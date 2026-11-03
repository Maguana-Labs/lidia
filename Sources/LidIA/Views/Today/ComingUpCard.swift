import SwiftUI

/// Days for the Coming up card: today (always) plus every later day with a
/// meeting, each with all of its events.
enum ComingUpModel {
    struct Day: Identifiable, Equatable {
        var date: Date
        var events: [AgendaEvent]
        var isToday: Bool
        var id: Date { date }
    }

    static func days(_ events: [AgendaEvent], now: Date, horizonDays: Int = 7, calendar: Calendar = .current) -> [Day] {
        let today = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: horizonDays, to: today) else { return [] }
        var byDay: [Date: [AgendaEvent]] = [:]
        for event in events where event.end > today && event.start < end {
            // An event already under way (or all-day) counts for today.
            let day = max(calendar.startOfDay(for: event.start), today)
            byDay[day, default: []].append(event)
        }
        var result = [Day(date: today, events: sorted(byDay[today] ?? []), isToday: true)]
        for day in byDay.keys.sorted() where day > today {
            result.append(Day(date: day, events: sorted(byDay[day] ?? []), isToday: false))
        }
        return result
    }

    /// Timed events by start, all-day events last.
    static func sorted(_ events: [AgendaEvent]) -> [AgendaEvent] {
        events.sorted { lhs, rhs in
            if lhs.isAllDay != rhs.isAllDay { return !lhs.isAllDay }
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    /// The first event still ahead (or under way): it keeps its buttons visible.
    static func nextEventID(_ events: [AgendaEvent], now: Date) -> String? {
        events.filter { !$0.isAllDay && $0.end > now }.min { $0.start < $1.start }?.id
    }
}

/// Granola-style "Coming up": one rounded card, a row per day with a big
/// day number (red dot on today), and every meeting of that day with its
/// colour bar, time range and project. Arrows page through the days;
/// Join/Record appear on hover.
struct ComingUpCard: View {
    let agenda: [AgendaEvent]
    let now: Date
    var eventProjects: [String: String] = [:]
    var isRecording: Bool
    var daysPerPage = 3
    var onOpenEvent: (AgendaEvent) -> Void
    var onRecordEvent: (AgendaEvent, _ join: Bool) -> Void

    @State private var page = 0

    private var days: [ComingUpModel.Day] { ComingUpModel.days(agenda, now: now) }

    private var pageCount: Int { max(1, Int((Double(days.count) / Double(daysPerPage)).rounded(.up))) }

    private var visibleDays: ArraySlice<ComingUpModel.Day> {
        let start = min(page, pageCount - 1) * daysPerPage
        return days.dropFirst(start).prefix(daysPerPage)
    }

    var body: some View {
        let nextID = ComingUpModel.nextEventID(agenda, now: now)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Coming up")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if pageCount > 1 {
                    pager
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(visibleDays.enumerated()), id: \.element.id) { index, day in
                    if index > 0 { Divider() }
                    dayRow(day, nextID: nextID)
                }
            }
            .lidiaCard(radius: 14)
        }
        .onChange(of: days.count) { _, _ in page = min(page, pageCount - 1) }
    }

    private var pager: some View {
        HStack(spacing: 2) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { page = max(0, page - 1) }
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 24, height: 22)
                    .contentShape(.rect)
            }
            .disabled(page == 0)
            .help("Earlier days")
            .accessibilityLabel("Earlier days")
            Button {
                withAnimation(.easeOut(duration: 0.15)) { page = min(pageCount - 1, page + 1) }
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 24, height: 22)
                    .contentShape(.rect)
            }
            .disabled(page >= pageCount - 1)
            .help("Later days")
            .accessibilityLabel("Later days")
        }
        .buttonStyle(.borderless)
        .font(.callout.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func dayRow(_ day: ComingUpModel.Day, nextID: String?) -> some View {
        HStack(alignment: .top, spacing: 14) {
            DayBadge(date: day.date, isToday: day.isToday)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                if day.events.isEmpty {
                    Text(day.isToday ? "Nothing else on your calendar today" : "No meetings")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                } else {
                    ForEach(day.events) { event in
                        ComingUpEventRow(
                            event: event,
                            now: now,
                            project: eventProjects[event.id],
                            isNext: event.id == nextID,
                            isRecording: isRecording,
                            onOpen: { onOpenEvent(event) },
                            onRecord: { join in onRecordEvent(event, join) }
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
    }
}

/// "3 Nov / Tue", with a red dot on today.
private struct DayBadge: View {
    let date: Date
    let isToday: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 26, weight: .semibold).monospacedDigit())
                .foregroundStyle(isToday ? Color.primary : .primary.opacity(0.85))
                .frame(minWidth: 32, alignment: .trailing)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(date.formatted(.dateTime.month(.abbreviated)))
                        .font(.caption.weight(.semibold))
                    if isToday {
                        Circle().fill(Brand.red).frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                }
                Text(date.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.caption)
                    .foregroundStyle(isToday ? Brand.red : .secondary)
            }
        }
        .frame(width: 76, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// One meeting in the Coming up card.
private struct ComingUpEventRow: View {
    let event: AgendaEvent
    let now: Date
    var project: String?
    var isNext: Bool
    var isRecording: Bool
    var onOpen: () -> Void
    var onRecord: (_ join: Bool) -> Void

    @State private var hovering = false

    private var isPast: Bool { !event.isAllDay && event.end <= now }
    private var isNow: Bool { event.isHappening(at: now) && !event.isAllDay }
    private var showsActions: Bool { !isRecording && !isPast && !event.isAllDay && (hovering || isNext) }

    private var barColor: Color {
        Color.fromHex(event.colorHex) ?? project.map(ProjectPalette.color(for:)) ?? .accentColor
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(barColor)
                .frame(width: 3, height: 30)
                .accessibilityHidden(true)
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(timeText)
                            .monospacedDigit()
                        if isNow {
                            Text("Now")
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(event.title), \(timeText)\(isNow ? ", happening now" : "")")
            .accessibilityHint("Opens the event")

            if let project {
                ProjectLabel(name: project)
                    .frame(maxWidth: 140, alignment: .trailing)
            }

            HStack(spacing: 6) {
                if event.meetingLink != nil {
                    Button { onRecord(true) } label: {
                        Label("Join", systemImage: "video.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .help("Open the call and start recording")
                    .accessibilityLabel("Join and record \(event.title)")
                }
                Button { onRecord(false) } label: {
                    Label("Record", systemImage: "record.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.glass)
                .help("Record this meeting")
                .accessibilityLabel("Record \(event.title)")
            }
            .controlSize(.small)
            .opacity(showsActions ? 1 : 0)
            .allowsHitTesting(showsActions)
            .accessibilityHidden(!showsActions)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(isPast ? 0.5 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var timeText: String {
        if event.isAllDay { return "All day" }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }
}
