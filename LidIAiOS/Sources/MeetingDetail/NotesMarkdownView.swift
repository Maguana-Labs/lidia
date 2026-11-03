import LidIAIntelligence
import SwiftUI

/// Renders the meeting notes: topic headings with bullets, decisions marked,
/// Next Steps left to the action items card below.
struct NotesMarkdownView: View {
    let markdown: String
    var hidesNextSteps = true

    var body: some View {
        let sections = NotesMarkdown.sections(in: markdown).filter {
            !(hidesNextSteps && ["next steps", "action items", "próximos pasos"].contains($0.heading.lowercased()))
        }
        VStack(alignment: .leading, spacing: 22) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 10) {
                    Text(section.heading)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(section.bullets.enumerated()), id: \.offset) { _, bullet in
                            BulletLine(bullet: bullet)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

private struct BulletLine: View {
    let bullet: NotesMarkdown.Bullet

    private var decision: String? {
        let plain = NotesMarkdown.stripInlineMarkup(bullet.text)
        for prefix in ["Decided:", "Decision:", "Decidido:"] where plain.hasPrefix(prefix) {
            return plain.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    var body: some View {
        if let decision {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x12B5A6))
                Text(decisionText(decision))
                    .font(.body)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: 0x12B5A6).opacity(0.1), in: .rect(cornerRadius: 12, style: .continuous))
            .padding(.leading, bullet.depth == 1 ? 20 : 0)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(bullet.depth == 0 ? Color.primary.opacity(0.55) : Color.secondary.opacity(0.5))
                    .frame(width: bullet.depth == 0 ? 5 : 4, height: bullet.depth == 0 ? 5 : 4)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                Text(inline(bullet.text))
                    .font(bullet.depth == 0 ? .body : .subheadline)
                    .foregroundStyle(bullet.depth == 0 ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, bullet.depth == 1 ? 20 : 0)
        }
    }

    private func decisionText(_ decision: String) -> AttributedString {
        var label = AttributedString("Decided  ")
        label.font = .subheadline.weight(.semibold)
        label.foregroundColor = Color(hex: 0x12B5A6)
        return label + inline(decision)
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
