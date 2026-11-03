import Foundation
import LidIAKit
import SwiftData
import SwiftUI

/// Follow-ups for Siri, reusing what the app already does: the Intents
/// engine's prepared next step for an action item, and `FollowUpPlanner`'s
/// recap email for a meeting. Both open a sheet in LidIA; nothing is sent
/// until the user chooses to.
@MainActor
enum MacFollowUps {
    struct Plan {
        var request: SiriRouter.Request
        var spoken: String
    }

    /// For a meeting: the engine's draft when the meeting has an open "send the
    /// recap" item (it already knows who and what), else the recap email.
    static func plan(for meeting: Meeting, settings: AppSettings, context: ModelContext) -> Plan {
        let recapItem = meeting.actionItems.first { !$0.isDeleted && !$0.isCompleted && FollowUpPlanner.isRecapPromise($0.title) }
        if let recapItem, let host = MacSiriHost.shared {
            let intent = nextStep(for: recapItem, host: host)
            return Plan(request: .nextStep(itemID: recapItem.id), spoken: spoken(intent, itemTitle: recapItem.title))
        }
        let draft = followUpDraft(for: meeting, settings: settings, context: context)
        let to = draft.recipients.first.map { " to \($0.name)" } ?? ""
        return Plan(
            request: .followUp(meetingID: meeting.id),
            spoken: "I drafted the follow-up\(to) in LidIA. Check it there; nothing is sent until you open it in Mail."
        )
    }

    /// The recap email for one meeting, as the Today card would draft it.
    static func followUpDraft(for meeting: Meeting, settings: AppSettings, context: ModelContext) -> FollowUpPlanner.Draft {
        let all = ((try? context.fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? [])
            .prefix(400)
            .map { MeetingSignals($0) }
        let signals = MeetingSignals(meeting)
        let context = ProjectSuggester.Context.build(Array(all))
        return FollowUpPlanner.draft(for: signals, among: Array(all), context: context, senderName: settings.displayName)
    }

    /// The item's prepared next step: the cached one, else built now without a
    /// model (the engine drafts with a model in the background afterwards).
    @discardableResult
    static func nextStep(for item: ActionItem, host: MacSiriHost) -> ActionIntent? {
        guard let meeting = item.meeting else { return nil }
        let store = IntentStore.shared
        if let cached = store.intent(for: item.id) { return cached }
        let settings = host.settings
        guard let input = IntentEngine.inputs(for: meeting, items: [item], userName: settings.displayName, store: store).first else { return nil }
        let connections = IntentConnections.current(settings: settings)
        let calendar = host.eventKitManager.map {
            IntentRuntime.calendar(eventKit: $0, google: host.googleCalendarMonitor, settings: settings)
        }
        var intent = IntentBuilder.build(input, connections: connections, events: IntentEngine.calendarEvents(calendar, now: .now))
        intent.inputFingerprint = IntentEngine.fingerprint(input, connections: connections, now: .now)
        store.setIntent(intent)
        if let eventKit = host.eventKitManager {
            IntentRuntime.refresh(
                meetingIDs: [meeting.id], settings: settings, modelManager: host.modelManager,
                eventKit: eventKit, google: host.googleCalendarMonitor, modelContext: host.context
            )
        }
        return intent
    }

    /// What Siri says about a prepared step (no meeting content, just what and to whom).
    static func spoken(_ intent: ActionIntent?, itemTitle: String) -> String {
        guard let intent else { return "I opened \u{201C}\(itemTitle)\u{201D} in LidIA." }
        let who = intent.recipientLabel ?? intent.recipients.first?.name
        let what: String
        switch intent.artifact {
        case .message: what = who.map { "an email to \($0)" } ?? "an email"
        case .calendarChange: what = "a calendar change"
        case .ticket: what = "a ticket"
        case .document: what = "a page"
        case .reminder: what = "a reminder"
        case .research: what = "research notes"
        case .none: what = "the next step"
        }
        return "I prepared \(what) for \u{201C}\(itemTitle)\u{201D}. Review it in LidIA; nothing is sent until you confirm."
    }
}

/// The meeting's follow-up email, editable, with Open in Mail and Copy. The
/// sheet Siri's "Draft Follow-Up" opens when no action item covers it.
struct SiriFollowUpSheet: View {
    let meeting: Meeting

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @State private var to = ""
    @State private var subject = ""
    @State private var messageBody = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "envelope.fill").foregroundStyle(Brand.red)
                Text("Follow-up for \u{201C}\(meeting.title)\u{201D}").font(.headline).lineLimit(1)
            }
            Text("Drafted on this Mac from the meeting notes. Nothing is sent until you open it in Mail and send it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            LabeledContent("To") {
                TextField("Recipients", text: $to).textFieldStyle(.roundedBorder)
            }
            LabeledContent("Subject") {
                TextField("Subject", text: $subject).textFieldStyle(.roundedBorder)
            }
            TextEditor(text: $messageBody)
                .font(.body)
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Copy") {
                    MailComposer.copy(subject: subject, body: messageBody)
                    dismiss()
                }
                Button("Open in Mail") {
                    let recipients = to.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    _ = MailComposer.open(to: recipients, subject: subject, body: messageBody)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .tint(Brand.red)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let draft = MacFollowUps.followUpDraft(for: meeting, settings: settings, context: modelContext)
            to = draft.recipients.compactMap(\.email).joined(separator: ", ")
            subject = draft.subject
            messageBody = draft.body
        }
    }
}
