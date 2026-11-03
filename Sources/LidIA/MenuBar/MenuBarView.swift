import Combine
import SwiftUI
import SwiftData

/// The menu bar panel. One job per state:
/// - idle: start recording, see what's next, ask your meetings;
/// - recording: see that it's working (time, level, the last line said) and pause,
///   stop or open the notes, laid out like a Live Activity's expanded view.
/// Sized to its content like a system menu bar extra; Settings, updates and
/// Quit live in the footer and in the status item's right-click menu.
struct MenuBarView: View {
    let feed: RecordingActivityFeed
    let close: () -> Void

    @Environment(RecordingSession.self) private var session
    @Environment(EventKitManager.self) private var eventKitManager
    @Environment(GoogleCalendarMonitor.self) private var googleCalendarMonitor
    @Environment(MeetingDetector.self) private var meetingDetector
    @Environment(AppSettings.self) private var settings
    @Environment(ModelManager.self) private var modelManager
    @Environment(UpdateController.self) private var updateController
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meeting.date, order: .reverse) private var allMeetings: [Meeting]

    private var agenda: [AgendaEvent] {
        AgendaSource.events(eventKitManager: eventKitManager, googleCalendarMonitor: googleCalendarMonitor)
    }

    private var calendarConnected: Bool {
        settings.calendarEnabled || (googleCalendarMonitor.isSignedIn && settings.googleCalendarEnabled)
    }

    private var attentionCount: Int {
        MeetingListModel.attentionItems(allMeetings).count
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                if session.isRecording {
                    RecordingSection(feed: feed, close: close)
                } else {
                    idleContent(now: context.date)
                }
                MenuDivider()
                footer
            }
            .padding(.vertical, 6)
            .frame(width: 320)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
    }

    // MARK: - Idle

    @ViewBuilder
    private func idleContent(now: Date) -> some View {
        let lead = UnifiedCalendar.nowCandidate(agenda, now: now)
        let later = UnifiedCalendar.remainingToday(agenda, now: now)
            .filter { $0.id != lead?.id && !$0.isAllDay }
            .prefix(3)

        StartRecordingCard(subtitle: captureSubtitle) {
            startAdHoc()
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 8)

        if let lead {
            MenuDivider()
            MenuSectionHeader(
                lead.isHappening(at: now) ? "Now" : "Up Next",
                trailing: Self.relative(lead, now: now)
            )
            LeadEventRow(event: lead) { join in
                record(lead, join: join)
            }
        }

        if !later.isEmpty {
            MenuDivider()
            MenuSectionHeader("Later Today")
            ForEach(Array(later)) { event in
                LaterEventRow(event: event) {
                    record(event, join: event.meetingLink != nil)
                }
            }
        }

        if !calendarConnected {
            MenuDivider()
            MenuRow(title: "Connect a Calendar…", systemImage: "calendar.badge.plus", tint: .secondary) {
                close()
                MenuBarActions.openSettings(.calendars)
            }
        }

        if attentionCount > 0 {
            MenuDivider()
            MenuRow(
                title: attentionCount == 1 ? "1 meeting needs attention" : "\(attentionCount) meetings need attention",
                systemImage: "exclamationmark.circle.fill",
                tint: .orange
            ) {
                close()
                MenuBarActions.openMainWindow(post: .lidiaOpenHomeWorkspace)
            }
        }
    }

    private var captureSubtitle: String { "Microphone and system audio" }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            MenuRow(title: "Ask LidIA…", systemImage: "sparkles", shortcut: "⌘K") {
                close()
                MenuBarActions.openMainWindow(post: .lidiaOpenAsk)
            }
            MenuRow(title: "New Note", systemImage: "square.and.pencil", shortcut: "⇧⌘N") {
                close()
                MenuBarActions.openMainWindow(post: .lidiaCreateNote)
            }
            MenuRow(title: "Open LidIA", systemImage: "macwindow") {
                close()
                MenuBarActions.openMainWindow(post: .lidiaOpenHomeWorkspace)
            }
            MenuDivider()
            HStack(spacing: 2) {
                FooterIconButton(systemImage: "gearshape", help: "Settings…") {
                    close()
                    MenuBarActions.openSettings()
                }
                Spacer()
                Menu {
                    Button("Check for Updates…") { updateController.checkForUpdates() }
                        .disabled(!updateController.canCheckForUpdates)
                    Divider()
                    Button("Quit LidIA") { NSApplication.shared.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("More")
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)
        }
    }

    // MARK: - Actions

    private func startAdHoc() {
        guard !session.isRecording else { return }
        _ = session.startRecording(
            modelContext: modelContext,
            settings: settings,
            modelManager: modelManager,
            meetingDetector: meetingDetector,
            eventKitManager: eventKitManager,
            googleCalendarMonitor: googleCalendarMonitor
        )
    }

    private func record(_ event: AgendaEvent, join: Bool) {
        guard !session.isRecording else { return }
        session.startRecording(
            from: event,
            join: join,
            modelContext: modelContext,
            settings: settings,
            modelManager: modelManager,
            meetingDetector: meetingDetector
        )
    }

    /// "in 3 h 28 min", "in 5 min", "ends in 20 min".
    static func relative(_ event: AgendaEvent, now: Date) -> String {
        if event.isHappening(at: now) {
            let left = max(1, Int(event.end.timeIntervalSince(now) / 60))
            return "ends in \(Self.duration(minutes: left))"
        }
        let minutes = max(1, Int((event.start.timeIntervalSince(now) / 60).rounded(.up)))
        return "in \(Self.duration(minutes: minutes))"
    }

    static func duration(minutes: Int) -> String {
        minutes >= 60
            ? (minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min")
            : "\(minutes) min"
    }
}

