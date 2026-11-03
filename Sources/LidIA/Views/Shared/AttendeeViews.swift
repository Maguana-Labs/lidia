import SwiftUI

/// A round initials avatar with a stable, warm, muted colour per person. The user is
/// drawn in the accent colour.
struct AttendeeAvatar: View {
    let attendee: MeetingAttendee
    var size: CGFloat = 20

    private static let palette = Brand.avatarPalette

    static func color(for key: String) -> Color {
        let hash = key.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return palette[hash % palette.count]
    }

    var body: some View {
        let tint = attendee.isCurrentUser ? Color.accentColor : Self.color(for: attendee.id)
        Text(attendee.initials)
            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Overlapping avatars plus a count. Click for everyone, grouped by company.
struct AttendeeStackButton: View {
    let attendees: [MeetingAttendee]
    var maxVisible = 3
    var size: CGFloat = 20

    @State private var showsPopover = false

    var body: some View {
        Button {
            showsPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                AttendeeAvatarStack(attendees: attendees, maxVisible: maxVisible, size: size)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.leading, 3)
            .padding(.trailing, 9)
            .padding(.vertical, 3)
            .contentShape(.capsule)
        }
        .buttonStyle(MeetingChipButtonStyle())
        .help(attendees.map(\.displayName).joined(separator: ", "))
        .accessibilityLabel("\(attendees.count) participant\(attendees.count == 1 ? "" : "s"): \(attendees.map(\.displayName).joined(separator: ", "))")
        .accessibilityHint("Shows everyone with their email")
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            AttendeeListPopover(attendees: attendees)
        }
    }

    /// "Daniel, Felix +3" or "4 people".
    private var summary: String {
        let others = attendees.filter { !$0.isCurrentUser }
        if others.count == 1 { return others[0].name }
        let companies = AttendeeGrouping.externalCompanies(attendees)
        if companies.count == 1 { return "\(companies[0]) · \(attendees.count)" }
        return "\(attendees.count) people"
    }
}

/// Just the overlapping circles, with "+N" when there are more.
struct AttendeeAvatarStack: View {
    let attendees: [MeetingAttendee]
    var maxVisible = 3
    var size: CGFloat = 20

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(attendees.prefix(maxVisible)) { attendee in
                AttendeeAvatar(attendee: attendee, size: size)
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5).padding(-1))
            }
            if attendees.count > maxVisible {
                Text("+\(attendees.count - maxVisible)")
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: size, minHeight: size)
                    .padding(.horizontal, 2)
                    .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Everyone in the meeting, grouped by company, with emails.
struct AttendeeListPopover: View {
    let attendees: [MeetingAttendee]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(attendees.count) Participant\(attendees.count == 1 ? "" : "s")")
                    .font(.headline)
                ForEach(AttendeeGrouping.byCompany(attendees)) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ForEach(group.attendees) { attendee in
                            AttendeeListRow(attendee: attendee)
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 300)
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One person in the popover; Copy Email appears on hover.
private struct AttendeeListRow: View {
    let attendee: MeetingAttendee
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            AttendeeAvatar(attendee: attendee, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(attendee.isCurrentUser ? "\(attendee.name) (You)" : attendee.name)
                    .font(.body)
                if let email = attendee.email {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if let email = attendee.email {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(email, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .help("Copy \(email)")
                .accessibilityLabel("Copy email of \(attendee.name)")
            }
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .contextMenu {
            if let email = attendee.email {
                Button("Copy Email") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(email, forType: .string)
                }
            }
        }
    }
}

/// The small capsule buttons in the meeting header row (view switcher,
/// Transcript, participants). Quiet at rest, tinted when on.
struct MeetingChipButtonStyle: ButtonStyle {
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        MeetingChipBody(configuration: configuration, isOn: isOn)
    }

    private struct MeetingChipBody: View {
        let configuration: ButtonStyleConfiguration
        let isOn: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                .background {
                    Capsule().fill(fill)
                }
                .overlay {
                    Capsule().strokeBorder(isOn ? Color.accentColor.opacity(0.35) : Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                }
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private var fill: Color {
            if isOn { return Color.accentColor.opacity(configuration.isPressed ? 0.22 : 0.14) }
            if configuration.isPressed { return Color.primary.opacity(0.12) }
            return Color.primary.opacity(hovering ? 0.08 : 0.04)
        }
    }
}
