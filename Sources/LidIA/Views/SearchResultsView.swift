import SwiftUI

/// Pure matching helpers for the toolbar search.
enum ShellSearch {
    /// Where a meeting matched, in priority order.
    enum Field: String, Sendable { case title, notes, summary, transcript, attendees }

    struct MeetingFields: Sendable {
        var title: String
        var notes: String
        var summary: String
        var transcript: String
        var attendees: [String]
    }

    /// The first field containing every query word, with a short snippet.
    static func match(_ fields: MeetingFields, query: String) -> (field: Field, snippet: String)? {
        let words = terms(query)
        guard !words.isEmpty else { return nil }
        let candidates: [(Field, String)] = [
            (.title, fields.title),
            (.attendees, fields.attendees.joined(separator: ", ")),
            (.notes, fields.notes),
            (.summary, fields.summary),
            (.transcript, fields.transcript),
        ]
        for (field, text) in candidates where containsAll(text, words) {
            return (field, field == .title ? "" : snippet(in: text, around: words[0]))
        }
        return nil
    }

    static func terms(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func containsAll(_ text: String, _ words: [String]) -> Bool {
        guard !text.isEmpty else { return false }
        return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// About `radius` characters either side of the first hit, on one line.
    static func snippet(in text: String, around word: String, radius: Int = 40) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let range = flat.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(flat.prefix(radius * 2))
        }
        let start = flat.index(range.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
        var result = String(flat[start..<end]).trimmingCharacters(in: .whitespaces)
        if start > flat.startIndex { result = "…" + result }
        if end < flat.endIndex { result += "…" }
        return result
    }
}

/// Toolbar search results, shown in the sidebar while the search field has
/// text: meetings (title, notes, summary, transcript), people and action
/// items, with "Ask LidIA" as the last result.
struct SearchResultsView: View {
    let query: String
    let meetings: [Meeting]
    let actionItems: [ActionItem]
    var onSelectMeeting: (Meeting) -> Void
    var onSelectPerson: (String) -> Void
    var onOpenActionItems: () -> Void
    var onAsk: (String) -> Void

    private struct MeetingHit: Identifiable {
        let meeting: Meeting
        let field: ShellSearch.Field
        let snippet: String
        var id: UUID { meeting.id }
    }

    private struct PersonHit: Identifiable {
        let id: String
        let name: String
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var meetingHits: [MeetingHit] {
        var hits: [MeetingHit] = []
        for meeting in meetings {
            let fields = ShellSearch.MeetingFields(
                title: meeting.title,
                notes: meeting.notes,
                summary: meeting.userEditedSummary ?? meeting.summary,
                transcript: meeting.userEditedTranscript ?? meeting.refinedTranscript,
                attendees: meeting.calendarAttendees ?? []
            )
            if let match = ShellSearch.match(fields, query: trimmedQuery) {
                hits.append(MeetingHit(meeting: meeting, field: match.field, snippet: match.snippet))
            }
            if hits.count >= 25 { break }
        }
        return hits
    }

    private var personHits: [PersonHit] {
        let words = ShellSearch.terms(trimmedQuery)
        var seen: Set<String> = []
        var hits: [PersonHit] = []
        for attendee in meetings.lazy.filter({ $0.status == .complete }).flatMap({ $0.calendarAttendees ?? [] }) {
            let parsed = RelationshipStore.parseAttendee(attendee)
            guard let key = parsed.email ?? parsed.displayName?.lowercased(), !seen.contains(key) else { continue }
            let name = parsed.displayName ?? parsed.email.map(RelationshipStore.displayNameFromEmail) ?? attendee
            guard ShellSearch.containsAll(name + " " + (parsed.email ?? ""), words) else { continue }
            seen.insert(key)
            hits.append(PersonHit(id: key, name: name))
            if hits.count >= 8 { break }
        }
        return hits
    }

    private var actionItemHits: [ActionItem] {
        let words = ShellSearch.terms(trimmedQuery)
        return Array(actionItems.filter { ShellSearch.containsAll($0.title, words) }.prefix(8))
    }

    var body: some View {
        let meetingHits = meetingHits
        let personHits = personHits
        let actionItemHits = actionItemHits

        List {
            if !meetingHits.isEmpty {
                Section("Meetings") {
                    ForEach(meetingHits) { hit in
                        Button {
                            onSelectMeeting(hit.meeting)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(hit.meeting.title.isEmpty ? "Untitled" : hit.meeting.title)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    MeetingStatusBadge(status: hit.meeting.status)
                                }
                                Text(hit.meeting.date, format: .dateTime.month(.abbreviated).day().year())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !hit.snippet.isEmpty {
                                    Text(hit.snippet)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Matched in \(hit.field.rawValue)")
                    }
                }
            }

            if !personHits.isEmpty {
                Section("People") {
                    ForEach(personHits) { person in
                        Button {
                            onSelectPerson(person.id)
                        } label: {
                            Label(person.name, systemImage: "person.crop.circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !actionItemHits.isEmpty {
                Section("Action Items") {
                    ForEach(actionItemHits) { item in
                        Button(action: onOpenActionItems) {
                            Label(item.title, systemImage: "circle")
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if meetingHits.isEmpty && personHits.isEmpty && actionItemHits.isEmpty {
                Text("No matches for “\(trimmedQuery)”")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    onAsk(trimmedQuery)
                } label: {
                    Label("Ask LidIA “\(trimmedQuery)”", systemImage: "sparkles")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Answer this with AI across your meetings (⌘K)")
            }
        }
        .listStyle(.sidebar)
    }
}
