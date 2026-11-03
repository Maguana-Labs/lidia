import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import LidIA

// MARK: - Cleanup

@Suite("Dictation cleanup")
struct DictationCleanupTests {
    private func clean(_ text: String, vocabulary: [AppSettings.VocabularyEntry] = [], language: String = "en", tidy: Bool = true) -> String {
        DictationTextCleaner(vocabulary: vocabulary, options: .init(tidy: tidy, languageCode: language)).clean(text)
    }

    @Test("Filler words go, the sentence stays")
    func fillers() {
        #expect(clean("Um, so I think, uh, we should ship it") == "So I think we should ship it.")
        #expect(clean("it was, like, great") == "It was great.")
        #expect(clean("the plan, you know, is fine") == "The plan is fine.")
        #expect(clean("uhm I'll call you back") == "I'll call you back.")
    }

    @Test("Ordinary uses of filler-like words are kept")
    func fillerLookalikes() {
        #expect(clean("I like the new design") == "I like the new design.")
        #expect(clean("Umbrella sales are up") == "Umbrella sales are up.")
    }

    @Test("Self-corrections keep only the correction")
    func corrections() {
        #expect(clean("Let's meet Tuesday, no wait, Thursday") == "Let's meet Thursday.")
        #expect(clean("Send it to John, sorry, to Mary") == "Send it to Mary.")
        #expect(clean("The budget is 10k, I mean, 12k") == "The budget is 12k.")
        // What SpeechTranscriber actually returns for a spoken correction (pauses become full stops).
        #expect(clean("So the TAPR review with Acme is on. Ah, Tuesday, no wait. Thursday at 3.") == "So the TAPR review with Acme is on Thursday at 3.")
        // Engines without punctuation.
        #expect(clean("lets meet tuesday no wait thursday") == "Lets meet thursday.")
    }

    @Test("Phrases that only look like corrections are left alone")
    func notCorrections() {
        #expect(clean("There is no wait time at the clinic.") == "There is no wait time at the clinic.")
        #expect(clean("I mean it.") == "I mean it.")
        #expect(clean("Sorry I missed the call yesterday.") == "Sorry I missed the call yesterday.")
    }

    @Test("Scratch that drops the sentence before it")
    func scratchThat() {
        #expect(clean("Book the room. Scratch that. Cancel the meeting.") == "Cancel the meeting.")
    }

    @Test("Stutters collapse, intended repeats stay")
    func stutters() {
        #expect(clean("the the plan is ready") == "The plan is ready.")
        #expect(clean("it was very very good") == "It was very very good.")
    }

    @Test("Personal vocabulary fixes words and spelling")
    func vocabulary() {
        let vocabulary = [
            AppSettings.VocabularyEntry(heardAs: "taper", replaceTo: "TAPR"),
            AppSettings.VocabularyEntry(heardAs: "lydia", replaceTo: "LidIA"),
        ]
        #expect(clean("the taper review is done", vocabulary: vocabulary) == "The TAPR review is done.")
        #expect(clean("the tapr review is done", vocabulary: vocabulary) == "The TAPR review is done.")
        #expect(clean("ask lydia about it", vocabulary: vocabulary) == "Ask LidIA about it.")
        // Whole words only.
        #expect(clean("tapers are tasty snacks", vocabulary: vocabulary) == "Tapers are tasty snacks.")
        // Vocabulary applies even with tidying off.
        #expect(clean("um the taper review", vocabulary: vocabulary, tidy: false) == "Um the TAPR review.")
    }

    @Test("Recognition hints come from the vocabulary")
    func hints() {
        let cleaner = DictationTextCleaner(
            vocabulary: [.init(heardAs: "taper", replaceTo: "TAPR"), .init(heardAs: "acne", replaceTo: "Acme")],
            personalTerms: ["Kubernetes", "tapr"]
        )
        #expect(cleaner.recognitionHints == ["TAPR", "Acme", "Kubernetes"])
        #expect(cleaner.canonicalTerms.contains("TAPR"))
        #expect(!cleaner.canonicalTerms.contains("Acme"))
    }

