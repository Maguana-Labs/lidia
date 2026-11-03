import EventKit
import SwiftData
import SwiftUI

/// Today: Coming up first (today and the next days, every meeting, with
/// Join/Record and the meeting's project), then anything that needs
/// attention, LidIA's suggestions with their reasons (follow-up emails, new
/// projects, patterns, briefs), meetings to pick up again and open action
/// items. Says plainly when no calendar is connected.
struct TodayView: View {
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @Query(filter: #Predicate<ActionItem> { !$0.isCompleted }) private var openActionItems: [ActionItem]
    @Query(filter: #Predicate<InboxNotification> { !$0.isRead }, sort: \InboxNotification.createdAt, order: .reverse)
    private var unreadNotifications: [InboxNotification]

    @Environment(AppSettings.self) private var settings
    @Environment(RecordingSession.self) private var session
    @Environment(EventKitManager.self) private var eventKitManager
    @Environment(GoogleCalendarMonitor.self) private var googleCalendarMonitor
    @Environment(ModelManager.self) private var modelManager
    @Environment(\.modelContext) private var modelContext

    let agenda: [AgendaEvent]
    var onOpenEvent: (AgendaEvent) -> Void
    var onRecordEvent: (AgendaEvent, _ join: Bool) -> Void
    var onRecordNow: () -> Void
    var onStopRecording: () -> Void
    var onOpenMeeting: (Meeting) -> Void
    var onRetryMeeting: (Meeting) -> Void
    var onNewNote: () -> Void
    var onOpenActionItems: () -> Void
    var onOpenLibrary: () -> Void = {}
    var onOpenProject: (String) -> Void = { _ in }
    var onOpenSeries: (String) -> Void = { _ in }
    var onAsk: (String) -> Void = { _ in }

    @State private var intelligence = IntelligenceResults.empty
    @State private var showsAllSuggestions = false
    @State private var intentSheet: IntentSheetItem?

    /// Every open item with a prepared intent.
    private var intentCandidates: [IntentSuggestions.Candidate] {
        openActionItems.compactMap { item in
            guard !item.isDeleted, let meeting = item.meeting, let intent = IntentStore.shared.intent(for: item.id) else { return nil }
            return IntentSuggestions.Candidate(intent: intent, itemTitle: item.title, meetingID: meeting.id, meetingDate: meeting.date)
        }
    }

    /// The intents For You shows (recent, ready, not already a follow-up card).
    private var pickedIntents: [IntentSuggestions.Candidate] {
        IntentSuggestions.pick(intentCandidates, followUpMeetingIDs: Set(intelligence.followUps.map(\.meetingID)))
    }

    /// Recent meetings with open items: their intents are worked out in the background.
    private var recentIntentMeetingIDs: [UUID] {
        let cutoff = Date.now.addingTimeInterval(-Double(IntentSuggestions.maxAgeDays) * 86_400)
        var ids: [UUID] = []
        for item in openActionItems where !item.isDeleted {
            if let meeting = item.meeting, meeting.date >= cutoff, meeting.status == .complete, !ids.contains(meeting.id) { ids.append(meeting.id) }
        }
        return ids
    }

    private var isCalendarConnected: Bool {
        googleCalendarMonitor.isSignedIn
            || (settings.calendarEnabled && eventKitManager.calendarAuthorizationStatus == .fullAccess)
    }

    /// Briefs and drafts worth acting on; "meeting processed" receipts aren't suggestions.
    private var inboxSuggestions: [InboxNotification] {
        let intents = intentCandidates
        return unreadNotifications.filter { notification in
            guard !notification.isDeleted, notification.type != "processed" else { return false }
            // A card about an item that now has an intent would show it twice.
            if ["follow_up", "ticket", "reminder"].contains(notification.type),
               IntentSuggestions.isCoveredByIntent(actionItemTitle: notification.sourceActionItemTitle, meetingID: notification.meetingID, intents: intents) {
                return false
            }
            return true
        }
    }

    private var attentionMeetings: [Meeting] {
        MeetingListModel.attentionItems(meetings)
    }

    private var recentMeetings: [Meeting] {
        Array(meetings.lazy.filter { $0.status == .complete && !$0.isDeleted }.prefix(3))
    }

    /// Due today or overdue first, then urgent, then the newest.
    private var topActionItems: [ActionItem] {
        let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)) ?? .now
        return openActionItems
            .filter { !$0.isDeleted }
            .sorted { lhs, rhs in
                func rank(_ item: ActionItem) -> Int {
                    if let deadline = item.deadlineDate, deadline < endOfToday { return 0 }
                    return item.isUrgent ? 1 : 2
                }
                let (l, r) = (rank(lhs), rank(rhs))
                if l != r { return l < r }
                return (lhs.meeting?.date ?? .distantPast) > (rhs.meeting?.date ?? .distantPast)
            }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    header(now: context.date)
                    if session.isRecording { recordingCard }
                    comingUpSection(now: context.date)
                    if !attentionMeetings.isEmpty { needsAttentionSection }
                    if suggestionCount > 0 { forYouSection }
                    if !recentMeetings.isEmpty { recentSection }
                    if !openActionItems.isEmpty { actionItemsSection }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle("Today")
        .intelligence(meetings: meetings, events: agenda, results: $intelligence, autoAssign: true)
        .task(id: recentIntentMeetingIDs) {
            IntentRuntime.refresh(
                meetingIDs: recentIntentMeetingIDs, settings: settings, modelManager: modelManager,
                eventKit: eventKitManager, google: googleCalendarMonitor, modelContext: modelContext
            )
        }
        .sheet(item: $intentSheet) { sheet in
            IntentConfirmSheet(intent: sheet.intent, item: sheet.item, meeting: sheet.meeting)
        }
    }

