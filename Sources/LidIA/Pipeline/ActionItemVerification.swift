import Foundation
import os

/// The action items a summary produced, checked against the transcript.
struct ActionItemVerification: Sendable {
    struct Check: Sendable, Equatable {
        var verdict: ActionIntent.Verdict
        var evidence: ActionIntent.Evidence?
        var originalTitle: String?
        var originalAssignee: String?
        var checkedBy: String?
    }

    /// The items, corrected (owner, direction), in the same order.
    var items: [MeetingSummaryResponse.ActionItemResponse]
    /// One per item; nil when there was no transcript to check against.
    var checks: [Check?]

    /// Saves each check for the item it became, so the board can flag it.
    @MainActor
    func record(_ added: [ActionItem], meetingDate: Date, in store: IntentStore) {
        for item in added {
            let key = ActionItem.normalizedTitle(item.title)
            guard let index = items.firstIndex(where: { ActionItem.normalizedTitle($0.title) == key }),
                  index < checks.count, let check = checks[index] else { continue }
            store.setVerification(.init(
                verdict: check.verdict, evidence: check.evidence,
                originalTitle: check.originalTitle, originalAssignee: check.originalAssignee,
                checkedBy: check.checkedBy
            ), for: item.id)
            if item.sourceQuote == nil, let quote = check.evidence?.quote { item.sourceQuote = quote }
        }
    }
}

