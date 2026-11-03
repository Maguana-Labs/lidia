import SwiftData
import SwiftUI

/// Settings → Recording → Custom vocabulary: words LidIA learned from the
/// user's own meetings, on this Mac. Mishearings ("taper → TAPR") and names
/// the transcript should always spell one way ("Pinecrest").
struct VocabularySuggestionsSection: View {
    @Bindable var settings: AppSettings
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]

    @State private var suggestions: [VocabularyMiner.Suggestion] = []
    @State private var isMining = false

    private var visible: [VocabularyMiner.Suggestion] {
        let dismissed = IntelligenceStore.shared.state.dismissedVocabulary
        let existing = Set(settings.customVocabulary.map { $0.replaceTo.lowercased() })
        return suggestions.filter { !dismissed.contains($0.id) && !existing.contains($0.term.lowercased()) }
    }

    var body: some View {
        Section {
            if isMining && suggestions.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading your meetings…")
                        .foregroundStyle(.secondary)
                }
            } else if visible.isEmpty {
                Text(meetings.isEmpty
                     ? "After a few meetings, LidIA suggests names and terms your transcripts get wrong."
                     : "No suggestions right now. LidIA keeps learning from new meetings.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visible) { suggestion in
                    row(suggestion)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Text("Suggested from your meetings")
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Found on this Mac, in your own transcripts and notes")
            }
        } footer: {
            Text("LidIA compares how your notes spell a term with what the transcript heard. Added words fix future transcripts and guide the AI that cleans them up.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: meetings.count) { await mine() }
    }

    private func row(_ suggestion: VocabularyMiner.Suggestion) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let heardAs = suggestion.heardAs {
                        Text(([heardAs] + suggestion.variants.filter { $0 != heardAs }.prefix(2)).joined(separator: ", "))
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("becomes")
                    }
                    Text(suggestion.term)
                        .fontWeight(.semibold)
                    Text(suggestion.kind == .acronym ? "Acronym" : "Name")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                Text(suggestion.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Add") { add(suggestion) }
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityLabel("Add \(suggestion.term) to custom vocabulary")
            Button {
                IntelligenceStore.shared.dismissVocabulary(suggestion.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Not useful")
            .accessibilityLabel("Dismiss \(suggestion.term)")
        }
        .accessibilityElement(children: .combine)
    }

    private func add(_ suggestion: VocabularyMiner.Suggestion) {
        let heard = suggestion.variants.isEmpty ? [suggestion.term] : suggestion.variants
        for variant in heard where !settings.customVocabulary.contains(where: {
            $0.heardAs.caseInsensitiveCompare(variant) == .orderedSame && $0.replaceTo == suggestion.term
        }) {
            settings.customVocabulary.append(AppSettings.VocabularyEntry(heardAs: variant, replaceTo: suggestion.term))
        }
    }

    private func mine() async {
        isMining = true
        defer { isMining = false }
        let documents = meetings.filter { !$0.isDeleted }.prefix(200).map { meeting in
            VocabularyMiner.Document(
                id: meeting.id,
                written: [meeting.title, meeting.userEditedSummary ?? meeting.summary, meeting.notes,
                          (meeting.calendarAttendees ?? []).joined(separator: ", ")].joined(separator: "\n"),
                heard: meeting.refinedTranscript,
                title: meeting.title
            )
        }
        let existing = Set(settings.customVocabulary.map(\.replaceTo))
        // The user's own name is spelled right everywhere; never suggest it.
        MeetingAttendeeContext.currentUserName = settings.displayName
        var exclude = Set(settings.displayName.split(separator: " ").map(String.init))
        for meeting in meetings.prefix(50) {
            for attendee in meeting.libraryAttendees where attendee.isCurrentUser {
                exclude.formUnion(attendee.name.split(separator: " ").map(String.init))
            }
        }
        let docs = Array(documents)
        suggestions = await Task.detached(priority: .utility) {
            VocabularyMiner.mine(docs, existing: existing, exclude: exclude, limit: 12)
        }.value
    }
}

/// Confirmed custom vocabulary as a glossary for AI prompts: the right
/// spellings, one per line. The transcript cleanup already receives the
/// full "heard → write" list; summaries can add this block.
enum PersonalGlossary {
    static func terms(_ vocabulary: [AppSettings.VocabularyEntry]) -> [String] {
        var seen: Set<String> = []
        return vocabulary.compactMap { entry in
            let term = entry.replaceTo.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { return nil }
            return term
        }
    }

    static func promptBlock(_ vocabulary: [AppSettings.VocabularyEntry]) -> String {
        let list = terms(vocabulary)
        guard !list.isEmpty else { return "" }
        return "Glossary (spell these exactly): " + list.joined(separator: ", ")
    }
}