    // MARK: - Header

    private func header(now: Date) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(greeting(now: now))
                    .font(.system(size: 30, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                Button(action: onNewNote) {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .buttonStyle(.glass)
                .help("Write a note without recording (⌘N)")
                if !session.isRecording {
                    Button(action: onRecordNow) {
                        Label("Record", systemImage: "record.circle")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Brand.red)
                    .help("Start recording now (⌘R)")
                }
            }
            .controlSize(.large)
        }
    }

    private func greeting(now: Date) -> String {
        let hour = Calendar.current.component(.hour, from: now)
        let name = settings.displayName.components(separatedBy: " ").first ?? ""
        let prefix = switch hour {
        case 0..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
        return name.isEmpty ? prefix : "\(prefix), \(name)"
    }

    private var recordingCard: some View {
        HStack(spacing: 12) {
            Circle().fill(Brand.red).frame(width: 9, height: 9)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.currentMeeting.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "Recording")
                    .font(.headline)
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text((session.isPaused ? "Paused · " : "Recording · ") + ElapsedFormat.string(session.elapsedTime))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Button("Open Notes") {
                if let meeting = session.currentMeeting { onOpenMeeting(meeting) }
            }
            .buttonStyle(.glass)
            Button(role: .destructive, action: onStopRecording) {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.glassProminent)
            .tint(Brand.red)
            .help("Stop recording (⌘R)")
        }
        .padding(14)
        .lidiaCard(tint: Brand.red)
    }

    // MARK: - Coming up

