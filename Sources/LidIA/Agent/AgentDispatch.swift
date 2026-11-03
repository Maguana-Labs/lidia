import Foundation
import SwiftData

/// The two halves of sending an action item somewhere:
/// `propose_dispatch` (a tool the model can call, which only drafts) and
/// `confirmAndDispatch` (which only the confirmation UI calls).
@MainActor
enum AgentDispatch {
    /// Sends a confirmed proposal. Call this ONLY from the confirmation UI,
    /// after the user pressed Confirm. Re-fetches the item by ID.
    static func confirmAndDispatch(
        destination: String,
        actionItemID: UUID,
        meetingTitle: String,
        title: String,
        note: String,
        settings: AppSettings,
        eventKitManager: EventKitManager,
        modelContext: ModelContext
    ) async throws {
        guard let item = LiveModel.actionItem(actionItemID, in: modelContext) else {
            throw DispatchError.notConfigured("This action item")
        }
        try await ActionItemDispatcher.dispatch(
            item: item,
            meetingTitle: meetingTitle,
            destination: destination,
            settings: settings,
            eventKitManager: eventKitManager,
            modelContext: modelContext,
            titleOverride: title,
            note: note
        )
        // Re-fetch: the dispatch awaited.
        LiveModel.actionItem(actionItemID, in: modelContext)?.confirmedDestination = destination
        try? modelContext.save()
    }

    /// Turns a "Comment to AI" run's result into the board's proposal.
    static func proposal(from result: AgentHarness.Result, itemTitle: String) -> ActionProposal? {
        if let drafted = result.proposals.last {
            let note = drafted.body.isEmpty ? nil : drafted.body
            let title = drafted.title.isEmpty ? itemTitle : drafted.title
            let kind: ActionProposal.Kind = drafted.destination == "email" ? .email : .dispatch(destination: drafted.destination)
            return ActionProposal(kind: kind, title: title, note: note, byAI: true)
        }
        if let move = result.pendingActions.last(where: { $0.toolName == "update_action_item_status" }),
           case .success(let arguments) = LidIATools.updateActionItemStatus.spec.validate(move.argumentsJSON),
           let board = arguments.string("status").flatMap(LidIATools.boardStatus) {
            return ActionProposal(kind: .move(board), title: itemTitle, byAI: true)
        }
        return nil
    }
}
