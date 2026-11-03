import SwiftUI

/// How dense a chat surface is: the Chats workspace reads like a document,
/// the ⌘K palette and the meeting inspector are tighter.
enum ChatDensity: Sendable {
    case regular
    case compact

    var bodySize: CGFloat { self == .regular ? 14 : 13 }
    var lineSpacing: CGFloat { self == .regular ? 4.5 : 3 }
    var blockSpacing: CGFloat { self == .regular ? 12 : 8 }
    var messageSpacing: CGFloat { self == .regular ? 30 : 20 }
    var smallSize: CGFloat { self == .regular ? 12 : 11 }
}

/// Opens a meeting from a citation or source card, at a transcript time when known.
struct ChatOpenMeetingAction: Sendable {
    var handler: (@MainActor @Sendable (UUID, TimeInterval?) -> Void)?

    @MainActor
    func callAsFunction(_ id: UUID, at time: TimeInterval? = nil) { handler?(id, time) }
}

extension EnvironmentValues {
    @Entry var chatDensity: ChatDensity = .regular
    @Entry var chatOpenMeeting = ChatOpenMeetingAction()
}

/// Shared colors and shapes for chat pieces.
enum ChatStyle {
    static let column: CGFloat = 720
    static let cardRadius: CGFloat = 12

    /// A quiet card surface that works in light and dark.
    static var cardFill: Color { Color.primary.opacity(0.035) }
    static var cardStroke: Color { Color.primary.opacity(0.08) }
    static var hoverFill: Color { Color.primary.opacity(0.06) }
}

extension View {
    /// The standard chat card: soft fill, hairline border, continuous corners.
    func chatCard(radius: CGFloat = ChatStyle.cardRadius, padding: CGFloat = 0) -> some View {
        self
            .padding(padding)
            .background(ChatStyle.cardFill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(ChatStyle.cardStroke, lineWidth: 0.5))
    }
}

/// A small icon-only button used in answer toolbars.
struct ChatIconButton: View {
    var systemImage: String
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .foregroundStyle(hovering ? .primary : .secondary)
                .background(hovering ? AnyShapeStyle(ChatStyle.hoverFill) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
