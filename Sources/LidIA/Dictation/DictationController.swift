import AppKit
import AVFoundation
import os

/// Dictation everywhere: hold (or double-tap) a key, speak, and cleaned-up
/// text is typed at the cursor of whatever app is in front.
///
/// Key → `DictationKeyStateMachine` → microphone (`DictationAudioCapture`) →
/// on-device recogniser (`DictationRecognizer`, live partial text in the HUD)
/// → `DictationTextCleaner` (+ optional AI polish) → `DictationInserter`.
@MainActor
@Observable
final class DictationController {
    static let shared = DictationController()
    nonisolated private static let logger = Logger(subsystem: "io.lidia.app", category: "Dictation")
    /// Audio kept after the key is released, so the last word isn't clipped.
    static let releaseTail: Duration = .milliseconds(120)

    enum Status: Equatable {
        case off
        /// Turned on, but Accessibility permission is missing.
        case needsAccessibility
        case ready
        case listening
        case finishing
    }

    private(set) var status: Status = .off
    /// Key release to text inserted, for the last dictation.
    private(set) var lastLatency: Duration?
    /// Replaceable so DEBUG snapshots can show sample history without touching the real file.
    var history = DictationHistory()

    @ObservationIgnored let hud = DictationHUDController()
    @ObservationIgnored private var settings: AppSettings?
    @ObservationIgnored private var modelManager: ModelManager?
    @ObservationIgnored private var monitor: DictationKeyMonitor?
    @ObservationIgnored private var machine = DictationKeyStateMachine(activation: .holdOrDoubleTap)
    @ObservationIgnored private let capture = DictationAudioCapture()
    @ObservationIgnored private let inserter = DictationInserter()
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var permissionPoll: Task<Void, Never>?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var preparedLocale: String?

    private final class Session {
        let id = UUID()
        let startedAt = ContinuousClock.now
        var releasedAt: ContinuousClock.Instant?
        let appName: String?
        let isOwnApp: Bool
        var recognition: Task<String, Error>?
        var hudTask: Task<Void, Never>?
        var levelTimer: Timer?
        var finishing = false

        init(appName: String?, isOwnApp: Bool) {
            self.appName = appName
            self.isOwnApp = isOwnApp
        }
    }

    // MARK: - Setup

    func configure(settings: AppSettings, modelManager: ModelManager?) {
        self.settings = settings
        self.modelManager = modelManager
        VoiceActivity.cancelDictation = { [weak self] in self?.cancel() }
        apply()
    }

    /// Re-reads settings: key, mode, on/off. Call after any dictation setting changes.
    func apply() {
        guard let settings else { return }
        let dictation = settings.dictation
        history.trim(to: dictation.keepHistory ? dictation.historyLimit : 0)
        machine = DictationKeyStateMachine(activation: dictation.activation)
        guard dictation.enabled else {
            stopMonitoring()
            status = .off
            return
        }
        if let monitor {
            monitor.triggerKey = dictation.triggerKey
        }
        if monitor?.isRunning == true {
            status = session == nil ? .ready : status
        } else {
            startMonitoringWhenTrusted()
        }
        prepareRecognizer()
    }

