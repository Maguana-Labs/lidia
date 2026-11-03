import SwiftUI
import UIKit

/// Confirmation toasts ("Summary copied", "Marked done · Undo").
///
/// Shown in their own window above every sheet, so a toast raised from a sheet
/// and one raised from the root look the same and never appear twice.
@MainActor
@Observable
final class ToastCenter {
    struct Toast: Identifiable, Equatable {
        enum Style { case success, info, warning }
        let id = UUID()
        var message: String
        var symbol: String
        var style: Style
        var actionTitle: String?
        var action: (() -> Void)?

        static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
    }

    private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?
    private var window: ToastWindow?

    func show(
        _ message: String,
        symbol: String = "checkmark.circle.fill",
        style: Toast.Style = .success,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        installWindowIfNeeded()
        let toast = Toast(message: message, symbol: symbol, style: style, actionTitle: actionTitle, action: action)
        withAnimation(.spring(duration: 0.4, bounce: 0.25)) { current = toast }
        window?.isHidden = false
        AccessibilityNotification.Announcement(message).post()
        switch style {
        case .success: Haptics.success()
        case .warning: Haptics.warning()
        case .info: Haptics.tap()
        }
        dismissTask?.cancel()
        let seconds: Double = actionTitle == nil ? 2.4 : 4
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        withAnimation(.smooth(duration: 0.3)) { current = nil }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            if self?.current == nil { self?.window?.isHidden = true }
        }
    }

    func runAction() {
        current?.action?()
        dismiss()
    }

    private func installWindowIfNeeded() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) ??
                UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        let window = ToastWindow(windowScene: scene)
        let host = UIHostingController(rootView: ToastHost(center: self))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.isHidden = true
        self.window = window
    }
}

/// A window that only takes touches on the toast itself.
private final class ToastWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        // Only the top band where the toast sits is interactive.
        let band = safeAreaInsets.top + 84
        return point.y <= band ? hit : nil
    }
}

private struct ToastHost: View {
    let center: ToastCenter

    var body: some View {
        VStack {
            if let toast = center.current {
                ToastView(toast: toast, onAction: { center.runAction() })
                    .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96)))
                    .gesture(
                        DragGesture(minimumDistance: 8).onEnded { value in
                            if value.translation.height < -10 { center.dismiss() }
                        }
                    )
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.top, 6)
            }
            Spacer()
        }
        .animation(.spring(duration: 0.4, bounce: 0.25), value: center.current)
    }
}

private struct ToastView: View {
    let toast: ToastCenter.Toast
    let onAction: () -> Void

    private var fill: Color {
        switch toast.style {
        case .success: Color(hex: 0x1F9D55)
        case .info: Color(hex: 0x2A2F45)
        case .warning: Color(hex: 0xD9480F)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.symbol)
                .font(.system(size: 18, weight: .semibold))
            Text(toast.message)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle = toast.actionTitle {
                Button(actionTitle, action: onAction)
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.2), in: .capsule)
                    .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(fill.gradient, in: .rect(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}