    @ViewBuilder
    private func comingUpSection(now: Date) -> some View {
        if !isCalendarConnected && agenda.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("Coming up")
                connectCalendarCard
            }
        } else {
            ComingUpCard(
                agenda: agenda,
                now: now,
                eventProjects: intelligence.eventProjects,
                isRecording: session.isRecording,
                onOpenEvent: onOpenEvent,
                onRecordEvent: onRecordEvent
            )
        }
    }

    private var connectCalendarCard: some View {
        HStack(alignment: .top, spacing: 14) {
            SettingsIconTile(symbol: "calendar", tint: Brand.red, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect a calendar")
                    .font(.headline)
                Text("See today's and the coming days' meetings here with a one-click Record, and get a nudge before each one. LidIA reads Apple Calendar or Google Calendar on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Connect Calendar…") {
                    SettingsRouter.shared.open(.calendars)
                }
                .buttonStyle(.glassProminent)
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .lidiaCard()
    }

    // MARK: - For you (on-device suggestions)

    private enum Suggestion: Identifiable {
        case followUp(FollowUpPlanner.Draft)
        case cluster(ProjectSuggester.Cluster)
        case pattern(PatternDetector.Pattern)
        case inbox(InboxNotification)
        case intent(IntentSuggestions.Candidate)

        var id: String {
            switch self {
            case .intent(let candidate): "intent:" + candidate.intent.itemID.uuidString
            case .followUp(let draft): draft.id
            case .cluster(let cluster): "cluster:" + cluster.id
            case .pattern(let pattern): pattern.id
            case .inbox(let notification): "inbox:" + notification.id.uuidString
            }
        }
    }

    /// Most useful first: what to send, what's next, how to organise, then the rest.
    private var suggestions: [Suggestion] {
        let reviews = intelligence.patterns.filter { if case .seriesReview = $0.kind { return true } else { return false } }
        let stale = intelligence.patterns.filter { if case .staleItems = $0.kind { return true } else { return false } }
        var result: [Suggestion] = []
        result += intelligence.followUps.prefix(2).map(Suggestion.followUp)
        result += pickedIntents.map(Suggestion.intent)
        result += reviews.prefix(1).map(Suggestion.pattern)
        result += intelligence.clusters.prefix(2).map(Suggestion.cluster)
        result += stale.prefix(2).map(Suggestion.pattern)
        result += inboxSuggestions.prefix(3).map(Suggestion.inbox)
        result += intelligence.followUps.dropFirst(2).map(Suggestion.followUp)
        result += intelligence.clusters.dropFirst(2).map(Suggestion.cluster)
        return result
    }

    private var suggestionCount: Int {
        intelligence.followUps.count + intelligence.patterns.count + intelligence.clusters.count + inboxSuggestions.count + pickedIntents.count
    }

    private var forYouSection: some View {
        let all = suggestions
        let visible = showsAllSuggestions ? all : Array(all.prefix(4))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sectionHeader("For You")
                Label("On this Mac", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("LidIA finds these from your own meetings, on this Mac. Nothing is sent anywhere.")
                Spacer()
                if all.count > 4 {
                    Button(showsAllSuggestions ? "Show Fewer" : "Show All \(all.count)") {
                        withAnimation(.easeOut(duration: 0.15)) { showsAllSuggestions.toggle() }
                    }
                    .buttonStyle(.accentLink)
                    .font(.callout)
                }
            }
            ForEach(visible) { suggestion in
                suggestionCard(suggestion)

            }
        }
    }

    @ViewBuilder
    private func suggestionCard(_ suggestion: Suggestion) -> some View {
        switch suggestion {
        case .followUp(let draft):
            FollowUpCard(draft: draft) {
                if let meeting = meetings.first(where: { $0.id == draft.meetingID }) { onOpenMeeting(meeting) }
            }
        case .cluster(let cluster):
            let members = meetings.filter { cluster.meetingIDs.contains($0.id) }
            ClusterCard(
                cluster: cluster,
                meetingTitles: Array(Set(members.map { $0.title.trimmingCharacters(in: .whitespaces) })).sorted(),
                companies: Array(Set(members.flatMap { AttendeeGrouping.externalCompanies($0.libraryAttendees) })).sorted(),
                onCreate: { name in
                    withAnimation {
                        IntelligenceEngine.assign(cluster.meetingIDs, to: name, in: meetings, store: .shared, context: modelContext)
                    }
                    onOpenProject(name)
                }
            )
        case .pattern(let pattern):
            switch pattern.kind {
            case .seriesReview(let key, let title, _, _):
                PatternCard(
                    pattern: pattern,
                    onPrimary: { onOpenSeries(key) },
                    onAsk: { onAsk("Recap the last 3 “\(title)” meetings: what was decided, what's still open, and what I should raise next time.") }
                )
            case .staleItems(let group, _, let project):
                PatternCard(
                    pattern: pattern,
                    onPrimary: {
                        if let project { onOpenProject(project) } else { onOpenActionItems() }
                    },
                    onAsk: { onAsk("Which of my open \(group) action items are blocked, and what would unblock them?") }
                )
            }
        case .inbox(let notification):
            InsightCard(notification: notification, onOpenMeeting: { id in
                if let meeting = meetings.first(where: { $0.id == id }) { onOpenMeeting(meeting) }
            })
        case .intent(let candidate):
            if let item = openActionItems.first(where: { $0.id == candidate.intent.itemID }), let meeting = item.meeting {
                IntentForYouCard(
                    candidate: candidate, item: item, meeting: meeting,
                    onOpen: { intentSheet = IntentSheetItem(intent: $0, item: item, meeting: meeting) },
                    onOpenMeeting: { onOpenMeeting(meeting) }
                )
            }
        }
    }

    // MARK: - Needs attention

    private var needsAttentionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Needs Attention")
            VStack(spacing: 0) {
                ForEach(Array(attentionMeetings.enumerated()), id: \.element.id) { index, meeting in
                    if index > 0 { Divider() }
                    HStack(spacing: 10) {
                        Button {
                            onOpenMeeting(meeting)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(meeting.title.isEmpty ? "Untitled" : meeting.title)
                                        .lineLimit(1)
                                    MeetingStatusBadge(status: meeting.status)
                                }
                                Text(meeting.processingError ?? meeting.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the meeting")

                        if meeting.status == .failed || meeting.status == .queued {
                            Button {
                                onRetryMeeting(meeting)
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.glass)
                            .help(meeting.rawTranscript.isEmpty
                                  ? "Transcribe the saved recording and write the notes"
                                  : "Process this meeting again")
                            .accessibilityLabel("Retry \(meeting.title.isEmpty ? "Untitled" : meeting.title)")
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 14)
            .lidiaCard(tint: .orange)
        }
    }

    // MARK: - Pick up where you left off

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("Recent Meetings")
                Spacer()
                Button("All Meetings", action: onOpenLibrary)
                    .buttonStyle(.accentLink)
                    .font(.callout)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(recentMeetings) { meeting in
                    RecentMeetingCard(meeting: meeting) { onOpenMeeting(meeting) }
                }
            }
        }
    }

    // MARK: - Action items

    private var actionItemsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("Open Action Items")
                Text("\(openActionItems.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("View All", action: onOpenActionItems)
                    .buttonStyle(.accentLink)
                    .font(.callout)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(topActionItems.prefix(5)) { item in
                    DueActionItemRow(item: item, onOpenMeeting: onOpenMeeting)
                }
            }
            .padding(14)
            .lidiaCard()
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Recent meeting card

