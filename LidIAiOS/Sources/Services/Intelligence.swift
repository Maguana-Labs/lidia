import Foundation
import LidIAIntelligence
import Observation

/// Picks the model for notes and Ask and says, in plain words, why it can't.
@MainActor
@Observable
final class Intelligence {
    private let settings: AppSettings
    private(set) var onDeviceStatus: OnDeviceModelStatus = .available
    /// DEBUG demo builds answer with a scripted generator (no model needed for screenshots).
    var demoGenerator: (any TextGenerator)?

    init(settings: AppSettings) {
        self.settings = settings
        refresh()
    }

    func refresh() {
        onDeviceStatus = OnDeviceModelStatus.current
    }

    /// The engine actually used, after Local-only.
    var effectiveEngine: NotesEngine {
        settings.localOnly ? .onDevice : settings.notesEngine
    }

    /// One line for the UI: where the text goes.
    var engineLabel: String {
        if demoGenerator != nil { return "On this iPhone · Apple Intelligence" }
        switch effectiveEngine {
        case .onDevice: return "On this iPhone · Apple Intelligence"
        case .anthropic: return "Cloud · Claude with your key"
        case .openAI: return "Cloud · OpenAI with your key"
        }
    }

    var isOnDevice: Bool { effectiveEngine == .onDevice }

    func generator() throws -> any TextGenerator {
        if let demoGenerator { return demoGenerator }
        switch effectiveEngine {
        case .onDevice:
            refresh()
            guard onDeviceStatus.isAvailable else {
                throw GeneratorError.unavailable(onDeviceStatus.message)
            }
            return AppleOnDeviceGenerator()
        case .anthropic, .openAI:
            guard let (key, _) = settings.apiKey(for: effectiveEngine) else {
                throw GeneratorError.unavailable("Add your \(effectiveEngine == .anthropic ? "Anthropic" : "OpenAI") key in Settings, or switch notes back to On this iPhone.")
            }
            return CloudGenerator(
                provider: effectiveEngine == .anthropic ? .anthropic : .openAI,
                apiKey: key,
                model: settings.effectiveCloudModel
            )
        }
    }

    /// Whether notes can be written right now, and if not, why.
    var readiness: (ready: Bool, message: String) {
        if demoGenerator != nil { return (true, OnDeviceModelStatus.available.message) }
        do {
            let generator = try generator()
            return (true, generator.isOnDevice ? OnDeviceModelStatus.available.message : "Notes are written by \(generator.displayName) with your key. The transcript is sent to it.")
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
