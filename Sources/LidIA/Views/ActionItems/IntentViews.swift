import SwiftData
import SwiftUI

// MARK: - Runtime

/// Builds the engine's environment from what a view has, and decides when
/// a model may draft (never in design snapshots unless asked).
@MainActor
enum IntentRuntime {
    #if DEBUG
    /// Snapshot runs use a fixed calendar.
    static var calendarOverride: (any IntentCalendarSource)?
    #endif

    static func calendar(eventKit: EventKitManager, google: GoogleCalendarMonitor?, settings: AppSettings) -> any IntentCalendarSource {
        #if DEBUG
        if let calendarOverride { return calendarOverride }
        #endif
        return LiveIntentCalendar(eventKit: eventKit, google: google, hidden: settings.hiddenCalendarIDs)
    }

    static var modelDraftsAllowed: Bool {
        if SnapshotRun.isActive { return ProcessInfo.processInfo.environment["LIDIA_INTENTS_MODEL"] == "1" }
        return true
    }

    static func refresh(
        meetingIDs: [UUID],
        settings: AppSettings,
        modelManager: ModelManager?,
        eventKit: EventKitManager,
        google: GoogleCalendarMonitor?,
        modelContext: ModelContext
    ) {
        guard !meetingIDs.isEmpty else { return }
        IntentEngine.shared.scheduleRefresh(meetingIDs: meetingIDs, environment: .init(
            settings: settings,
            modelManager: modelManager,
            calendar: calendar(eventKit: eventKit, google: google, settings: settings),
            modelContext: modelContext,
            useModel: modelDraftsAllowed,
            keepCached: SnapshotRun.isActive
        ))
    }

    /// Changes when anything an intent reads changes.
    static func fingerprint(_ rows: [(ActionItem, Meeting)]) -> Int {
        var hasher = Hasher()
        for (item, meeting) in rows where !item.isDeleted && !item.isCompleted {
            hasher.combine(item.id)
            hasher.combine(item.title)
            hasher.combine(item.assignee)
            hasher.combine(meeting.summary.count)
        }
        return hasher.finalize()
    }
}

extension ActionIntent.Destination {
    var symbol: String {
        switch id {
        case "gmail", "mail": "envelope.fill"
        case "slack": "number"
        case "calendar", "calendarApp": "calendar"
        case "linear": "line.3.horizontal.decrease.circle.fill"
        case "clickup": "checkmark.square.fill"
        case "notion": "doc.richtext.fill"
        case "n8n": "point.3.connected.trianglepath.dotted"
        default: "checklist"
        }
    }

    var tint: Color {
        switch id {
        case "gmail": .red
        case "mail": .blue
        case "slack": .purple
        case "calendar", "calendarApp": .orange
        case "linear": .indigo
        case "clickup": .pink
        case "notion": Color(white: 0.35)
        default: .green
        }
    }
}

// MARK: - On a card or row

/// The prepared next step under an action item: the one button, a preview
/// of what it will do, and where in the transcript it comes from. Flagged
/// items ask Keep or Dismiss instead.
struct IntentSummaryView: View {
    let item: ActionItem
    let meeting: Meeting
    var compact = false
    /// Off where the corrected title is already the headline (For You).
    var showsDirectionFix = true
    var onDismissItem: () -> Void
    var onOpen: (ActionIntent) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    private var store: IntentStore { IntentStore.shared }
    private var intent: ActionIntent? { store.intent(for: item.id) }