    @Test("Spoken lists become numbered lists")
    func lists() {
        #expect(clean("I need three things. First, buy milk. Second, call John. Third, email Sarah.")
                == "I need three things:\n1. Buy milk\n2. Call John\n3. Email Sarah")
        #expect(clean("number one the deck number two the budget") == "1. The deck\n2. The budget")
        // A lone "first" is not a list.
        #expect(clean("First, thanks for coming.") == "First, thanks for coming.")
    }

    @Test("New line and new paragraph")
    func voiceCommands() {
        #expect(clean("Hi Ana new paragraph thanks for the notes") == "Hi Ana\n\nThanks for the notes.")
        #expect(clean("milk new line eggs") == "Milk\nEggs")
    }

    @Test("Punctuation and capitals")
    func punctuation() {
        #expect(clean("ok thanks") == "Ok thanks")
        #expect(clean("what time is the meeting") == "What time is the meeting?")
        #expect(clean("i think i'm late") == "I think I'm late.")
        #expect(clean("the call is at 3:30 , right ?") == "The call is at 3:30, right?")
        #expect(clean("send it to my iPhone") == "Send it to my iPhone.")
        #expect(clean("") == "")
    }

    @Test("Spanish fillers and corrections")
    func spanish() {
        #expect(clean("Eh, nos vemos el martes, no, espera, el jueves", language: "es") == "Nos vemos el jueves.")
    }

    @Test("Cleanup is fast enough to add no latency")
    func fast() {
        let text = String(repeating: "Um, so the TAPR review with Acme is on, uh, Tuesday, no wait, Thursday at 3. ", count: 10)
        let start = ContinuousClock.now
        _ = clean(text, vocabulary: [.init(heardAs: "taper", replaceTo: "TAPR")])
        #expect(ContinuousClock.now - start < .milliseconds(50))
    }
}

// MARK: - Key handling

@Suite("Dictation key state machine")
struct DictationKeyStateMachineTests {
    typealias M = DictationKeyStateMachine

    @Test("Hold to talk: press starts, release finishes")
    func holdToTalk() {
        var machine = M(activation: .hold)
        #expect(machine.handle(.triggerDown(0)).commands == [.start])
        #expect(machine.isCapturing)
        #expect(machine.handle(.triggerUp(1.2)).commands == [.finish])
        #expect(machine.phase == .idle)
    }

    @Test("Hold mode: a blip is discarded")
    func holdBlip() {
        var machine = M(activation: .hold)
        _ = machine.handle(.triggerDown(0))
        #expect(machine.handle(.triggerUp(0.05)).commands == [.cancel])
    }

    @Test("Hybrid: hold finishes on release")
    func hybridHold() {
        var machine = M(activation: .holdOrDoubleTap)
        #expect(machine.handle(.triggerDown(0)).commands == [.start])
        #expect(machine.handle(.triggerUp(0.8)).commands == [.finish])
    }

    @Test("Hybrid: a single quick tap is thrown away after the double-tap window")
    func hybridSingleTap() {
        var machine = M(activation: .holdOrDoubleTap)
        _ = machine.handle(.triggerDown(0))
        let up = machine.handle(.triggerUp(0.1))
        #expect(up.commands.isEmpty)
        #expect(up.deadline == 0.5)
        #expect(machine.isCapturing, "keeps listening in case a second tap comes")
        #expect(machine.handle(.tick(0.3)).commands.isEmpty, "early tick does nothing")
        #expect(machine.handle(.tick(0.5)).commands == [.cancel])
        #expect(machine.phase == .idle)
    }

    @Test("Hybrid: double-tap locks hands-free, a tap finishes")
    func hybridDoubleTap() {
        var machine = M(activation: .holdOrDoubleTap)
        _ = machine.handle(.triggerDown(0))
        _ = machine.handle(.triggerUp(0.1))
        #expect(machine.handle(.triggerDown(0.25)).commands == [.lock])
        #expect(machine.handle(.triggerUp(0.3)).commands.isEmpty)
        #expect(machine.isLocked)
        // Typing while hands-free doesn't stop it.
        #expect(machine.handle(.otherKey(2)).commands.isEmpty)
        #expect(machine.handle(.triggerDown(5)).commands == [.finish])
        #expect(machine.handle(.triggerUp(5.1)).commands.isEmpty)
        #expect(machine.phase == .idle)
    }

