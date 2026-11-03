import Foundation
import Testing
@testable import LidIA

@Suite("Proactive notes")
struct NoteProactiveTests {
    // MARK: Auto title

    @Test func placeholderTitlesAreRetitledOnceThereIsContent() {
        #expect(NoteAutoTitle.isPlaceholder("New Note"))
        #expect(NoteAutoTitle.isPlaceholder("  nueva nota "))
        #expect(NoteAutoTitle.isPlaceholder(""))
        #expect(!NoteAutoTitle.isPlaceholder("CRB cash disbursement"))
        #expect(!NoteAutoTitle.shouldTitle(currentTitle: "New Note", contentLength: 5, aiTitle: nil, userTitled: false), "too little to title")
        #expect(NoteAutoTitle.shouldTitle(currentTitle: "New Note", contentLength: 90, aiTitle: nil, userTitled: false))
    }

    @Test func aTypedTitleIsNeverOverwritten() {
        #expect(!NoteAutoTitle.shouldTitle(currentTitle: "Bank errand", contentLength: 900, aiTitle: nil, userTitled: false))
        #expect(!NoteAutoTitle.shouldTitle(currentTitle: "New Note", contentLength: 900, aiTitle: nil, userTitled: true),
                "even back to a placeholder: the user chose it")
        let ai = IntentStore.AITitle(title: "CRB cash disbursement (code 41503)", contentLength: 90, date: .now)
        #expect(NoteAutoTitle.isUserEdit(newTitle: "CRB cash pickup", aiTitle: ai))
        #expect(!NoteAutoTitle.isUserEdit(newTitle: ai.title, aiTitle: ai))
        #expect(!NoteAutoTitle.isUserEdit(newTitle: "New Note", aiTitle: ai))
    }

    @Test func anAITitleIsRefreshedOnlyWhenTheNoteGrowsALot() {
        let ai = IntentStore.AITitle(title: "CRB cash disbursement (code 41503)", contentLength: 90, date: .now)
        #expect(!NoteAutoTitle.shouldTitle(currentTitle: ai.title, contentLength: 120, aiTitle: ai, userTitled: false))
        #expect(NoteAutoTitle.shouldTitle(currentTitle: ai.title, contentLength: 400, aiTitle: ai, userTitled: false))
    }

    @MainActor
    @Test func userTitlesStickInTheStore() {
        let store = IntentStore(url: nil)
        let id = UUID()
        store.setAITitle("CRB cash disbursement (code 41503)", contentLength: 90, for: id)
        store.markUserTitled(id)
        #expect(store.isUserTitled(id))
        #expect(store.aiTitle(for: id) == nil)
        #expect(!NoteAutoTitle.shouldTitle(currentTitle: "New Note", contentLength: 500, aiTitle: store.aiTitle(for: id), userTitled: store.isUserTitled(id)))
    }

    @Test func modelRepliesBecomeCleanTitles() {
        #expect(NoteAutoTitle.clean("\"CRB cash disbursement (code 41503)\".") == "CRB cash disbursement (code 41503)")
        #expect(NoteAutoTitle.clean("Title: CRB cash disbursement\n\nmore") == "CRB cash disbursement")
        #expect(NoteAutoTitle.clean("New Note") == nil)
        #expect(NoteAutoTitle.clean("   ") == nil)
    }

    @MainActor
    @Test func debounceRunsOnlyAfterTypingPauses() async throws {
        let debouncer = Debouncer(delay: .milliseconds(500))
        var runs: [Int] = []
        for keystroke in 1...5 {
            debouncer.schedule { runs.append(keystroke) }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(runs.isEmpty, "still typing")
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(runs == [5], "one title, for the last text")
        debouncer.schedule { runs.append(6) }
        debouncer.cancel()
        try await Task.sleep(for: .milliseconds(800))
        #expect(runs == [5])
    }

    // MARK: Transcribe new notes

    @Test(arguments: [
        (NoteTranscriptionMode.duringMeetings, true, false, false, NoteTranscriptionPolicy.Decision.start),
        (.duringMeetings, false, true, false, .start),
        (.duringMeetings, false, false, false, .offer),
        (.duringMeetings, true, true, true, .none),
        (.always, false, false, false, .start),
        (.always, false, false, true, .none),
        (.never, true, true, false, .none),
    ])
    func newNoteTranscriptionRules(_ mode: NoteTranscriptionMode, _ calendar: Bool, _ micApp: Bool, _ recording: Bool, _ expected: NoteTranscriptionPolicy.Decision) {
        #expect(NoteTranscriptionPolicy.decide(mode: mode, calendarMeetingNow: calendar, meetingAppOnMic: micApp, alreadyRecording: recording) == expected)
    }

    @MainActor
    @Test func theSettingDefaultsToDuringMeetingsAndIsSearchable() {
        #expect(NoteTranscriptionMode(rawValue: "") == nil)
        #expect(SettingsSearchIndex.entries.contains { $0.anchor == .noteTranscription && $0.pane == .recording })
        #expect(SettingsSearchIndex.entries.contains { $0.anchor == .linear })
    }
}
