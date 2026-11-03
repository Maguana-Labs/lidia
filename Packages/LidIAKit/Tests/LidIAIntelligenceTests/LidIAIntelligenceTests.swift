import Foundation
import Testing
@testable import LidIAIntelligence

/// A scripted generator with a small context, to exercise fitting without a model.
private struct ScriptedGenerator: TextGenerator {
    var contextTokens: Int = 4096
    var notes: String
    var displayName: String { "Scripted" }
    var isOnDevice: Bool { true }
    let calls = CallLog()

    func countTokens(_ text: String) async throws -> Int { TokenEstimate.estimate(text) }

    func respond(instructions: String, prompt: String, maxTokens: Int, temperature: Double) async throws -> String {
        await calls.record(instructions: instructions, prompt: prompt)
        if instructions == ContextFitter.condenseInstructions {
            return "Condensed: " + prompt.prefix(80)
        }
        if instructions == MeetingPrompts.factsSystemPrompt {
            return #"{"title": "Pricing review with Acme", "decisions": ["Ship in May"], "action_items": [{"title": "Send the deck", "assignee": "Ana", "deadline": "Friday"}]}"#
        }
        return "ok"
    }

    func stream(instructions: String, prompt: String, maxTokens: Int, temperature: Double) -> AsyncThrowingStream<String, Error> {
        let calls = calls
        let notes = notes
        return AsyncThrowingStream { continuation in
            Task {
                await calls.record(instructions: instructions, prompt: prompt)
                for piece in notes.split(separator: "\n", omittingEmptySubsequences: false) {
                    continuation.yield(String(piece) + "\n")
                }
                continuation.finish()
            }
        }
    }
}

private actor CallLog {
    var prompts: [(String, String)] = []
    func record(instructions: String, prompt: String) { prompts.append((instructions, prompt)) }
}

private let sampleNotes = """
```markdown
### Pricing for the EU launch
- Budget capped at $40k for Q1
  - Ana wants a second quote
- Decided: ship the EU plan in May

### Next Steps
- Ana: send the deck to Acme (Friday)
- Team: review the contract
```
"""

@Test func pipelineFitsLongTranscriptsIntoTheContext() async throws {
    let generator = ScriptedGenerator(notes: sampleNotes)
    let transcript = String(repeating: "We talked about pricing and the EU launch in detail. ", count: 1500)
    let result = try await MeetingNotesPipeline(generator: generator).run(transcript: transcript)

    #expect(result.condensedParts > 0)
    // Every request stayed inside the window (prompt + instructions + answer budget).
    for (instructions, prompt) in await generator.calls.prompts {
        let used = TokenEstimate.estimate(instructions) + TokenEstimate.estimate(prompt)
        #expect(used + 256 <= generator.contextTokens + MeetingNotesPipeline.notesOutputTokens)
    }
    #expect(result.title == "Pricing review with Acme")
    #expect(result.actionItems.first?.assignee == "Ana")
    #expect(!result.markdown.contains("```"))
}

@Test func shortTranscriptIsSentWhole() async throws {
    let generator = ScriptedGenerator(notes: sampleNotes)
    let result = try await MeetingNotesPipeline(generator: generator).run(transcript: "Short chat about the deck.")
    #expect(result.condensedParts == 0)
}

@Test func nextStepsAreParsedWithOwnersAndDeadlines() {
    let items = NotesMarkdown.nextSteps(in: sampleNotes)
    #expect(items.count == 2)
    #expect(items[0] == ExtractedActionItem(title: "Send the deck to Acme", assignee: "Ana", deadline: "Friday"))
    #expect(items[1].assignee == nil)
    #expect(NotesMarkdown.decisions(in: sampleNotes) == ["ship the EU plan in May"])
}

@Test func sectionsKeepOneLevelOfNesting() {
    let sections = NotesMarkdown.sections(in: sampleNotes)
    #expect(sections.first?.heading == "Pricing for the EU launch")
    #expect(sections.first?.bullets.map(\.depth) == [0, 1, 0])
}

@Test func streamCleanerDropsFences() {
    var cleaner = MarkdownStreamCleaner()
    var out = ""
    for chunk in ["``", "`markdown\n### A\n", "- b\n", "``", "`"] {
        out += cleaner.consume(chunk)
    }
    out += cleaner.finish()
    #expect(out.trimmingCharacters(in: .whitespacesAndNewlines) == "### A\n- b")
}

@Test func retrievalPrefersMatchingMeetings() {
    let now = Date()
    let docs = [
        MeetingDocument(id: UUID(), title: "Weekly sync", date: now, summary: "Hiring plan"),
        MeetingDocument(id: UUID(), title: "Northwind kickoff", date: now.addingTimeInterval(-86_400 * 20), summary: "TAPR scope and pricing"),
    ]
    let ranked = MeetingRetrieval.rank(query: "What did we agree on TAPR pricing?", documents: docs, limit: 1)
    #expect(ranked.first?.title == "Northwind kickoff")
}

@Test func retrievalContextStaysInBudget() {
    let doc = MeetingDocument(id: UUID(), title: "Long", date: .now, summary: String(repeating: "word ", count: 10_000))
    let (text, sources) = MeetingRetrieval.context(for: [doc], tokenBudget: 1000)
    #expect(TokenEstimate.estimate(text) <= 1100)
    #expect(sources.first?.label == 1)
}

@Test func factsDecoderToleratesFencesAndNulls() throws {
    let facts = try MeetingFactsDecoder.decode("```json\n{\"title\":\"T\",\"decisions\":[],\"action_items\":[{\"title\":\"Do it\",\"assignee\":null,\"deadline\":\"null\"}]}\n```")
    #expect(facts.actionItems == [ExtractedActionItem(title: "Do it")])
}