    @Test("A shortcut with the trigger key (⌥Space) cancels, never dictates")
    func chordCancels() {
        for activation in [DictationActivation.hold, .holdOrDoubleTap] {
            var machine = M(activation: activation)
            _ = machine.handle(.triggerDown(0))
            #expect(machine.handle(.otherKey(0.05)).commands == [.cancel])
            #expect(machine.handle(.triggerUp(0.2)).commands.isEmpty)
            #expect(machine.phase == .idle)
        }
        var doubleTap = M(activation: .doubleTap)
        _ = doubleTap.handle(.triggerDown(0))
        #expect(doubleTap.handle(.otherKey(0.05)).commands.isEmpty)
        _ = doubleTap.handle(.triggerUp(0.1))
        #expect(doubleTap.handle(.triggerDown(0.2)).commands.isEmpty, "the chord's release isn't a first tap")
    }

    @Test("Esc cancels and is swallowed only while dictating")
    func escape() {
        var machine = M(activation: .holdOrDoubleTap)
        let idleEsc = machine.handle(.escape(0))
        #expect(idleEsc.commands.isEmpty)
        #expect(!idleEsc.swallow)

        _ = machine.handle(.triggerDown(1))
        let esc = machine.handle(.escape(1.5))
        #expect(esc.commands == [.cancel])
        #expect(esc.swallow)
        #expect(machine.handle(.triggerUp(2)).commands.isEmpty)
        #expect(machine.phase == .idle)

        // Hands-free.
        _ = machine.handle(.triggerDown(3)); _ = machine.handle(.triggerUp(3.1))
        _ = machine.handle(.triggerDown(3.2)); _ = machine.handle(.triggerUp(3.3))
        #expect(machine.handle(.escape(6)).commands == [.cancel])
        #expect(machine.phase == .idle)
    }

    @Test("Double-tap mode starts on the second tap")
    func doubleTapMode() {
        var machine = M(activation: .doubleTap)
        #expect(machine.handle(.triggerDown(0)).commands.isEmpty)
        #expect(machine.handle(.triggerUp(0.1)).commands.isEmpty)
        #expect(machine.handle(.triggerDown(0.3)).commands == [.start, .lock])
        _ = machine.handle(.triggerUp(0.35))
        #expect(machine.handle(.triggerDown(4)).commands == [.finish])
    }

    @Test("Double-tap mode: taps too far apart do nothing")
    func doubleTapTooSlow() {
        var machine = M(activation: .doubleTap)
        _ = machine.handle(.triggerDown(0)); _ = machine.handle(.triggerUp(0.1))
        #expect(machine.handle(.triggerDown(1.0)).commands.isEmpty)
        #expect(!machine.isCapturing)
    }
}

@Suite("Dictation key monitor")
@MainActor
struct DictationKeyMonitorTests {
    private final class Recorder {
        var events: [DictationKeyStateMachine.Event] = []
    }

    private func monitor(_ key: DictationTriggerKey, recorder: Recorder) -> DictationKeyMonitor {
        DictationKeyMonitor(triggerKey: key) { event in
            recorder.events.append(event)
            return false
        }
    }

    private func names(_ events: [DictationKeyStateMachine.Event]) -> [String] {
        events.map {
            switch $0 {
            case .triggerDown: "down"
            case .triggerUp: "up"
            case .otherKey: "other"
            case .escape: "esc"
            case .tick: "tick"
            }
        }
    }

    @Test("Right Option is told apart from Left Option")
    func rightOption() {
        let recorder = Recorder()
        let monitor = monitor(.rightOption, recorder: recorder)
        // Left Option: keyCode 58, device bit 0x20.
        _ = monitor.handle(.init(type: .flagsChanged, flags: 0x80120, keyCode: 58))
        _ = monitor.handle(.init(type: .flagsChanged, flags: 0x100, keyCode: 58))
        #expect(recorder.events.isEmpty)
        // Right Option: keyCode 61, device bit 0x40.
        _ = monitor.handle(.init(type: .flagsChanged, flags: 0x80140, keyCode: 61))
        _ = monitor.handle(.init(type: .flagsChanged, flags: 0x100, keyCode: 61))
        #expect(names(recorder.events) == ["down", "up"])
    }

    @Test("Another key while the trigger is held is a shortcut")
    func chord() {
        let recorder = Recorder()
        let monitor = monitor(.rightOption, recorder: recorder)
        _ = monitor.handle(.init(type: .flagsChanged, flags: 0x80140, keyCode: 61))
        _ = monitor.handle(.init(type: .keyDown, flags: 0x80140, keyCode: 49)) // Space
        _ = monitor.handle(.init(type: .flagsChanged, flags: 0x180148, keyCode: 54)) // + Right Command
        #expect(names(recorder.events) == ["down", "other", "other"])
    }

