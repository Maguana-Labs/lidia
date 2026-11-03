import SwiftUI

struct PersonRow: View {
    let profile: RelationshipStore.PersonProfile
    let isFavorite: Bool
    let onToggleFavorite: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: profile.name, size: 32)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(health.color)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                        .help(health.text)
                        .accessibilityHidden(true)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if !profile.openActionItems.isEmpty {
                Text("\(profile.openActionItems.count) open")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Color.orange.opacity(0.14), in: Capsule())
                    .help("Open action items with \(profile.name)")
            }
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.fill" : "star", action: onToggleFavorite)
                .foregroundStyle(isFavorite ? .yellow : .secondary)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .opacity(isFavorite || hovering ? 1 : 0)
                .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.name), \(subtitle), \(health.text)")
    }

    private var subtitle: String {
        var parts: [String] = []
        if let email = profile.email { parts.append(email) }
        parts.append("\(profile.meetingCount) meeting\(profile.meetingCount == 1 ? "" : "s")")
        parts.append("last met \(MeetingRowFormat.relativeDay(profile.lastMet, timeForToday: false))")
        return parts.joined(separator: " · ")
    }

    private var health: (color: Color, text: String) {
        let days = Calendar.current.dateComponents([.day], from: profile.lastMet, to: .now).day ?? 0
        let hasOverdue = profile.openActionItems.contains { item in
            guard !item.isDeleted, let meeting = item.meeting else { return false }
            return (Calendar.current.dateComponents([.day], from: meeting.date, to: .now).day ?? 0) > 14
        }
        if hasOverdue { return (.red, "Has action items open for over two weeks") }
        if days <= 7 { return (.green, "Met in the last week") }
        if days <= 21 { return (.yellow, "Met in the last three weeks") }
        return (Color(nsColor: .tertiaryLabelColor), "Not met in three weeks")
    }
}