    var body: some View {
        if let intent {
            VStack(alignment: .leading, spacing: 7) {
                if let verdict = store.needsReview(item.id) {
                    reviewFlag(verdict, intent: intent)
                } else {
                    if showsDirectionFix, let suggested = intent.suggestedTitle, suggested != item.title {
                        directionFix(suggested, intent: intent)
                    }
                    primaryRow(intent)
                    preview(intent)
                }
                if let evidence = intent.bestEvidence, intent.verdict != .notFound {
                    evidenceLine(evidence)
                }
            }
        } else if IntentEngine.shared.working.contains(item.id) {
            Label("Preparing…", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Pieces

    private func primaryRow(_ intent: ActionIntent) -> some View {
        HStack(spacing: 6) {
            Button {
                if let destination = intent.primaryDestination, !destination.configured {
                    IntentActions.connect(destination)
                } else {
                    onOpen(intent)
                }
            } label: {
                Label(intent.primaryLabel, systemImage: intent.primaryDestination?.symbol ?? "sparkles")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            // Her red for the one next step; the symbol says which tool it goes to.
            .tint(intent.needsConnection ? .gray : Brand.red)
            .controlSize(.small)
            .help(intent.primaryDestination?.reason ?? "")
            if IntentEngine.shared.working.contains(item.id) {
                ProgressView().controlSize(.mini).help("Drafting…")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func preview(_ intent: ActionIntent) -> some View {
        switch intent.artifact {
        case .calendarChange(let proposal):
            if let start = proposal.currentStart, let slot = proposal.slots.first {
                Text("\(start.formatted(.dateTime.weekday(.abbreviated).hour().minute())) → \(slot.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))\(proposal.slots.count > 1 ? " · \(proposal.slots.count - 1) more" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let note = proposal.note {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        case .message(_, let body), .document(_, let body), .ticket(_, let body):
            Text(Self.previewText(body))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(compact ? 1 : 2)
        case .research(let notes):
            Text(Self.previewText(notes)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case .reminder, .none:
            EmptyView()
        }
    }

    /// The draft without its greeting.
    static func previewText(_ body: String) -> String {
        let lines = body.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let content = lines.first.map { $0.lowercased().hasPrefix("hi ") || $0.lowercased().hasPrefix("hello") } == true ? Array(lines.dropFirst()) : lines
        return content.prefix(3).joined(separator: " ")
    }

    private func evidenceLine(_ evidence: ActionIntent.Evidence) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "quote.opening")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("\(evidence.saidLabel()): “\(evidence.quote)”")
                .font(.caption)
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(compact ? 1 : 2)
                .help(evidence.quote)
        }
    }

    private func directionFix(_ suggested: String, intent: ActionIntent) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.uturn.right")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text("You owe this: “\(suggested)”")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Fix") {
                item.title = suggested
                if !settings.displayName.isEmpty { item.assignee = settings.displayName }
                try? modelContext.save()
            }
            .buttonStyle(.accentLink)
            .font(.caption)
            .help("Use the corrected title and make you the owner")
        }
    }

    private func reviewFlag(_ verdict: ActionIntent.Verdict, intent: ActionIntent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(.orange)
                Text(Self.reviewText(verdict))
                    .font(.caption.weight(.medium))
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button("Keep") { withAnimation { store.keep(item.id) } }
                    .buttonStyle(.glass)
                Button("Dismiss", role: .destructive) { onDismissItem() }
                    .buttonStyle(.glass)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    static func reviewText(_ verdict: ActionIntent.Verdict) -> String {
        switch verdict {
        case .notFound: "Not found in the transcript: keep?"
        case .weak: "Not clearly in the transcript: keep?"
        case .doneInMeeting: "Looks done during the meeting: keep?"
        case .supported: ""
        }
    }
}

// MARK: - For You

/// A prepared next step on Today: what it is, for whom and where, the draft,
/// the evidence and the one button.
struct IntentForYouCard: View {
    let candidate: IntentSuggestions.Candidate
    let item: ActionItem
    let meeting: Meeting
    var onOpen: (ActionIntent) -> Void
    var onOpenMeeting: () -> Void

    private var intent: ActionIntent { candidate.intent }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                SettingsIconTile(symbol: intent.primaryDestination?.symbol ?? "sparkles", tint: intent.primaryDestination?.tint ?? Brand.red, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NEXT STEP · \(intent.kind.label.uppercased())")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(intent.primaryDestination?.tint ?? Brand.red)
                    Text(intent.suggestedTitle ?? item.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text([intent.recipientLabel.map { "For \($0)" }, intent.primaryDestination?.reason, meeting.title.trimmingCharacters(in: .whitespaces)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            IntentSummaryView(item: item, meeting: meeting, showsDirectionFix: false, onDismissItem: {}, onOpen: onOpen)
            HStack {
                Button("Open Meeting", action: onOpenMeeting)
                    .buttonStyle(.link)
                    .font(.caption)
                Spacer()
                Text("Confidence \(Int((intent.confidence * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help(intent.confidenceReasons.joined(separator: "\n"))
            }
        }
        .padding(16)
        .lidiaCard()
    }
}

// MARK: - Confirmation

/// Everything an intent prepared, editable, and the one button that runs it.
/// Nothing happens until Confirm.
struct IntentConfirmSheet: View {
    let intent: ActionIntent
    let item: ActionItem
    let meeting: Meeting

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(EventKitManager.self) private var eventKitManager
    @Environment(GoogleCalendarMonitor.self) private var googleCalendarMonitor
    @Environment(\.modelContext) private var modelContext

    @State private var edited = IntentActions.Edited(destinationID: "", subject: "", body: "", slot: nil)
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var outcome: IntentActions.Outcome?

    #if DEBUG
    /// Snapshot runs open the sheet without a window to host it.
    static var snapshotOutcome: IntentActions.Outcome?
    #endif

    private var destination: ActionIntent.Destination? { intent.destinations.first { $0.id == edited.destinationID } }
    private var blocked: Bool { IntentActions.isBlockedByLocalOnly(edited.destinationID, localOnly: settings.localOnlyMode) }
    private var proposal: ActionIntent.CalendarProposal? {
        if case .calendarChange(let proposal) = intent.artifact { return proposal }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let proposal {
                calendarSection(proposal)
                if ["gmail", "mail"].contains(edited.destinationID) { draftSection }
            } else {
                draftSection
            }
            if !intent.links.isEmpty { linksSection }
            evidenceSection
            footer
        }
        .padding(20)
        .frame(width: 520)
        .task(id: intent.itemID) {
            edited = IntentActions.initialEdit(for: intent, sender: settings.displayName)
            SiriCues.preparedNextStep(item)
        }
        .onChange(of: edited.destinationID) { old, new in
            // Switching between a calendar move and an email reshapes the draft.
            guard !old.isEmpty, proposal != nil else { return }
            edited = IntentActions.initialEdit(for: intent, destinationID: new, sender: settings.displayName)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsIconTile(symbol: destination?.symbol ?? "sparkles", tint: destination?.tint ?? Brand.red, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(IntentDestinationRanker.primaryLabel(
                    kind: intent.kind, direction: intent.direction, destination: destination,
                    recipientLabel: intent.recipientLabel, proposal: proposal, title: intent.suggestedTitle ?? item.title
                ))
                .font(.title3.weight(.semibold))
                Text("For “\(item.title)”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if intent.destinations.count > 1 {
                Picker("Send with", selection: $edited.destinationID) {
                    ForEach(intent.destinations) { option in
                        Text(option.configured ? option.name : "\(option.name) (not connected)").tag(option.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help(destination?.reason ?? "")
            }
        }
    }

    @ViewBuilder
    private var draftSection: some View {
        let people = proposal?.attendees ?? intent.recipients
        if !people.isEmpty, ["gmail", "mail", "slack"].contains(edited.destinationID) {
            LabeledContent("To") {
                Text(edited.destinationID == "slack" ? settings.slackChannel : people.map { $0.email ?? $0.name }.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .font(.callout)
        }
        TextField(edited.destinationID == "slack" ? "Title (not posted)" : "Subject or title", text: $edited.subject)
            .textFieldStyle(.roundedBorder)
        TextEditor(text: $edited.body)
            .font(.body)
            .frame(minHeight: 150, maxHeight: 260)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        if let note = intent.linkNote, intent.links.isEmpty {
            Label("\(note): LidIA only links pages a web search found\(IntentEngine.wantsDraft(intent) ? "" : "").", systemImage: "link.badge.plus")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let model = intent.draftedBy {
            Label("Drafted by \(model)\(intent.usedWebSearch ? " with a web search" : ""). Check it before you send.", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func calendarSection(_ proposal: ActionIntent.CalendarProposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let start = proposal.currentStart, let end = proposal.currentEnd {
                LabeledContent("Now") {
                    Text("\(proposal.eventTitle) · \(start.formatted(.dateTime.weekday(.wide).month().day().hour().minute()))–\(end.formatted(.dateTime.hour().minute()))")
                        .foregroundStyle(.secondary)
                }
            }
            if !proposal.slots.isEmpty {
                Text(proposal.editable ? "Move to" : "Free times to propose")
                    .font(.callout.weight(.medium))
                ForEach(proposal.slots, id: \.self) { slot in
                    Button {
                        edited.slot = slot
                    } label: {
                        HStack {
                            Image(systemName: edited.slot == slot ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(edited.slot == slot ? Color.accentColor : .secondary)
                            Text("\(slot.start.formatted(.dateTime.weekday(.wide).month().day())) · \(slot.start.formatted(.dateTime.hour().minute()))–\(slot.end.formatted(.dateTime.hour().minute()))")
                            Spacer()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let note = proposal.note {
                Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !proposal.attendees.isEmpty {
                Text("With \(proposal.attendees.map { $0.email ?? $0.name }.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Links from a web search").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            ForEach(intent.links, id: \.self) { link in
                Link(link.title, destination: link.url).font(.callout).lineLimit(1)
            }
        }
    }

    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let evidence = intent.bestEvidence {
                Text("\(evidence.saidLabel()): “\(evidence.quote)”")
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("Confidence \(Int((intent.confidence * 100).rounded()))% · " + intent.confidenceReasons.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if blocked {
            LocalOnlyModeBanner(message: "Local-only mode is on, so nothing is sent to \(destination?.name ?? "this destination"). Pick Mail to open it as a draft instead.")
        } else if let destination {
            Label(Self.flowText(destination, settings: settings), systemImage: "arrow.up.forward.app")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
        }
        HStack {
            if case .done(let text)? = outcome {
                Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            } else if case .handedOff(let text)? = outcome {
                Label(text, systemImage: "arrow.up.forward.app").foregroundStyle(.secondary).font(.callout)
            }
            Spacer()
            if let proposal, case .done? = outcome, let slot = edited.slot, !proposal.attendees.isEmpty {
                Button("Email Attendees…") {
                    let note = IntentActions.attendeeNote(for: proposal, slot: slot, sender: settings.displayName)
                    MailComposer.open(to: proposal.attendees.compactMap(\.email), subject: note.subject, body: note.body)
                    dismiss()
                }
            }
            Button(outcome == nil ? "Cancel" : "Close", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if outcome == nil {
                Button {
                    run()
                } label: {
                    if isRunning { ProgressView().controlSize(.small) } else { Text(confirmTitle) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning || blocked || !(destination?.configured ?? false) || (proposal != nil && proposal?.editable == true && edited.slot == nil))
            }
        }
    }

    private var confirmTitle: String {
        switch edited.destinationID {
        case "gmail": "Open in Gmail"
        case "mail": "Open in Mail"
        case "slack": "Post to Slack"
        case "linear": "Create Issue"
        case "clickup": "Create Task"
        case "notion": intent.kind == .document || intent.kind == .research ? "Create Page" : "Add to Notion"
        case "n8n": "Send"
        case "calendar": edited.slot.map { "Move to \($0.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))" } ?? "Move"
        case "calendarApp": proposal?.source == "google" ? "Open Google Calendar" : "Open Calendar"
        default: "Add Reminder"
        }
    }

    static func flowText(_ destination: ActionIntent.Destination, settings: AppSettings) -> String {
        switch destination.id {
        case "gmail": "Opens the draft in Gmail in your browser. Nothing is sent until you send it there."
        case "mail": "Opens the draft in your mail app. Nothing is sent until you send it there."
        case "slack": "Posts this text to \(settings.slackChannel)."
        case "linear", "clickup", "n8n": "Sends this title and text to \(destination.name)."
        case "notion": "Creates a page with this title and text in Notion."
        case "calendar": "Moves the event in your calendar. If you organize it, attendees' invites update."
        case "calendarApp": "Opens your calendar. LidIA changes nothing."
        default: "Adds a reminder on this Mac."
        }
    }

    private func run() {
        guard let liveItem = LiveModel.actionItem(item.id, in: modelContext) else { dismiss(); return }
        isRunning = true
        errorMessage = nil
        let calendar = IntentRuntime.calendar(eventKit: eventKitManager, google: googleCalendarMonitor, settings: settings)
        Task { @MainActor in
            defer { isRunning = false }
            do {
                // The only path that sends: the user pressed Confirm.
                outcome = try await IntentActions.perform(
                    intent, edited: edited, item: liveItem, meetingTitle: meeting.title,
                    settings: settings, eventKitManager: eventKitManager, calendar: calendar, modelContext: modelContext
                )
                if case .handedOff = outcome { dismiss() }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