    @Test("Trigger pressed while ⌘ is already held is ignored")
    func modifierAlreadyHeld() {
        let recorder = Recorder()
        let monitor = monitor(.rightOption, recorder: recorder)
        _ = monitor.handle(.init(type: .flagsChanged, flags: 0x180148, keyCode: 61))
        #expect(recorder.events.isEmpty)
    }

    @Test("Fn / Globe is captured and kept from the system")
    func fn() {
        let recorder = Recorder()
        let monitor = monitor(.fn, recorder: recorder)
        let swallowDown = monitor.handle(.init(type: .flagsChanged, flags: 0x800100, keyCode: 63))
        let swallowUp = monitor.handle(.init(type: .flagsChanged, flags: 0x100, keyCode: 63))
        #expect(names(recorder.events) == ["down", "up"])
        #expect(swallowDown && swallowUp)
        // Arrow keys carry the Fn flag but aren't the Fn key.
        _ = monitor.handle(.init(type: .flagsChanged, flags: 0x800100, keyCode: 123))
        #expect(recorder.events.count == 2)
    }

    @Test("Esc and our own synthetic ⌘V")
    func escapeAndSynthetic() {
        let recorder = Recorder()
        let monitor = monitor(.rightOption, recorder: recorder)
        _ = monitor.handle(.init(type: .keyDown, flags: 0x100, keyCode: 53))
        var synthetic = DictationKeyMonitor.KeyEventInfo(type: .keyDown, flags: 0x100100, keyCode: 9)
        synthetic.isSynthetic = true
        _ = monitor.handle(synthetic)
        #expect(names(recorder.events) == ["esc"])
    }
}

// MARK: - Pasteboard

@Suite("Dictation pasteboard restore", .serialized)
@MainActor
struct DictationPasteboardTests {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("io.lidia.tests.\(UUID().uuidString)"))
    }

    @Test("Previous contents, every type, come back after the paste")
    func restores() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("previous clipboard", forType: .string)
        item.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("com.example.custom"))
        pasteboard.writeObjects([item])
        let before = PasteboardSnapshot.capture(pasteboard)

        var seenDuringPaste: String?
        let restored = await PasteboardTransaction(pasteboard: pasteboard, restoreDelay: .milliseconds(20)).perform(text: "dictated text") {
            seenDuringPaste = pasteboard.string(forType: .string)
        }

        #expect(seenDuringPaste == "dictated text")
        #expect(restored)
        #expect(pasteboard.string(forType: .string) == "previous clipboard")
        #expect(pasteboard.data(forType: NSPasteboard.PasteboardType("com.example.custom")) == Data([1, 2, 3]))
        #expect(PasteboardSnapshot.capture(pasteboard) == before)
    }

    @Test("Our temporary contents are marked transient for clipboard managers")
    func transient() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        var types: [NSPasteboard.PasteboardType] = []
        await PasteboardTransaction(pasteboard: pasteboard, restoreDelay: .milliseconds(5)).perform(text: "x") {
            types = pasteboard.types ?? []
        }
        #expect(types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))
    }

    @Test("Something copied meanwhile is not overwritten")
    func userCopiedMeanwhile() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)
        let restored = await PasteboardTransaction(pasteboard: pasteboard, restoreDelay: .milliseconds(20)).perform(text: "dictated") {
            pasteboard.clearContents()
            pasteboard.setString("copied by the user", forType: .string)
        }
        #expect(!restored)
        #expect(pasteboard.string(forType: .string) == "copied by the user")
    }

    @Test("An empty clipboard stays empty")
    func emptyStaysEmpty() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        await PasteboardTransaction(pasteboard: pasteboard, restoreDelay: .milliseconds(5)).perform(text: "dictated") {}
        #expect(pasteboard.string(forType: .string) == nil)
    }
}

// MARK: - Settings and history

