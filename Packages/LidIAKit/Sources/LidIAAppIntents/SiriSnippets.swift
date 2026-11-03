import Foundation
import LidIAKit
import SwiftUI

/// The brand in Siri's cards: her red for the mark and accents, ink and ivory
/// for text, system materials for the card (Siri draws the background).
public enum SiriBrand {
    static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static func red(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? LidIABrand.Hex.redDark : LidIABrand.Hex.red) }
    static let crimson = color(LidIABrand.Hex.crimson)
    static let coral = color(LidIABrand.Hex.coral)
    static let ivory = color(LidIABrand.Hex.ivory)
    static let ink = color(LidIABrand.Hex.ink)
}

/// "LidIA" with her red mark, at the top of every card.
struct SiriCardHeader: View {
    var title: String
    var symbol: String = "waveform"
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(LinearGradient(colors: [SiriBrand.red(scheme), SiriBrand.coral], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SiriBrand.ivory)
            }
            .frame(width: 22, height: 22)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

/// Meetings Siri found.
public struct MeetingListSnippet: View {
    let meetings: [MeetingEntity]
    let heading: String

    public init(meetings: [MeetingEntity], heading: String) {
        self.meetings = meetings
        self.heading = heading
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SiriCardHeader(title: heading)
            ForEach(meetings.prefix(5), id: \.id) { meeting in
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title).font(.body.weight(.semibold)).lineLimit(1)
                    Text(MeetingEntity.subtitle(date: meeting.date, attendees: meeting.attendees))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if meetings.count > 5 {
                Text("and \(meetings.count - 5) more").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }
}

/// A meeting's summary and decisions, or why they aren't shown.
public struct MeetingSummarySnippet: View {
    let meeting: MeetingEntity
    let points: [String]
    let decisions: [String]
    let blockedMessage: String?
    @Environment(\.colorScheme) private var scheme

    public init(meeting: MeetingEntity, points: [String], decisions: [String], blockedMessage: String?) {
        self.meeting = meeting
        self.points = points
        self.decisions = decisions
        self.blockedMessage = blockedMessage
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SiriCardHeader(title: "Meeting notes", symbol: "text.alignleft")
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).font(.headline).lineLimit(2)
                Text(MeetingEntity.subtitle(date: meeting.date, attendees: meeting.attendees))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let blockedMessage {
                Label(blockedMessage, systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(points.prefix(6).enumerated()), id: \.offset) { _, point in
                    bullet(point, color: .secondary)
                }
                if !decisions.isEmpty {
                    Text("Decisions").font(.caption.weight(.semibold)).foregroundStyle(SiriBrand.red(scheme)).padding(.top, 2)
                    ForEach(Array(decisions.prefix(4).enumerated()), id: \.offset) { _, decision in
                        bullet(decision, color: SiriBrand.red(scheme))
                    }
                }
            }
        }
        .padding(14)
    }

    private func bullet(_ text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Action items, with owner, due date and status.
public struct ActionItemListSnippet: View {
    let items: [ActionItemEntity]
    let heading: String
    @Environment(\.colorScheme) private var scheme

    public init(items: [ActionItemEntity], heading: String) {
        self.items = items
        self.heading = heading
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SiriCardHeader(title: heading, symbol: "checklist")
            ForEach(items.prefix(6), id: \.id) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: item.status == .done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.status == .done ? SiriBrand.red(scheme) : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.callout.weight(.medium)).lineLimit(2)
                        Text(detail(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            if items.count > 6 {
                Text("and \(items.count - 6) more").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    private func detail(_ item: ActionItemEntity) -> String {
        var parts: [String] = []
        if let owner = item.owner, !owner.isEmpty { parts.append(owner) }
        if let due = item.dueDate { parts.append("due " + due.formatted(date: .abbreviated, time: .omitted)) }
        if let meeting = item.meetingTitle, !meeting.isEmpty { parts.append(meeting) }
        return parts.joined(separator: " · ")
    }
}

/// A one-line confirmation ("Recording", "Added to your action items").
public struct SiriConfirmationSnippet: View {
    let symbol: String
    let title: String
    let detail: String?
    @Environment(\.colorScheme) private var scheme

    public init(symbol: String, title: String, detail: String? = nil) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(SiriBrand.red(scheme))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}
