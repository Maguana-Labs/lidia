import LidIAAppIntents
import LidIAKit
import SwiftData
import SwiftUI

/// Carries out what Siri asked the main window for (`SiriRouter`): opens a
/// meeting, starts a note, opens Ask, or presents a confirm sheet. Also tells
/// Siri what's on screen: the meeting page sets its own entity
/// (`MeetingEntity`), see `MeetingDetailView`.
struct SiriRequestHandler: ViewModifier {
    let nav: NavigationState
    let newNote: () -> Void
    let ask: (String) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var sheet: SiriSheet?

    enum SiriSheet: Identifiable {
        case followUp(Meeting)
        case nextStep(ActionIntent, ActionItem, Meeting)

        var id: String {
            switch self {
            case .followUp(let meeting): "follow-up:\(meeting.id)"
            case .nextStep(_, let item, _): "next-step:\(item.id)"
            }
        }
    }

    func body(content: Content) -> some View {
        content
            .onAppear { handle(SiriRouter.shared.take()) }
            .onChange(of: SiriRouter.shared.pending) { _, pending in
                guard pending != nil else { return }
                handle(SiriRouter.shared.take())
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .followUp(let meeting):
                    SiriFollowUpSheet(meeting: meeting)
                case .nextStep(let intent, let item, let meeting):
                    IntentConfirmSheet(intent: intent, item: item, meeting: meeting)
                }
            }
    }

    private func handle(_ request: SiriRouter.Request?) {
        guard let request else { return }
        switch request {
        case .openMeeting(let id):
            if let meeting = SiriStore.meeting(id, in: modelContext) { nav.show(meeting) }
        case .newNote:
            newNote()
        case .ask(let question):
            ask(question)
        case .followUp(let meetingID):
            guard let meeting = SiriStore.meeting(meetingID, in: modelContext) else { return }
            nav.show(meeting)
            sheet = .followUp(meeting)
        case .nextStep(let itemID):
            guard let item = SiriStore.actionItem(itemID, in: modelContext), let meeting = item.meeting else { return }
            nav.show(meeting)
            if let host = MacSiriHost.shared, let intent = MacFollowUps.nextStep(for: item, host: host) {
                sheet = .nextStep(intent, item, meeting)
            }
        }
    }
}