    private func startMonitoringWhenTrusted() {
        guard let settings else { return }
        let monitor = monitor ?? DictationKeyMonitor(triggerKey: settings.dictation.triggerKey) { [weak self] event in
            self?.handle(event) ?? false
        }
        self.monitor = monitor
        if DictationPermissions.isAccessibilityTrusted, monitor.start() {
            status = .ready
            permissionPoll?.cancel()
            permissionPoll = nil
            return
        }
        status = .needsAccessibility
        guard permissionPoll == nil else { return }
        // Accessibility can't be observed; check every couple of seconds until granted.
        permissionPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.settings?.dictation.enabled == true else { return }
                if DictationPermissions.isAccessibilityTrusted, self.monitor?.start() == true {
                    self.status = .ready
                    self.permissionPoll = nil
                    Self.logger.info("Accessibility granted; dictation key active")
                    return
                }
            }
        }
    }

    private func stopMonitoring() {
        permissionPoll?.cancel()
        permissionPoll = nil
        monitor?.stop()
        monitor = nil
        cancel()
    }

    /// Loads the speech model in the background so the first dictation is quick.
    private func prepareRecognizer() {
        guard let settings else { return }
        let locale = settings.dictation.resolvedLocale(sttLanguage: settings.sttLanguage)
        guard preparedLocale != locale.identifier else { return }
        preparedLocale = locale.identifier
        let recognizer = DictationEngineRegistry.makeRecognizer(settings.dictation.engine, settings: settings)
        Task.detached(priority: .utility) {
            do {
                try await recognizer.prepare(locale: locale)
            } catch {
                Self.logger.error("Dictation recogniser not ready: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Keys

    private func handle(_ event: DictationKeyStateMachine.Event) -> Bool {
        if case .triggerDown = event, session == nil, !machine.isCapturing {
            // The assistant has the microphone; the key does nothing until it closes.
            if VoiceActivity.isAssistantActive { return false }
        }
        let output = machine.handle(event)
        for command in output.commands {
            switch command {
            case .start: start()
            case .lock: lock()
            case .finish: finish()
            case .cancel: cancel(resetMachine: false)
            }
        }
        if let deadline = output.deadline {
            scheduleTick(at: deadline)
        }
        return output.swallow
    }

    private func scheduleTick(at deadline: TimeInterval) {
        deadlineTask?.cancel()
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay) + .milliseconds(5))
            guard !Task.isCancelled else { return }
            self?.monitor?.tick()
        }
    }

    // MARK: - Session

    func start() {
        guard let settings, session == nil else { return }
        switch DictationPermissions.microphoneStatus {
        case .authorized:
            break
        case .notDetermined:
            machine.reset()
            Task { _ = await DictationPermissions.requestMicrophone() }
            hud.showMessage("Allow the microphone, then try again", isError: true)
            return
        default:
            machine.reset()
            hud.showMessage("Microphone access is off for LidIA", isError: true)
            return
        }

        let front = NSWorkspace.shared.frontmostApplication
        let session = Session(
            appName: front?.localizedName,
            isOwnApp: front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        )
        let audio: AsyncStream<AudioChunk>
        do {
            audio = try capture.start()
        } catch {
            machine.reset()
            hud.showMessage(error.localizedDescription, isError: true)
            return
        }
        self.session = session
        VoiceActivity.isDictating = true
        status = .listening
        hud.model.reset(keySymbol: settings.dictation.triggerKey.symbol)

        let recognizer = DictationEngineRegistry.makeRecognizer(settings.dictation.engine, settings: settings)
        let locale = settings.dictation.resolvedLocale(sttLanguage: settings.sttLanguage)
        let hints = cleaner(for: settings).recognitionHints
        let sessionID = session.id
        let hudModel = hud.model
        let onPartial: @Sendable (String) -> Void = { partial in
            Task { @MainActor in
                guard DictationController.shared.session?.id == sessionID else { return }
                hudModel.partialText = partial
            }
        }
        session.recognition = Task.detached(priority: .userInitiated) {
            try await recognizer.transcribe(audio, locale: locale, hints: hints, onPartial: onPartial)
        }
        // Wait a moment before showing the HUD: ⌥ + another key is a shortcut,
        // and a HUD flashing on every shortcut would be anything but calm.
        session.hudTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled, let self, self.session?.id == sessionID else { return }
            self.hud.show()
        }
        session.levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let current = self.session, current.id == sessionID else { return }
                self.hud.model.push(level: self.capture.level)
                // Hands-free safety stop.
                if ContinuousClock.now - current.startedAt > .seconds(600) { self.finish() }
            }
        }
    }

    private func lock() {
        guard session != nil else { return }
        hud.model.phase = .locked
        session?.hudTask?.cancel()
        hud.show()
    }

    /// Stops listening, then transcribes, cleans and inserts.
    func finish() {
        guard let settings, let session, !session.finishing else { return }
        session.finishing = true
        session.releasedAt = .now
        session.hudTask?.cancel()
        session.levelTimer?.invalidate()
        machine.reset()
        status = .finishing
        hud.model.phase = .finishing
        if hud.isVisible == false { hud.show() }

        let dictation = settings.dictation
        let cleaner = cleaner(for: settings)
        let languageCode = dictation.resolvedLocale(sttLanguage: settings.sttLanguage).language.languageCode?.identifier ?? "en"

        Task { [weak self] in
            guard let self else { return }
            defer { self.endSession(session) }
            // Keep the mic open a moment: people let go on the last syllable.
            try? await Task.sleep(for: Self.releaseTail)
            let spoken = self.capture.capturedDuration
            self.capture.stop()
            let raw: String
            do {
                raw = try await session.recognition?.value ?? ""
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
                self.hud.showMessage(error.localizedDescription, isError: true, for: .seconds(3))
                return
            }
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if spoken > 0.6 { self.hud.showMessage("Didn't catch that", isError: true, for: .seconds(1.2)) } else { self.hud.hide() }
                return
            }

            var text = cleaner.clean(raw)
            if dictation.polishWithAI,
               let polished = await DictationPolisher.polish(text, terms: cleaner.canonicalTerms, languageCode: languageCode, settings: settings, modelManager: self.modelManager) {
                text = cleaner.applyVocabulary(polished)
            }

            // LidIA's own windows can't be driven through Accessibility from
            // the main thread (it would wait on itself), so paste there.
            let method: DictationInsertionMethod = session.isOwnApp && dictation.insertion == .automatic ? .paste : dictation.insertion
            let outcome = await self.inserter.insert(text, method: method)
            let latency = session.releasedAt.map { ContinuousClock.now - $0 }
            self.lastLatency = latency
            if let latency {
                Self.logger.info("Dictation inserted (\(Self.describe(outcome), privacy: .public)) \(Self.milliseconds(latency))ms after release")
            }

            switch outcome {
            case .accessibility, .pasted:
                self.hud.hide()
            case .secureInput:
                self.hud.showMessage("Not typed into a password field. It's in History.", isError: true, for: .seconds(2.5))
            case .failed(let reason):
                self.hud.showMessage("\(reason). It's in History.", isError: true, for: .seconds(2.5))
            }
            if dictation.keepHistory {
                self.history.add(DictationRecord(
                    date: .now,
                    text: text,
                    rawText: raw,
                    appName: session.appName,
                    outcome: Self.describe(outcome),
                    latencyMilliseconds: latency.map(Self.milliseconds)
                ), limit: dictation.historyLimit)
            }
        }
    }

    /// Stops and throws the audio away.
    func cancel() {
        cancel(resetMachine: true)
    }

    private func cancel(resetMachine: Bool) {
        if resetMachine { machine.reset() }
        deadlineTask?.cancel()
        guard let session, !session.finishing else { return }
        session.hudTask?.cancel()
        session.levelTimer?.invalidate()
        session.recognition?.cancel()
        capture.stop()
        if hud.isVisible { hud.hide() }
        endSession(session)
    }

    private func endSession(_ ended: Session) {
        guard session?.id == ended.id else { return }
        session = nil
        VoiceActivity.isDictating = false
        if status == .listening || status == .finishing {
            status = monitor?.isRunning == true ? .ready : .off
        }
    }

    // MARK: - Helpers

    func cleaner(for settings: AppSettings) -> DictationTextCleaner {
        let locale = settings.dictation.resolvedLocale(sttLanguage: settings.sttLanguage)
        return DictationTextCleaner(
            vocabulary: settings.customVocabulary,
            options: .init(tidy: settings.dictation.tidyText, languageCode: locale.language.languageCode?.identifier ?? "en")
        )
    }

    nonisolated static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    static func describe(_ outcome: DictationInserter.Outcome) -> String {
        switch outcome {
        case .accessibility: "Typed"
        case .pasted: "Pasted"
        case .secureInput: "Not inserted (password field)"
        case .failed(let reason): "Not inserted (\(reason))"
        }
    }
}
