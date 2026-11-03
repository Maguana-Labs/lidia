import AppKit
import Foundation
import Observation

/// What Siri asked the window to show. Intents put a request here; the main
/// window (`ContentView`) takes it when it appears or when it changes, so a
/// request made while the app is still launching isn't lost.
@MainActor
@Observable
final class SiriRouter {
    static let shared = SiriRouter()

    enum Request: Equatable, Identifiable {
        case openMeeting(UUID)
        case newNote
        /// The meeting's follow-up email, to review before anything is sent.
        case followUp(meetingID: UUID)
        /// An action item's prepared next step, in the Intents confirm sheet.
        case nextStep(itemID: UUID)
        /// Ask, with the question typed in.
        case ask(String)

        var id: String {
            switch self {
            case .openMeeting(let id): "open:\(id)"
            case .newNote: "new-note"
            case .followUp(let id): "follow-up:\(id)"
            case .nextStep(let id): "next-step:\(id)"
            case .ask(let question): "ask:\(question)"
            }
        }
    }

    /// The request waiting for the window.
    private(set) var pending: Request?

    func request(_ request: Request) {
        NSApp.activate()
        pending = request
    }

    /// Takes the waiting request (the window handles it once).
    func take() -> Request? {
        defer { pending = nil }
        return pending
    }
}
