import Foundation
import LidIAKit
import Observation
import SwiftData
import SwiftUI

enum AppTab: Hashable {
    case home
    case meetings
    case actions
    case ask
}

/// Value pushed onto a navigation stack to open a meeting.
struct MeetingRoute: Hashable {
    let id: UUID
}

/// App-wide navigation and presentation state.
@MainActor
@Observable
final class AppRouter {
    /// For App Intents, which run outside the view hierarchy.
    static weak var current: AppRouter?

    var tab: AppTab = .home
    var homePath = NavigationPath()
    var meetingsPath = NavigationPath()
    var actionsPath = NavigationPath()
    var askPath = NavigationPath()

    var showRecorder = false
    var showSettings = false
    /// Ask presented as a sheet (from a meeting, or the ✦ button on Home).
    var askSheet: AskScope?
    var actionItemDetail: ActionItemRoute?
    var meetingsSearchFocused = false
    /// A question to ask as soon as the Ask tab appears (demo and deep links).
    var pendingAskQuestion: String?

    struct AskScope: Identifiable, Hashable {
        let id = UUID()
        var meetingID: UUID?
        var meetingTitle: String?
    }

    struct ActionItemRoute: Identifiable, Hashable {
        let id: UUID
    }

    func open(_ meetingID: UUID) {
        let route = MeetingRoute(id: meetingID)
        switch tab {
        case .home: homePath.append(route)
        case .meetings: meetingsPath.append(route)
        case .actions: actionsPath.append(route)
        case .ask: askPath.append(route)
        }
    }

    func handle(url: URL) {
        guard url.scheme == "lidia" else { return }
        switch url.host {
        case "record", "recording":
            showRecorder = true
        case "ask":
            tab = .ask
        default:
            break
        }
    }
}
