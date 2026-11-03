import SwiftUI

/// What the sidebar list can select. The detail view still reads
/// `selectedMeeting`; this is only the sidebar's view of the same state.
enum SidebarSelection: Hashable {
    case today
    case library
    case actionItems
    case people
    case chats
    case project(String)
    case meeting(UUID)
    case event(String)
}

@MainActor
@Observable
final class NavigationState {
    enum DetailDestination {
        /// The Today agenda (formerly Home).
        case home
        /// The Meetings library (search, filters, series).
        case library
        case meeting, calendarEvent, actionItems, people, chat
        /// One project's page (`selectedProject`).
        case project
    }

    /// One-shot requests to the meeting page (inspector tab, notes view),
    /// consumed by the page. Used by commands and the snapshot run.
    enum InspectorRequest: Equatable { case hide, transcript, ask }
    enum MeetingPageRequest: Equatable { case aiNotes, myNotes, showAttendees, closePopovers }

    var selectedMeeting: Meeting?
    var selectedCalendarEvent: AgendaEvent?
    var selectedFolder: String?
    /// The project open in the detail column.
    var selectedProject: String?
    var detailDestination: DetailDestination = .home
    var selectedTab = "summary"
    var detailPath = NavigationPath()
    var columnVisibility: NavigationSplitViewVisibility = .automatic

    /// Toolbar search.
    var searchText = ""
    var isSearchPresented = false

    /// ⌘K "Ask LidIA" palette.
    var isAskPalettePresented = false

    /// The series open in the Meetings library, if any.
    var librarySeriesKey: String?
    /// Where the meeting page's Back button returns to.
    var meetingReturnDestination: DetailDestination = .home

    var inspectorRequest: InspectorRequest?
    var meetingPageRequest: MeetingPageRequest?
    /// One-shot: show the transcript and play from this time (a citation).
    var transcriptSeekRequest: TimeInterval?

    /// The sidebar row matching the current detail, if any.
    var sidebarSelection: SidebarSelection? {
        switch detailDestination {
        case .home: .today
        case .library: .library
        case .actionItems: .actionItems
        case .people: .people
        case .chat: .chats
        case .project: selectedProject.map { .project($0) }
        case .meeting: selectedMeeting.map { .meeting($0.id) }
        case .calendarEvent: selectedCalendarEvent.map { .event($0.id) }
        }
    }

    func showToday() {
        selectedMeeting = nil
        selectedCalendarEvent = nil
        detailDestination = .home
    }

    func show(_ meeting: Meeting) {
        if detailDestination != .meeting {
            meetingReturnDestination = detailDestination == .calendarEvent ? .home : detailDestination
        }
        selectedMeeting = meeting
        detailDestination = .meeting
    }

    /// Back from a meeting to where it was opened (Today, Meetings, a series…).
    func goBackFromMeeting() {
        show(meetingReturnDestination == .meeting ? .home : meetingReturnDestination)
    }

    /// Title for the meeting page's Back button.
    var meetingBackTitle: String {
        switch meetingReturnDestination {
        case .library: librarySeriesKey == nil ? "Meetings" : "Series"
        case .actionItems: "Action Items"
        case .people: "People"
        case .chat: "Chats"
        case .project: selectedProject ?? "Project"
        default: "Today"
        }
    }

    func show(_ event: AgendaEvent) {
        selectedCalendarEvent = event
        selectedMeeting = nil
        detailDestination = .calendarEvent
    }

    func showProject(_ name: String) {
        selectedProject = name
        show(.project)
    }

    func show(_ destination: DetailDestination) {
        if destination != .meeting { selectedMeeting = nil }
        detailDestination = destination
    }
}