private struct RecentMeetingCard: View {
    let meeting: Meeting
    var onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                Text(meeting.title.isEmpty ? "Untitled" : meeting.title.trimmingCharacters(in: .whitespaces))
                    .font(.callout.weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let project = meeting.projectName {
                    ProjectLabel(name: project)
                }
                Text(SummaryPreview.lines(from: meeting.userEditedSummary ?? meeting.summary, limit: 2).joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color.primary.opacity(hovering ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the meeting")
    }

    private var subtitle: String {
        var parts = [MeetingRowFormat.relativeDay(meeting.date)]
        if let who = MeetingRowFormat.withWhom(meeting.libraryAttendees) { parts.append(who) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Action item row

struct DueActionItemRow: View {
    @Bindable var item: ActionItem
    var onOpenMeeting: (Meeting) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle(isOn: $item.isCompleted) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .lineLimit(2)
                    if !meta.isEmpty {
                        Text(meta)
                            .font(.caption)
                            .foregroundStyle(isOverdue ? .red : .secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 8)
            if let meeting = item.meeting {
                Button {
                    onOpenMeeting(meeting)
                } label: {
                    Image(systemName: "arrow.up.right")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Open \(meeting.title)")
                .accessibilityLabel("Open meeting \(meeting.title)")
            }
        }
    }

    private var isOverdue: Bool {
        guard let deadline = item.deadlineDate else { return false }
        return deadline < Calendar.current.startOfDay(for: .now)
    }

    private var meta: String {
        var parts: [String] = []
        if let deadline = item.displayDeadline { parts.append("Due \(deadline)") }
        if let assignee = item.assignee, !assignee.isEmpty { parts.append(assignee) }
        if let meeting = item.meeting { parts.append(meeting.title.trimmingCharacters(in: .whitespaces)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Insight card

/// A meeting brief or follow-up draft from the dispatcher. Its controls are
/// always visible (not hover-only) so they work from the keyboard.
struct InsightCard: View {
    @Bindable var notification: InboxNotification
    var onOpenMeeting: ((UUID) -> Void)?
    @Environment(AppSettings.self) private var settings

    @State private var isEditing = false
    @State private var isExpanded = false
    @State private var editDraft = ""
    @State private var status: Status?

    private enum Status { case sending, sent, copied, failed }

    private var isBrief: Bool { notification.type == "meeting_prep" }
    private var tint: Color { isBrief ? Brand.red : Brand.ember }
    private var tileTint: Color { isBrief ? Brand.red : Brand.emberSolid }

    private var kindLabel: String {
        switch notification.type {
        case "meeting_prep": "Meeting brief"
        case "follow_up": "Follow-up draft"
        case "ticket": "Ticket draft"
        case "reminder": "Reminder"
        default: "Update"
        }
    }

    private var bodyText: String {
        (notification.draft ?? notification.body).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                SettingsIconTile(symbol: isBrief ? "doc.text.magnifyingglass" : "paperplane", tint: tileTint, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kindLabel.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint)
                    Text(notification.title.replacingOccurrences(of: "Prep: ", with: ""))
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    // Tickets go to a tracker, never "to" the user.
                    if let recipient = notification.recipient, notification.type != "ticket",
                       !IntentSuggestions.isSelfAddressed(recipient: recipient, userName: settings.displayName, userEmails: []) {
                        Text("To \(recipient)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    withAnimation { notification.isRead = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(.circle)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss \(notification.title)")
            }

            if isEditing {
                TextField("Edit draft", text: $editDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...10)
            } else if !bodyText.isEmpty {
                MarkdownBlockView(text: bodyText, textStyle: .secondary)
                    .lineLimit(isExpanded ? nil : 5)
                    .frame(maxHeight: isExpanded ? nil : 120, alignment: .top)
                    .clipped()
                    .mask(alignment: .top) {
                        if isExpanded || bodyText.count < 280 {
                            Rectangle()
                        } else {
                            LinearGradient(stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                        }
                    }
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                if let status {
                    statusLabel(status)
                } else {
                    if notification.isDispatchable && !isBrief {
                        if settings.n8nEnabled && !settings.n8nWebhookURL.isEmpty {
                            Button {
                                sendViaN8n()
                            } label: {
                                Label(n8nButtonLabel, systemImage: "paperplane.fill")
                            }
                            .buttonStyle(.glassProminent)
                        }
                        Button {
                            copyDraft()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.glass)
                        Button {
                            editDraft = notification.draft ?? notification.body
                            isEditing.toggle()
                        } label: {
                            Label(isEditing ? "Done" : "Edit", systemImage: "pencil")
                        }
                        .buttonStyle(.glass)
                    }
                    if let meetingID = notification.meetingID, let onOpenMeeting, isBrief == false {
                        Button("Open Meeting") { onOpenMeeting(meetingID) }
                            .buttonStyle(.glass)
                    }
                }
                Spacer(minLength: 0)
                if !isEditing && bodyText.count >= 280 {
                    Button(isExpanded ? "Show Less" : "Show More") {
                        withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                    }
                    .buttonStyle(.accentLink)
                    .font(.callout)
                }
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
    }

    private func statusLabel(_ status: Status) -> some View {
        let (text, image, color): (String, String, Color) = switch status {
        case .sending: ("Sending…", "arrow.up.circle", .secondary)
        case .sent: ("Sent", "checkmark.circle.fill", .green)
        case .copied: ("Copied", "checkmark.circle.fill", .green)
        case .failed: ("Couldn't send. Check the n8n webhook in Settings › Apps.", "xmark.circle", .red)
        }
        return Label(text, systemImage: image)
            .font(.callout.weight(.medium))
            .foregroundStyle(color)
    }

    private var currentDraft: String {
        isEditing ? editDraft : (notification.draft ?? notification.body)
    }

    private var n8nButtonLabel: String {
        switch notification.channel {
        case "slack": "Send to Slack"
        case "email": "Send Email"
        case "ticket": "Create Ticket"
        default: "Send via n8n"
        }
    }

    private func sendViaN8n() {
        let draft = currentDraft
        status = .sending
        let payload = N8nClient.DispatchPayload(
            channel: notification.channel ?? "reminder",
            recipient: notification.recipient,
            draft: draft,
            ticketTitle: notification.ticketTitle,
            meetingTitle: notification.sourceMeetingTitle,
            actionItemTitle: notification.sourceActionItemTitle,
            actionItemID: notification.id.uuidString
        )
        let webhookURL = settings.n8nWebhookURL
        let authHeader = settings.n8nAuthHeader.isEmpty ? nil : settings.n8nAuthHeader
        Task {
            let success = await N8nClient.sendDispatch(payload: payload, webhookURL: webhookURL, authHeader: authHeader)
            withAnimation { status = success ? .sent : .failed }
            if success {
                isEditing = false
                try? await Task.sleep(for: .seconds(2))
                withAnimation { notification.isRead = true }
            }
        }
    }

    private func copyDraft() {
        ExportService.copyToClipboard(currentDraft)
        withAnimation { status = .copied }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { status = nil }
        }
    }
}