@Suite("Dictation settings and history")
@MainActor
struct DictationSettingsTests {
    @Test("Defaults, and settings persist under dictation.*")
    func persistence() throws {
        let suite = "io.lidia.tests.dictation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = DictationSettings(defaults: defaults)
        #expect(settings.enabled == false)
        #expect(settings.triggerKey == .rightOption)
        #expect(settings.activation == .holdOrDoubleTap)
        #expect(settings.insertion == .automatic)
        #expect(settings.polishWithAI == false)
        #expect(settings.tidyText)

        settings.enabled = true
        settings.triggerKey = .fn
        settings.polishWithAI = true
        settings.language = "es-ES"
        settings.historyLimit = 50
        let reloaded = DictationSettings(defaults: defaults)
        #expect(reloaded.enabled)
        #expect(reloaded.triggerKey == .fn)
        #expect(reloaded.polishWithAI)
        #expect(reloaded.historyLimit == 50)
        #expect(reloaded.resolvedLocale(sttLanguage: "en-US").identifier == "es-ES")
        #expect(defaults.string(forKey: "dictation.triggerKey") == "fn")
    }

    @Test("History keeps the last N and clears from disk")
    func history() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let history = DictationHistory(fileURL: url)
        for index in 0..<5 {
            history.add(DictationRecord(date: .now, text: "note \(index)", rawText: "note \(index)", appName: "Notes", outcome: "Typed", latencyMilliseconds: 200), limit: 3)
        }
        #expect(history.records.map(\.text) == ["note 4", "note 3", "note 2"])
        #expect(DictationHistory(fileURL: url).records.count == 3, "saved to disk")
        history.clear()
        #expect(history.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Every dictation anchor is searchable and on the Dictation pane")
    func search() {
        let dictationAnchors: [SettingsAnchor] = [.dictationEnabled, .dictationKey, .dictationMode, .dictationInsertion,
                                                  .dictationTidy, .dictationPolish, .dictationLanguage, .dictationEngine, .dictationHistory]
        for anchor in dictationAnchors {
            #expect(SettingsSearchIndex.entries.first { $0.anchor == anchor }?.pane == .dictation)
        }
        #expect(SettingsSearchIndex.search("dictation").first?.anchor == .dictationEnabled)
        #expect(SettingsSearchIndex.search("globe").first?.anchor == .dictationKey)
        #expect(SettingsSearchIndex.search("filler words").first?.anchor == .dictationTidy)
        #expect(SettingsSearchIndex.search("clipboard").first?.anchor == .dictationInsertion)
        #expect(SettingsSearchIndex.search("grok").first?.anchor == .grokVoice)
    }

    @Test("AI polish rejects answers and preambles")
    func polishGuard() {
        let original = "can we move the tapr review to thursday"
        #expect(DictationPolisher.accept("Can we move the TAPR review to Thursday?", original: original) == "Can we move the TAPR review to Thursday?")
        #expect(DictationPolisher.accept("Here's the cleaned text: Can we move it?", original: original) == nil)
        #expect(DictationPolisher.accept("", original: original) == nil)
        #expect(DictationPolisher.accept(String(repeating: "Sure, I can help you schedule that. ", count: 8), original: original) == nil)
        #expect(DictationPolisher.accept("<think>hmm</think>Can we move the TAPR review to Thursday?", original: original) == "Can we move the TAPR review to Thursday?")
    }

    @Test("The polish prompt carries the user's spelling")
    func polishPrompt() {
        let prompt = DictationPolisher.systemPrompt(terms: ["TAPR", "LidIA"], languageCode: "en")
        #expect(prompt.contains("TAPR, LidIA"))
        #expect(prompt.contains("Reply with the finished text only"))
    }
}

// MARK: - Voice assistant

@Suite("Voice assistant hotkey and backends")
struct VoiceLayerTests {
    @Test("The assistant hotkey matches exactly, ignores auto-repeat and bare keys")
    func hotkey() {
        let space: UInt16 = 49
        #expect(VoiceInputController.matchesHotkey(keyCode: space, modifiers: .option, isRepeat: false, hotkeyCode: space, hotkeyModifiers: .option))
        #expect(!VoiceInputController.matchesHotkey(keyCode: space, modifiers: .option, isRepeat: true, hotkeyCode: space, hotkeyModifiers: .option))
        #expect(!VoiceInputController.matchesHotkey(keyCode: space, modifiers: [.option, .command], isRepeat: false, hotkeyCode: space, hotkeyModifiers: .option))
        #expect(!VoiceInputController.matchesHotkey(keyCode: space, modifiers: [], isRepeat: false, hotkeyCode: space, hotkeyModifiers: []))
        #expect(VoiceInputController.matchesHotkey(keyCode: space, modifiers: [.option, .capsLock], isRepeat: false, hotkeyCode: space, hotkeyModifiers: .option))
    }

