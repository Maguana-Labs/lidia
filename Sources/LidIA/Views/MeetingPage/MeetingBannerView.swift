import SwiftUI

/// Operations on the meeting page that can fail and report back with a banner.
enum MeetingPageOperation: String, CaseIterable, Identifiable, Sendable {
    case generateTitle
    case generateNotes
    case resummarize
    case regenerate
    case notion
    case n8n
    case reminders
    case export

    var id: String { rawValue }

    var failureTitle: String {
        switch self {
        case .generateTitle: "Couldn't generate a title"
        case .generateNotes: "Couldn't generate notes"
        case .resummarize: "Couldn't re-summarise with that template"
        case .regenerate: "Couldn't regenerate the summary"
        case .notion: "Couldn't send to Notion"
        case .n8n: "Couldn't send to n8n"
        case .reminders: "Couldn't add to Reminders"
        case .export: "Couldn't export the meeting"
        }
    }
}

/// A banner currently shown on the meeting page.
struct MeetingPageBanner: Identifiable, Equatable {
    enum Kind: Equatable {
        case error
        case success
        case info
    }

    var operation: MeetingPageOperation
    var kind: Kind
    var title: String
    var message: String?

    var id: MeetingPageOperation { operation }

    static func failure(_ operation: MeetingPageOperation, error: Error) -> MeetingPageBanner {
        MeetingPageBanner(operation: operation, kind: .error, title: operation.failureTitle, message: error.localizedDescription)
    }

    static func failure(_ operation: MeetingPageOperation, message: String) -> MeetingPageBanner {
        MeetingPageBanner(operation: operation, kind: .error, title: operation.failureTitle, message: message)
    }
}

/// Consistent inline banner: icon, title, optional detail, actions, dismiss.
struct MeetingBannerView<Actions: View>: View {
    let kind: MeetingPageBanner.Kind
    let title: String
    var message: String?
    var onDismiss: (() -> Void)?
    @ViewBuilder var actions: () -> Actions

    private var tint: Color {
        switch kind {
        case .error: .orange
        case .success: .green
        case .info: .accentColor
        }
    }

    private var icon: String {
        switch kind {
        case .error: "exclamationmark.triangle.fill"
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.body)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                actions()
            }
            .controlSize(.small)

            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.25)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension MeetingBannerView where Actions == EmptyView {
    init(kind: MeetingPageBanner.Kind, title: String, message: String? = nil, onDismiss: (() -> Void)? = nil) {
        self.kind = kind
        self.title = title
        self.message = message
        self.onDismiss = onDismiss
        self.actions = { EmptyView() }
    }
}
