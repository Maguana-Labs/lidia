import SwiftUI

// MARK: - Now row

/// Pinned at the top of the sidebar: the live recording, or the next meeting
/// with its Record action, or a plain Record button.
struct NowRow: View {
    @Environment(RecordingSession.self) private var session

    let agenda: [AgendaEvent]
    var onOpenRecording: () -> Void
    var onOpenEvent: (AgendaEvent) -> Void
    var onRecordEvent: (AgendaEvent, _ join: Bool) -> Void
    var onRecordNow: () -> Void
    var onStop: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: session.isRecording ? 1 : 30)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if session.isRecording {
            HStack(spacing: 8) {
                Circle()
                    .fill(Brand.red)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Button(action: onOpenRecording) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.currentMeeting.map { $0.title.isEmpty ? "Recording" : $0.title } ?? "Recording")
                            .font(.headline)
                            .lineLimit(1)
                        Text(session.isPaused ? "Paused · \(ElapsedFormat.string(session.elapsedTime))"
                                              : "Recording · \(ElapsedFormat.string(session.elapsedTime))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Brand.red)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the live meeting")

                Button(action: onStop) {
                    Label("Stop Recording", systemImage: "stop.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Brand.red)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Stop recording")
                .accessibilityLabel("Stop recording")
            }
            .padding(.vertical, 4)
        } else if let event = UnifiedCalendar.nowCandidate(agenda, now: now) {
            let later = UnifiedCalendar.remainingToday(agenda, now: now)
                .filter { $0.id != event.id && !$0.isAllDay && $0.start > event.start }
            VStack(alignment: .leading, spacing: 4) {
                Text(event.isHappening(at: now) ? "NOW" : "UP NEXT · \(relative(event.start, now: now))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                AgendaEventRow(
                    event: event,
                    compact: true,
                    onOpen: { onOpenEvent(event) },
                    onRecord: { join in onRecordEvent(event, join) }
                )
                if !later.isEmpty {
                    ForEach(later.prefix(3)) { next in
                        Button { onOpenEvent(next) } label: {
                            HStack(spacing: 8) {
                                Text(next.start.formatted(date: .omitted, time: .shortened))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 40, alignment: .leading)
                                Text(next.title)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(next.title), \(next.start.formatted(date: .omitted, time: .shortened))")
                    }
                    if later.count > 3 {
                        Text("+\(later.count - 3) more today")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 2)
        } else {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nothing scheduled")
                        .font(.callout)
                        .lineLimit(1)
                    Text("Record any time with ⌘R")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                Button(action: onRecordNow) {
                    Label("Record", systemImage: "record.circle")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Brand.red)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Start recording now (⌘R)")
                .accessibilityLabel("Start recording")
            }
            .padding(.vertical, 2)
        }
    }

    private func relative(_ date: Date, now: Date) -> String {
        let minutes = Int(date.timeIntervalSince(now) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}
