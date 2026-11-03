import LidIAKit
import SwiftUI

/// A proactive suggestion. Every one says why, and can be dismissed.
struct Suggestion: Identifiable, Hashable {
    enum Kind { case prep, followUp, stale, review }
    enum Target: Hashable {
        case meeting(UUID)
        case actionItem(UUID)
    }

    let id: String
    let kind: Kind
    let title: String
    let reason: String
    let target: Target

    var symbol: String {
        switch kind {
        case .prep: "list.bullet.clipboard"
        case .followUp: "arrowshape.turn.up.right"
        case .stale: "hourglass"
        case .review: "exclamationmark.triangle"
        }
    }

    var eyebrow: String {
        switch kind {
        case .prep: "Prep"
        case .followUp: "Follow up"
        case .stale: "Still open"
        case .review: "Needs you"
        }
    }

    var tint: Color {
        switch kind {
        case .prep: Brand.red
        case .followUp: Brand.ember
        case .stale: Brand.amber
        case .review: Color(uiColor: .systemRed) // an error: system red, with the triangle and "Needs you"
        }
    }
}

/// Builds suggestions from the library and the calendar.
enum SuggestionEngine {
    static func suggestions(meetings: [Meeting], openItems: [ActionItem], next: UpcomingEvent?, dismissed: Set<String>) -> [Suggestion] {
        var result: [Suggestion] = []
        let finished = meetings.filter { $0.status == .complete }

        // Prep: the next event continues a series we've recorded before.
        if let next {
            let key = Meeting.seriesKey(for: next.title)
            if let last = finished.first(where: { $0.seriesKey == key && $0.date < next.start }) {
                let open = last.openItems.count
                result.append(Suggestion(
                    id: "prep-\(next.id)",
                    kind: .prep,
                    title: "Prep for \(next.title)",
                    reason: open > 0 ? "Last time you left \(open) item\(open == 1 ? "" : "s") open" : "Recap of \(Format.day(last.date))’s meeting",
                    target: .meeting(last.id)
                ))
            }
        }

        // Needs attention: notes that failed.
        for meeting in meetings where meeting.status == .failed {
            result.append(Suggestion(
                id: "review-\(meeting.id)",
                kind: .review,
                title: "Notes for \(meeting.displayTitle) didn’t finish",
                reason: "Tap to try again",
                target: .meeting(meeting.id)
            ))
        }

        // Follow up: recent meetings with commitments still open.
        let threeDaysAgo = Date.now.addingTimeInterval(-3 * 86_400)
        for meeting in finished where meeting.date > threeDaysAgo && !meeting.openItems.isEmpty {
            let count = meeting.openItems.count
            result.append(Suggestion(
                id: "follow-\(meeting.id)",
                kind: .followUp,
                title: "Follow up on \(meeting.displayTitle)",
                reason: "\(count) commitment\(count == 1 ? "" : "s") from \(Format.dayInSentence(meeting.date))",
                target: .meeting(meeting.id)
            ))
        }

        // Stale: items open for a week or more.
        for item in openItems.sorted(by: { $0.ageInDays > $1.ageInDays }) where item.ageInDays >= 7 {
            result.append(Suggestion(
                id: "stale-\(item.id)",
                kind: .stale,
                title: item.title,
                reason: "Open for \(item.ageInDays) days" + (item.meeting.map { " · \($0.displayTitle)" } ?? ""),
                target: .actionItem(item.id)
            ))
        }

        return Array(result.filter { !dismissed.contains($0.id) }.prefix(6))
    }
}

struct ForYouSection: View {
    let meetings: [Meeting]
    let openItems: [ActionItem]

    @Environment(AppRouter.self) private var router
    @Environment(AppSettings.self) private var settings
    @Environment(CalendarService.self) private var calendar

    var body: some View {
        let suggestions = SuggestionEngine.suggestions(
            meetings: meetings,
            openItems: openItems,
            next: calendar.next,
            dismissed: settings.dismissedSuggestions
        )
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "For you")
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(suggestions) { suggestion in
                            SuggestionCard(suggestion: suggestion) {
                                open(suggestion)
                            } onDismiss: {
                                withAnimation(.snappy) { _ = settings.dismissedSuggestions.insert(suggestion.id) }
                                Haptics.tap()
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
    }

    private func open(_ suggestion: Suggestion) {
        Haptics.tap()
        switch suggestion.target {
        case .meeting(let id): router.open(id)
        case .actionItem(let id): router.actionItemDetail = .init(id: id)
        }
    }
}

private struct SuggestionCard: View {
    let suggestion: Suggestion
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    illustration
                    HStack {
                        Spacer()
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .background(.thinMaterial, in: .circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss suggestion")
                    }
                    .padding(10)
                }
                .frame(height: 84)

                VStack(alignment: .leading, spacing: 4) {
                    Text(suggestion.eyebrow.uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(0.5)
                        .foregroundStyle(suggestion.tint)
                    Text(suggestion.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Text(suggestion.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(14)
            }
            .frame(width: 176, height: 212, alignment: .topLeading)
            .background(Surface.card, in: .rect(cornerRadius: Metrics.tileRadius, style: .continuous))
            .contentShape(.rect(cornerRadius: Metrics.tileRadius))
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            Button("Open", systemImage: "arrow.up.forward", action: onOpen)
            Button("Not now", systemImage: "xmark", action: onDismiss)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Dismiss", onDismiss)
    }

    private var illustration: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: Metrics.tileRadius, topTrailingRadius: Metrics.tileRadius, style: .continuous)
        return ZStack(alignment: .bottomLeading) {
            shape.fill(LinearGradient(colors: [suggestion.tint.opacity(0.22), suggestion.tint.opacity(0.07)], startPoint: .topTrailing, endPoint: .bottomLeading))
            WaveMark(amplitude: 0.32)
                .stroke(suggestion.tint.opacity(0.35), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 150, height: 50)
                .offset(x: 40, y: -22)
            Image(systemName: suggestion.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(suggestion.tint)
                .frame(width: 44, height: 44)
                .background(Surface.card, in: .rect(cornerRadius: 13, style: .continuous))
                .shadow(color: suggestion.tint.opacity(0.15), radius: 6, y: 2)
                .padding(14)
        }
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}
