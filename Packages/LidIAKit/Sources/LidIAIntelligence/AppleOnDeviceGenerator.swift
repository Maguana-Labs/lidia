#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Whether Apple's on-device model can run, in words the UI can show.
public enum OnDeviceModelStatus: Equatable, Sendable {
    case available
    case appleIntelligenceOff
    case deviceNotEligible
    case modelNotReady
    case unsupportedLanguage
    case unavailable

    public var isAvailable: Bool { self == .available }

    public var title: String {
        switch self {
        case .available: "Ready"
        case .appleIntelligenceOff: "Apple Intelligence is off"
        case .deviceNotEligible: "Not supported on this device"
        case .modelNotReady: "Getting ready"
        case .unsupportedLanguage: "Language not supported"
        case .unavailable: "Unavailable"
        }
    }

    public var message: String {
        switch self {
        case .available:
            "Notes, titles and action items are written on this device. Nothing is sent anywhere."
        case .appleIntelligenceOff:
            "Turn on Apple Intelligence in Settings to write notes on this device, or add a cloud model with your own key."
        case .deviceNotEligible:
            "This device can't run Apple Intelligence. Add a cloud model with your own key to get notes; transcripts still work."
        case .modelNotReady:
            "Apple Intelligence is still downloading. Notes will be written once it's ready."
        case .unsupportedLanguage:
            "Apple Intelligence doesn't support your language yet. Add a cloud model with your own key."
        case .unavailable:
            "Apple Intelligence isn't available right now."
        }
    }

    public static var current: OnDeviceModelStatus {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.supportsLocale(Locale.current) ? .available : .unsupportedLanguage
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
            case .deviceNotEligible: return .deviceNotEligible
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unavailable
            }
        }
    }
}

// MARK: - Guided generation

@Generable
struct OnDeviceFacts {
    @Guide(description: "A specific meeting title of at most 8 words naming the main topic")
    var title: String

    @Guide(description: "Things that were explicitly decided. Empty when none.")
    var decisions: [String]

    @Guide(description: "Tasks someone committed to or was asked to do. Empty when none.")
    var actionItems: [OnDeviceActionItem]
}

@Generable
struct OnDeviceActionItem {
    @Guide(description: "The task, starting with a verb")
    var title: String

    @Guide(description: "Name of the person who committed to it, exactly as written, or an empty string")
    var assignee: String

    @Guide(description: "Deadline as stated, or an empty string")
    var deadline: String
}

// MARK: - Generator

/// `TextGenerator` over Apple's on-device foundation model.
///
/// The context is small (4,096 tokens on 26.0–26.3, read at runtime on 26.4+),
/// so callers fit their input with `ContextFitter` first and every request
/// bounds its answer with `maximumResponseTokens`; a runaway answer is what
/// used to end in "context length exceeded" on the Mac.
public struct AppleOnDeviceGenerator: TextGenerator {
    public init() {}

    public var displayName: String { "Apple Intelligence" }
    public var isOnDevice: Bool { true }

    public var contextTokens: Int {
        if #available(iOS 26.4, macOS 26.4, *) {
            return SystemLanguageModel.default.contextSize
        }
        return 4096
    }

    public func countTokens(_ text: String) async throws -> Int {
        if #available(iOS 26.4, macOS 26.4, *) {
            return try await SystemLanguageModel.default.tokenCount(for: text)
        }
        return TokenEstimate.estimate(text)
    }

    public func respond(instructions: String, prompt: String, maxTokens: Int, temperature: Double) async throws -> String {
        try ensureAvailable()
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(temperature: temperature, maximumResponseTokens: maxTokens)
            )
            return response.content
        } catch {
            throw Self.map(error)
        }
    }

    public func stream(instructions: String, prompt: String, maxTokens: Int, temperature: Double) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try ensureAvailable()
                    let session = LanguageModelSession(instructions: instructions)
                    let stream = session.streamResponse(
                        to: prompt,
                        options: GenerationOptions(temperature: temperature, maximumResponseTokens: maxTokens)
                    )
                    var delta = StreamSnapshotDelta()
                    for try await snapshot in stream {
                        let text = delta.next(snapshot.content)
                        if !text.isEmpty { continuation.yield(text) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func extractFacts(notes: String) async throws -> MeetingFacts {
        try ensureAvailable()
        let session = LanguageModelSession(instructions: MeetingPrompts.factsSystemPrompt)
        do {
            let response = try await session.respond(
                to: notes,
                generating: OnDeviceFacts.self,
                options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 600)
            )
            let facts = response.content
            func clean(_ value: String) -> String? {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return MeetingFacts(
                title: facts.title,
                decisions: facts.decisions,
                actionItems: facts.actionItems.map {
                    ExtractedActionItem(title: $0.title, assignee: clean($0.assignee), deadline: clean($0.deadline))
                }
            )
        } catch {
            throw Self.map(error)
        }
    }

    private func ensureAvailable() throws {
        let status = OnDeviceModelStatus.current
        guard status.isAvailable else { throw GeneratorError.unavailable(status.message) }
    }

    static func map(_ error: Error) -> Error {
        if error is GeneratorError || error is CancellationError { return error }
        if let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .exceededContextWindowSize: return GeneratorError.contextLengthExceeded
            case .guardrailViolation, .refusal: return GeneratorError.declined
            case .unsupportedLanguageOrLocale: return GeneratorError.unavailable(OnDeviceModelStatus.unsupportedLanguage.message)
            case .assetsUnavailable: return GeneratorError.unavailable(OnDeviceModelStatus.modelNotReady.message)
            default: return GeneratorError.badResponse(generationError.localizedDescription)
            }
        }
        return error
    }
}
#endif