    @Test("Grok only with a key, never in Local-only mode")
    func grokBackend() {
        #expect(VoiceAssistantBackend.resolve(ttsProvider: .automatic, openAIAPIKey: "", grokEnabled: true, xAIAPIKey: "xai-1", localOnly: false) == .xAIRealtime)
        #expect(VoiceAssistantBackend.resolve(ttsProvider: .automatic, openAIAPIKey: "", grokEnabled: true, xAIAPIKey: "xai-1", localOnly: true) == .localPipeline)
        #expect(VoiceAssistantBackend.resolve(ttsProvider: .automatic, openAIAPIKey: "", grokEnabled: true, xAIAPIKey: " ", localOnly: false) == .localPipeline)
        #expect(VoiceAssistantBackend.resolve(ttsProvider: .openai, openAIAPIKey: "sk", grokEnabled: false, xAIAPIKey: "xai-1", localOnly: false) == .openAIRealtime)
    }

    @Test("Realtime voices map TTS-only names to a valid voice")
    func voices() {
        #expect(RealtimeVoiceProvider.openAI.voice(for: "nova") == "marin")
        #expect(RealtimeVoiceProvider.openAI.voice(for: "") == "marin")
        #expect(RealtimeVoiceProvider.openAI.voice(for: "Coral") == "coral")
        #expect(RealtimeVoiceProvider.xAI.voice(for: "rex") == "rex")
        #expect(RealtimeVoiceProvider.xAI.voice(for: "nova") == "eve")
    }

    @Test("GA OpenAI and xAI session shapes")
    func sessionShapes() throws {
        let openAI = RealtimeVoiceProvider.openAI.sessionUpdate(instructions: "hi", voice: "nova")
        let session = try #require(openAI["session"] as? [String: Any])
        #expect(session["type"] as? String == "realtime")
        let audio = try #require(session["audio"] as? [String: Any])
        let output = try #require(audio["output"] as? [String: Any])
        #expect(output["voice"] as? String == "marin")
        #expect(RealtimeVoiceProvider.openAI.url(model: "gpt-realtime-2.1").absoluteString == "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1")

        let xai = RealtimeVoiceProvider.xAI.sessionUpdate(instructions: "hi", voice: "ara")
        let xaiSession = try #require(xai["session"] as? [String: Any])
        #expect(xaiSession["voice"] as? String == "ara")
        #expect(RealtimeVoiceProvider.xAI.url(model: "grok-voice-latest").host == "api.x.ai")
        // Both are JSON-serialisable.
        _ = try JSONSerialization.data(withJSONObject: openAI)
        _ = try JSONSerialization.data(withJSONObject: xai)
    }

    @Test("GA, beta and xAI server events parse")
    func events() throws {
        func parse(_ json: String) -> RealtimeVoiceClient.ServerEvent? {
            RealtimeVoiceClient.parseServerEvent(from: Data(json.utf8))
        }
        #expect(parse(#"{"type":"response.output_audio.delta","delta":"QUJD"}"#) == .audioDelta(Data("ABC".utf8)))
        #expect(parse(#"{"type":"response.output_audio_transcript.delta","delta":"Hi"}"#) == .audioTranscriptDelta("Hi"))
        #expect(parse(#"{"type":"response.output_text.delta","delta":"Hi"}"#) == .textDelta("Hi"))
        #expect(parse(#"{"type":"conversation.item.input_audio_transcription.updated","transcript":"hello"}"#) == .inputTranscript("hello", isFinal: false))
        #expect(parse(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"hello"}"#) == .inputTranscript("hello", isFinal: true))
    }

    @Test("Voice ears follow the dictation engine")
    func ears() {
        #expect(VoiceEars.resolve(dictationEngine: .appleOnDevice, appleAvailable: true) == .apple)
        #expect(VoiceEars.resolve(dictationEngine: .appleOnDevice, appleAvailable: false) == .liveEngine)
        #expect(VoiceEars.resolve(dictationEngine: .liveEngine, appleAvailable: true) == .liveEngine)
    }

    @Test("Joining engine words keeps punctuation attached")
    func joinWords() {
        #expect(STTEngineDictationRecognizer.join(["Hello", ",", "world", "."]) == "Hello, world.")
    }
}
