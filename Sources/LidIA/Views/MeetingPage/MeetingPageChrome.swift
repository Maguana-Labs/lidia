import SwiftUI

// MARK: - Ask dock

/// The persistent "Ask anything" field docked at the bottom of the meeting
/// page, with recipes one click away.
struct MeetingAskDock: View {
    @Binding var text: String
    var isRecipeRunning: Bool
    var onSubmit: (String) -> Void
    var onRecipe: (Recipe) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            TextField("Ask anything", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(submit)
                .accessibilityLabel("Ask about this meeting")
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                recipesMenu
            } else {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Ask (Return)")
                .accessibilityLabel("Send question")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 40)
        .glassEffect(.regular, in: .capsule)
        .overlay(Capsule().strokeBorder(focused ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1))
        .frame(maxWidth: 560)
    }

    private var recipesMenu: some View {
        Menu {
            ForEach(Recipe.Category.allCases, id: \.self) { category in
                Section(category.rawValue) {
                    ForEach(Recipe.builtIn.filter { $0.category == category }) { recipe in
                        Button("\(recipe.emoji) \(recipe.name)") { onRecipe(recipe) }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if isRecipeRunning {
                    ProgressView().controlSize(.mini)
                }
                Text(isRecipeRunning ? "Running…" : "Recipes")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isRecipeRunning)
        .help("Run a recipe on this meeting: follow-up email, decisions, risks…")
    }

    private func submit() {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        onSubmit(question)
        text = ""
    }
}

// MARK: - Feedback

/// "How do these notes feel?" Stored per meeting; "Not good" offers a
/// regenerate with another model.
struct MeetingFeedbackBar<RegenerateMenu: View>: View {
    let meetingID: UUID
    @ViewBuilder var regenerateMenu: () -> RegenerateMenu

    @State private var rating: MeetingFeedbackStore.Rating?
    private let store = MeetingFeedbackStore()

    var body: some View {
        HStack(spacing: 10) {
            switch rating {
            case nil:
                Text("How do these notes feel?")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                feedbackButton(.good, "Good", "hand.thumbsup")
                feedbackButton(.bad, "Not good", "hand.thumbsdown")
            case .good:
                Label("Thanks for the feedback.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Undo") { set(nil) }
                    .buttonStyle(.accentLink)
            case .bad:
                Label("Sorry about that. Try another model or template?", systemImage: "hand.thumbsdown.fill")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Menu("Regenerate") { regenerateMenu() }
                    .menuStyle(.button)
                    .fixedSize()
                Button("Undo") { set(nil) }
                    .buttonStyle(.accentLink)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(minHeight: 42)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear { rating = store.rating(for: meetingID) }
        .animation(.easeOut(duration: 0.15), value: rating)
    }

    private func feedbackButton(_ value: MeetingFeedbackStore.Rating, _ title: String, _ symbol: String) -> some View {
        Button {
            set(value)
        } label: {
            Label(title, systemImage: symbol)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .contentShape(.capsule)
        }
        .buttonStyle(MeetingChipButtonStyle())
    }

    private func set(_ value: MeetingFeedbackStore.Rating?) {
        rating = value
        store.setRating(value, for: meetingID)
    }
}

/// Per-meeting notes feedback. Swap for a field on `Meeting` if feedback is
/// ever sent anywhere; today it only stays on this Mac.
struct MeetingFeedbackStore {
    enum Rating: String { case good, bad }

    private let defaults: UserDefaults
    private static let prefix = "meetingPage.feedback."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func rating(for meetingID: UUID) -> Rating? {
        defaults.string(forKey: Self.prefix + meetingID.uuidString).flatMap(Rating.init(rawValue:))
    }

    func setRating(_ rating: Rating?, for meetingID: UUID) {
        let key = Self.prefix + meetingID.uuidString
        if let rating { defaults.set(rating.rawValue, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

// MARK: - Streaming summary

/// The summary as the model writes it, with a quiet "Writing…" state.
struct StreamingSummaryView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WritingIndicator()
            if text.isEmpty {
                SummarySkeleton()
            } else {
                MarkdownBlockView(text: text, textStyle: .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeOut(duration: 0.2), value: text.count)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text.isEmpty ? "Writing notes" : "Writing notes: \(text)")
    }
}

/// "✦ Writing…" with a soft pulse.
struct WritingIndicator: View {
    var title = "Writing notes…"
    @State private var pulse = false

    var body: some View {
        Label(title, systemImage: "sparkles")
            .font(.callout.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .opacity(pulse ? 0.45 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}

/// Placeholder lines while the first words arrive.
struct SummarySkeleton: View {
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([0.42, 0.92, 0.84, 0.66, 0.88], id: \.self) { width in
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(pulse ? 0.05 : 0.09))
                        .frame(width: geometry.size.width * width)
                }
                .frame(height: 12)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityHidden(true)
    }
}