/// Checks extracted action items against the transcript before they are
/// saved: who owns each one (the microphone is the user), who it is for,
/// and whether anything in the transcript says it. Unsupported items are
/// kept and flagged ("Not found in the transcript: keep?"), never dropped.
enum ActionItemVerifier {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "ActionItemVerifier")

    /// Marker so routing sends the check on the Action items route.
    static let marker = "You check meeting action items against the transcript"

    /// The model check runs only on meetings at least this long (words).
    static let minWordsForModelCheck = 150

    static func verify(
        _ items: [MeetingSummaryResponse.ActionItemResponse],
        words: [TranscriptWord],
        transcript: String,
        attendees: [String],
        userName: String,
        client: (any LLMClient)?,
        model: String
    ) async -> ActionItemVerification {
        let turns = words.isEmpty
            ? TranscriptTimeline.turns(fromText: transcript, userName: userName)
            : TranscriptTimeline.turns(from: words, userName: userName)
        var result = verifyDeterministic(items, turns: turns, attendees: attendees, userName: userName)
        let wordCount = words.isEmpty ? transcript.split(separator: " ").count : words.count
        guard let client, !model.isEmpty, wordCount >= minWordsForModelCheck else { return result }
        let unsure = result.checks.indices.filter { result.checks[$0]?.verdict == .weak || result.checks[$0]?.verdict == .notFound }
        guard !unsure.isEmpty else { return result }
        guard let answers = await modelCheck(result.items, indices: unsure, turns: turns, userName: userName, client: client, model: model) else { return result }
        for (index, answer) in answers {
            guard var check = result.checks[index] else { continue }
            check.checkedBy = model
            check.verdict = combine(lexical: check.evidence?.score, model: answer)
            result.checks[index] = check
        }
        return result
    }

    /// The model can confirm a passage the words already point to, or say
    /// it happened during the meeting; it can't conjure evidence.
    static func combine(lexical: Double?, model answer: String) -> ActionIntent.Verdict {
        let score = lexical ?? 0
        switch answer {
        case "said": return score >= 0.5 ? .supported : (score >= EvidenceMatcher.notFoundBelow ? .weak : .notFound)
        case "done_in_meeting": return .doneInMeeting
        default: return score >= EvidenceMatcher.supportedFrom ? .weak : .notFound
        }
    }

    /// Owner, direction and evidence without a model. Pure.
    static func verifyDeterministic(
        _ items: [MeetingSummaryResponse.ActionItemResponse],
        turns: [TranscriptTurn],
        attendees: [String],
        userName: String
    ) -> ActionItemVerification {
        guard !turns.isEmpty else { return ActionItemVerification(items: items, checks: items.map { _ in nil }) }
        let people = AttendeeParser.parse(attendees, currentUserName: userName)
        let first = userName.split(separator: " ").first.map(String.init) ?? userName
        var corrected: [MeetingSummaryResponse.ActionItemResponse] = []
        var checks: [ActionItemVerification.Check?] = []
        for item in items {
            var title = item.title
            var assignee = item.assignee
            let matches = EvidenceMatcher.matches(for: item.title, in: turns, exclude: [userName, first].filter { !$0.isEmpty }, limit: 1)
            let best = matches.first
            let verdict = EvidenceMatcher.verdict(for: best?.score)
            // "Me", "User", "You" as an owner mean the person recording.
            if let original = item.assignee, OwnerResolver.selfWords.contains(IntentText.fold(original)), !userName.isEmpty {
                assignee = userName
            } else if let original = item.assignee, OwnerResolver.isSpeakerLabel(original) {
                // "Them" / "Speaker 2" aren't people: leave the owner open.
                assignee = nil
            }
            if verdict != .notFound, let turn = best?.turn {
                let resolution = OwnerResolver.resolve(.init(title: item.title, assignee: item.assignee, userName: userName, attendees: people, evidence: turn))
                if resolution.ownerIsUser, turn.isUser == false, let suggested = resolution.suggestedTitle {
                    // Someone asked the user: the user owns it, for them.
                    title = suggested
                    if !userName.isEmpty { assignee = userName }
                }
            }
            let fixed = MeetingSummaryResponse.ActionItemResponse(title: title, assignee: assignee, deadline: item.deadline, sourceQuote: item.sourceQuote)
            corrected.append(fixed)
            checks.append(ActionItemVerification.Check(
                verdict: verdict,
                evidence: best.map { IntentBuilder.evidence($0, meetingDate: .distantPast) }.map { evidence in
                    var e = evidence
                    e.spokenAt = nil // set by the board from the meeting date
                    return e
                },
                originalTitle: fixed.title != item.title ? item.title : nil,
                originalAssignee: fixed.assignee != item.assignee ? item.assignee : nil
            ))
        }
        return ActionItemVerification(items: corrected, checks: checks)
    }

    // MARK: - Model check

    private static func modelCheck(
        _ items: [MeetingSummaryResponse.ActionItemResponse],
        indices: [Int],
        turns: [TranscriptTurn],
        userName: String,
        client: any LLMClient,
        model: String
    ) async -> [Int: String]? {
        let user = userName.isEmpty ? "the user" : userName
        var blocks: [String] = []
        for (n, index) in indices.enumerated() {
            let passages = EvidenceMatcher.matches(for: items[index].title, in: turns, limit: 2).map { match in
                let who = match.turn.isUser == true ? "\(user) (Me)" : (match.turn.speaker ?? "someone")
                return "  \(who): \"\(match.quote)\""
            }
            blocks.append("\(n + 1). \(items[index].title)\n" + (passages.isEmpty ? "  (no matching passage)" : passages.joined(separator: "\n")))
        }
        let system = """
            \(marker). For each numbered item you get the closest passages. Answer with ONLY a JSON object:
            {"items": [{"n": 1, "verdict": "said" | "done_in_meeting" | "not_said"}]}
            - "said": a passage shows someone taking on or being asked to do it after the meeting.
            - "done_in_meeting": it was done live during the meeting (shown on screen, explained right then), nothing left to do.
            - "not_said": the passages don't say it.
            """
        do {
            let raw = try await client.chat(
                messages: [.init(role: "system", content: system), .init(role: "user", content: blocks.joined(separator: "\n\n"))],
                model: model, format: .json
            )
            let cleaned = MapReduceSummarizer.stripThinking(raw)
            guard let object = IntelligenceLLMJSON.object(in: cleaned), let list = object["items"] as? [[String: Any]] else { return nil }
            var answers: [Int: String] = [:]
            for entry in list {
                guard let n = (entry["n"] as? Int) ?? (entry["n"] as? String).flatMap(Int.init), n >= 1, n <= indices.count,
                      let verdict = entry["verdict"] as? String else { continue }
                answers[indices[n - 1]] = verdict
            }
            return answers
        } catch {
            logger.warning("Action item check failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// The first JSON object in a model's reply (nonisolated twin of `IntelligenceLLM.jsonObject`).
enum IntelligenceLLMJSON {
    static func object(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