// MARK: - Recording

/// The recording, laid out like a Live Activity's expanded view, from the menu bar's
/// `RecordingActivityFeed` (the same state the status item's timer reads).
private struct RecordingSection: View {
    let feed: RecordingActivityFeed
    let close: () -> Void

    @Environment(RecordingSession.self) private var session
    @Environment(EventKitManager.self) private var eventKitManager
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        if let state = feed.state {
            RecordingActivityExpandedView(
                state: state,
                level: { session.currentRMS },
                actions: actions
            )
        } else {
            // The first tick hasn't run yet.
            Color.clear
                .frame(height: 1)
                .onAppear { feed.refresh(from: session) }
        }
    }

    private var actions: RecordingActivityActions {
        RecordingActivityActions(
            togglePause: {
                session.isPaused ? session.resumeRecording() : session.pauseRecording()
                feed.refresh(from: session)
            },
            stop: {
                session.stopRecording(modelContext: modelContext, settings: settings, eventKitManager: eventKitManager)
            },
            openNotes: session.currentMeeting.map { meeting in
                {
                    close()
                    MenuBarActions.openMainWindow()
                    NotificationCenter.default.post(
                        name: .lidiaOpenMeeting,
                        object: nil,
                        userInfo: [NotificationDispatcher.eventIDUserInfoKey: meeting.id.uuidString]
                    )
                }
            }
        )
    }
}

// MARK: - Building blocks

private struct StartRecordingCard: View {
    let subtitle: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Brand.red)
                    Circle().fill(.white).frame(width: 10, height: 10)
                }
                .frame(width: 30, height: 30)
                .shadow(color: Brand.red.opacity(0.35), radius: hovering ? 6 : 3, y: 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Start Recording")
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.09 : 0.05))
            )
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Record a meeting that isn't on your calendar")
    }
}

private struct LeadEventRow: View {
    let event: AgendaEvent
    let onRecord: (_ join: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.fromHex(event.colorHex) ?? .accentColor)
                    .frame(width: 3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title.isEmpty ? "Untitled Event" : event.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if event.meetingLink != nil {
                    Button { onRecord(true) } label: {
                        Label("Join & Record", systemImage: "video.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .help("Open the call and start recording")
                }
                Button { onRecord(false) } label: {
                    Label("Record", systemImage: "record.circle")
                        .frame(maxWidth: event.meetingLink == nil ? .infinity : nil)
                }
                .buttonStyle(.glass)
                .help("Start recording this meeting")
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var detail: String {
        let time = "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))"
        let people = event.attendees.count
        return people > 1 ? "\(time) · \(people) people" : time
    }
}

private struct LaterEventRow: View {
    let event: AgendaEvent
    let onRecord: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(event.start.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(event.title.isEmpty ? "Untitled Event" : event.title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 4)
            if hovering {
                Button(action: onRecord) {
                    Image(systemName: event.meetingLink != nil ? "video.circle" : "record.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(event.meetingLink != nil ? "Join & Record" : "Record")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0))
        )
        .padding(.horizontal, 6)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }
}

private struct MenuSectionHeader: View {
    let title: String
    var trailing: String?

    init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

/// A full-width row with the system menu's hover highlight.
private struct MenuRow: View {
    let title: String
    let systemImage: String
    var shortcut: String?
    var tint: Color = .primary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(tint == .primary ? Color.secondary : tint)
                Text(title)
                    .foregroundStyle(tint == .orange ? tint : .primary)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0))
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
    }
}

private struct FooterIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0))
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct MenuDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
    }
}
