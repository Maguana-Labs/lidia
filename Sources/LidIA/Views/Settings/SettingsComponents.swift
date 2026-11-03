import SwiftUI

// MARK: - Icon tile

/// A System Settings-style rounded square with a white SF Symbol.
struct SettingsIconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22
    /// Spoken by VoiceOver. Empty hides the tile from VoiceOver (when the
    /// row's own text already says what it is).
    var accessibilityName: String = ""

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.monochrome)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
            .accessibilityElement()
            .accessibilityLabel(accessibilityName)
            .accessibilityHidden(accessibilityName.isEmpty)
    }
}

// MARK: - Page scaffold

/// Content column width for every page.
enum SettingsLayout {
    static let contentWidth: CGFloat = 640
    static let sidebarWidth: CGFloat = 220
}

/// A Settings page: large title, a grouped Form centered at a readable width,
/// and scrolling to the row search picked.
struct SettingsPage<Content: View>: View {
    let pane: SettingsPane
    var subpage: SettingsSubpage?
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: Content

    private var router: SettingsRouter { .shared }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                Form {
                    // The title lives in an empty section's footer: a header
                    // here would restyle the next section's header.
                    Section {
                    } footer: {
                        header
                    }
                    content
                }
                .formStyle(.grouped)
                .contentMargins(.horizontal, sideMargin(for: geometry.size.width), for: .scrollContent)
                .onAppear { scrollIfNeeded(proxy) }
                .onChange(of: router.pendingTarget) { _, _ in scrollIfNeeded(proxy) }
            }
        }
        .navigationTitle(title ?? subpage?.title ?? pane.title)
        .navigationBarBackButtonHidden(true)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if subpage != nil {
                Button {
                    if !router.path.isEmpty { router.path.removeLast() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.callout.weight(.semibold))
                        Text(pane.title)
                    }
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: .command)
                .accessibilityLabel("Back to \(pane.title)")
                .padding(.bottom, 4)
            }
            Text(title ?? subpage?.title ?? pane.title)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            if let text = subtitle ?? (subpage == nil ? pane.subtitle : nil) {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private func sideMargin(for width: CGFloat) -> CGFloat {
        max(4, (width - SettingsLayout.contentWidth - 40) / 2)
    }

    private func scrollIfNeeded(_ proxy: ScrollViewProxy) {
        guard let target = router.pendingTarget,
              target.pane == pane, target.subpage == subpage else { return }
        Task { @MainActor in
            // Let the page lay out (and Advanced expand) before scrolling,
            // then scroll again in case rows below were still being built.
            try? await Task.sleep(for: .milliseconds(150))
            proxy.scrollTo(target.anchor, anchor: .center)
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(target.anchor, anchor: .center)
            }
            router.didScroll(to: target)
        }
    }
}

// MARK: - Anchors and highlight

private struct SettingsAnchorModifier: ViewModifier {
    let anchor: SettingsAnchor

    func body(content: Content) -> some View {
        let isHighlighted = SettingsRouter.shared.highlighted == anchor
        content
            .id(anchor)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(isHighlighted ? 0.16 : 0))
                    .padding(.horizontal, -8)
                    .padding(.vertical, -5)
                    .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.45), value: isHighlighted)
    }
}

extension View {
    /// Marks a row search can scroll to and flash.
    func settingsAnchor(_ anchor: SettingsAnchor) -> some View {
        modifier(SettingsAnchorModifier(anchor: anchor))
    }
}

// MARK: - Advanced

/// The collapsed "Advanced" section at the bottom of a pane.
struct SettingsAdvancedSection<Content: View>: View {
    let pane: SettingsPane
    var footer: String?
    @ViewBuilder var content: Content

    private var router: SettingsRouter { .shared }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { router.expandedAdvanced.contains(pane) },
            set: { open in
                if open { router.expandedAdvanced.insert(pane) } else { router.expandedAdvanced.remove(pane) }
            }
        )
    }

    var body: some View {
        Section {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack {
                    Text("Advanced")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Advanced")
            .accessibilityValue(isExpanded.wrappedValue ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows settings most people never need.")

            if isExpanded.wrappedValue {
                content
            }
        } footer: {
            if isExpanded.wrappedValue, let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Row helpers

/// "On", "Off" or "Needs setup" next to a chevron.
struct StatusText: View {
    enum Status {
        case on, off, needsSetup, paused

        var label: String {
            switch self {
            case .on: "On"
            case .off: "Off"
            case .needsSetup: "Needs setup"
            case .paused: "Paused"
            }
        }
    }

    let status: Status

    var body: some View {
        HStack(spacing: 5) {
            if status == .on {
                Circle().fill(.green).frame(width: 7, height: 7)
            }
            Text(status.label)
                .foregroundStyle(status == .needsSetup ? Color.orange : Color.secondary)
        }
        .font(.callout)
    }
}

/// A small inline message: warning, error or success.
struct InlineNote: View {
    enum Kind { case info, warning, error, success }

    let text: String
    var kind: Kind = .info

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
        .font(.callout)
        .foregroundStyle(kind == .info ? Color.secondary : Color.primary)
    }

    private var symbol: String {
        switch kind {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        case .success: .green
        }
    }
}

/// A sub-page link row with an icon tile, title, description and status.
struct SettingsLinkRow: View {
    let symbol: String
    let tint: Color
    let title: String
    var detail: String?
    var status: StatusText.Status?
    var trailingText: String?

    var body: some View {
        HStack(spacing: 12) {
            SettingsIconTile(symbol: symbol, tint: tint, size: 28, accessibilityName: "\(title) icon")
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let status {
                StatusText(status: status)
            } else if let trailingText {
                Text(trailingText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
