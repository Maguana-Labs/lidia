import Foundation
import Testing
@testable import LidIA

private func word(_ text: String, _ start: TimeInterval, local: Bool? = true, speaker: Int? = nil) -> TranscriptWord {
    var w = TranscriptWord(word: text, start: start, end: start + 0.3, confidence: 1, speaker: speaker)
    w.isLocalSpeaker = local
    return w
}

// MARK: - Speaker mapping

@Suite("Speaker attribution")
struct SpeakerAttributionTests {
    @Test func micIsYouAndOneRemoteVoiceIsOthers() {
        let words = [word("Hi", 0, local: true), word("Hello", 1, local: false), word("there", 1.4, local: false)]
        let labelled = SpeakerAttribution.labelCall(words, systemSegments: [.init(speaker: 7, start: 0.9, end: 2)])
        #expect(labelled[0].isLocalSpeaker == true && labelled[0].speaker == 0)
        #expect(labelled[1].isLocalSpeaker == false && labelled[1].speaker == nil)
        #expect(SpeakerAttribution.label(isLocalSpeaker: labelled[1].isLocalSpeaker, speaker: labelled[1].speaker, speakerName: nil, localName: "You") == "Others")
    }

    @Test func severalRemoteVoicesAreNumberedInOrderOfAppearance() {
        let words = [
            word("Me", 0, local: true),
            word("first", 1, local: false),
            word("second", 5, local: false),
            word("first-again", 9, local: false),
        ]
        let segments: [SpeakerAttribution.Segment] = [
            .init(speaker: 4, start: 0.8, end: 2), .init(speaker: 1, start: 4.8, end: 6), .init(speaker: 4, start: 8.8, end: 10),
        ]
        let labelled = SpeakerAttribution.labelCall(words, systemSegments: segments)
        #expect(labelled.map(\.speaker) == [0, 1, 2, 1])
        let labels = labelled.map { SpeakerAttribution.label(isLocalSpeaker: $0.isLocalSpeaker, speaker: $0.speaker, speakerName: nil, localName: "You") }
        #expect(labels == ["You", "Speaker 2", "Speaker 3", "Speaker 2"])
    }

    @Test func micOnlyWithoutDiarizationIsAllYou() {
        // The owner's session: system audio off, every live line said "Others".
        let words = [word("hello", 0, local: nil), word("there", 1, local: nil)]
        let labelled = SpeakerAttribution.labelRoom(words, segments: [])
        #expect(labelled.allSatisfy { $0.isLocalSpeaker == true && $0.speaker == 0 })
    }

    @Test func inRoomTheDominantVoiceIsYou() {
        let words = (0..<6).map { word("w\($0)", Double($0), local: true) } + [word("guest", 10, local: true)]
        let segments: [SpeakerAttribution.Segment] = [.init(speaker: 3, start: 0, end: 6), .init(speaker: 0, start: 9.9, end: 11)]
        let labelled = SpeakerAttribution.labelRoom(words, segments: segments)
        #expect(labelled.prefix(6).allSatisfy { $0.isLocalSpeaker == true })
        #expect(labelled.last?.isLocalSpeaker == false && labelled.last?.speaker == 1)
    }

    @Test func wordJustOutsideASegmentTakesTheNearestWithinTolerance() {
        let segments: [SpeakerAttribution.Segment] = [.init(speaker: 2, start: 0, end: 1), .init(speaker: 5, start: 3, end: 4)]
        #expect(SpeakerAttribution.diarizedSpeaker(for: word("a", 1.2), in: segments) == 2)
        #expect(SpeakerAttribution.diarizedSpeaker(for: word("b", 2.6), in: segments) == 5)
        #expect(SpeakerAttribution.diarizedSpeaker(for: word("c", 20), in: segments) == nil)
    }

    @Test func liveLanesLabelMicAsYouEvenWithoutSystemAudio() {
        #expect(SourceSeparatedTranscriber.isLocalSpeaker(lane: .mic))
        #expect(!SourceSeparatedTranscriber.isLocalSpeaker(lane: .system))
    }

    @Test func recordedSingleTrackKeepsItsSource() async {
        let factory = STTEngineFactory(engineType: .whisperKit, language: "", whisperKitModel: "")
        // No samples: nothing to transcribe, but the API must not crash.
        let none = await TranscriptionService.transcribeRecorded(mic: [], system: [], factory: factory)
        #expect(none.isEmpty)
    }
}

// MARK: - Live bubbles

@Suite("Live transcript bubbles")
struct LiveTranscriptBubbleTests {
    @Test func consecutiveLinesFromOneSpeakerMergeIntoOneParagraph() {
        let words = [word("Hello.", 0), word("How", 1), word("are", 1.2), word("you?", 1.4), word("Fine.", 3, local: false), word("Thanks.", 3.5, local: false)]
        let bubbles = LiveTranscriptBubbles.bubbles(words: words)
        #expect(bubbles.count == 2)
        #expect(bubbles[0].text == "Hello. How are you?")
        #expect(bubbles[0].speaker == .you && bubbles[0].start == 0)
        #expect(bubbles[1].text == "Fine. Thanks.")
        #expect(bubbles[1].speaker == .others && bubbles[1].start == 3)
    }

    @Test func aLongPauseStartsANewBubbleWithItsOwnTime() {
        let bubbles = LiveTranscriptBubbles.bubbles(words: [word("one", 0), word("two", 45)])
        #expect(bubbles.map(\.text) == ["one", "two"])
        #expect(bubbles.map(\.start) == [0, 45])
    }

    @Test func finalTextOnlyGrowsAtTheEnd() {
        // Appending words never changes earlier bubbles or their ids.
        var words = [word("One.", 0), word("Two.", 2, local: false)]
        let before = LiveTranscriptBubbles.bubbles(words: words)
        words.append(word("Three.", 3, local: false))
        let after = LiveTranscriptBubbles.bubbles(words: words)
        #expect(after[0] == before[0])
        #expect(after[1].id == before[1].id)
        #expect(after[1].text.hasPrefix(before[1].text))
    }

    @Test func theGuessRefinesAtTheEndOfTheSpeakersBubble() {
        let words = [word("I'm", 0), word("going", 0.3)]
        let volatile: [AudioSource: LiveVolatileLine] = [.mic: .init(text: "to send a test", start: 0.6, isLocalSpeaker: true)]
        let bubbles = LiveTranscriptBubbles.bubbles(words: words, volatile: volatile)
        #expect(bubbles.count == 1)
        #expect(bubbles[0].text == "I'm going")
        #expect(bubbles[0].volatileText == "to send a test")
    }

    @Test func theOtherSidesGuessGetsItsOwnPendingBubble() {
        let words = [word("Question?", 0)]
        let volatile: [AudioSource: LiveVolatileLine] = [.system: .init(text: "Well", start: 2, isLocalSpeaker: false)]
        let bubbles = LiveTranscriptBubbles.bubbles(words: words, volatile: volatile)
        #expect(bubbles.count == 2)
        #expect(bubbles[1].speaker == .others && bubbles[1].text.isEmpty && bubbles[1].volatileText == "Well")
        #expect(bubbles[1].id < 0)
    }

    @Test func typingIndicatorWhileSpeakingBeforeWordsAppear() {
        let bubbles = LiveTranscriptBubbles.bubbles(words: [word("Hi.", 0)], speaking: [.system], now: 5)
        #expect(bubbles.last?.isTyping == true)
        #expect(bubbles.last?.speaker == .others)
        #expect(bubbles.last?.start == 5)
        // Speaking with a guess already shown: no extra "…".
        let guessed = LiveTranscriptBubbles.bubbles(
            words: [], volatile: [.mic: .init(text: "So", start: 0, isLocalSpeaker: true)], speaking: [.mic]
        )
        #expect(guessed.count == 1 && !guessed[0].isTyping)
    }

    @Test func diarizedRemoteSpeakersGetSeparateBubbles() {
        let words = [word("a", 0, local: false, speaker: 1), word("b", 1, local: false, speaker: 2)]
        let bubbles = LiveTranscriptBubbles.bubbles(words: words)
        #expect(bubbles.map { $0.label(localName: "You") } == ["Speaker 2", "Speaker 3"])
    }
}

// MARK: - SpeechAnalyzer words

@Suite("SpeechAnalyzer word splitting")
struct SpeechAnalyzerWordTests {
    @Test func punctuationRunsStickToThePreviousWord() {
        let runs: [SpeechAnalyzerWords.Run] = [
            .init(text: "Hello", start: 0, end: 0.4),
            .init(text: ",", start: nil, end: nil),
            .init(text: " world", start: 0.5, end: 0.9),
            .init(text: ".", start: 0.9, end: 0.95),
        ]
        let words = SpeechAnalyzerWords.words(from: runs, fallbackStart: 0, fallbackEnd: 1)
        #expect(words.map(\.word) == ["Hello,", "world."])
        #expect(words[0].start == 0 && words[1].start == 0.5)
        #expect(words[1].end == 0.95)
    }

    @Test func untimedWordsAreSpreadBetweenNeighbours() {
        let runs: [SpeechAnalyzerWords.Run] = [
            .init(text: "one", start: 0, end: 1),
            .init(text: " two", start: nil, end: nil),
            .init(text: " three", start: nil, end: nil),
            .init(text: " four", start: 4, end: 5),
        ]
        let words = SpeechAnalyzerWords.words(from: runs, fallbackStart: 0, fallbackEnd: 5)
        #expect(words.map(\.start) == [0, 2, 3, 4])
    }

    @Test func aRunWithSeveralWordsSplits() {
        let words = SpeechAnalyzerWords.words(from: [.init(text: " 1, 2, 3", start: 2, end: 3)], fallbackStart: 0, fallbackEnd: 3)
        #expect(words.map(\.word) == ["1,", "2,", "3"])
    }
}

// MARK: - WER

@Suite("Word error rate")
struct WordErrorRateTests {
    @Test func normalizationMakesDigitsAndPunctuationComparable() {
        #expect(WordErrorRate.normalizedWords("A test: 1, 2, 10. It's fine!") == ["a", "test", "one", "two", "ten", "it's", "fine"])
    }

    @Test func countsSubstitutionsDeletionsAndInsertions() {
        let result = WordErrorRate.compute(reference: "the cat sat on the mat", hypothesis: "the cat sit on mat now")
        #expect(result.errors == 3)
        #expect(abs(result.wer - 0.5) < 0.0001)
        #expect(WordErrorRate.compute(reference: "a b c", hypothesis: "a x c").substitutions == 1)
        #expect(WordErrorRate.compute(reference: "a b c", hypothesis: "a c").deletions == 1)
        #expect(WordErrorRate.compute(reference: "a b c", hypothesis: "a b z c").insertions == 1)
    }

    @Test func freeEndsIgnoreHypothesisOutsideTheReference() {
        let result = WordErrorRate.compute(reference: "how we do it here", hypothesis: "before that how we do it here and after", freeEnds: true)
        #expect(result.errors == 0)
        let strict = WordErrorRate.compute(reference: "how we do it here", hypothesis: "before that how we do it here and after")
        #expect(strict.insertions == 4)
    }

    @Test func truncatedWordsAreFound() {
        let reference = WordErrorRate.normalizedWords("this actually works on lydia")
        let hypothesis = WordErrorRate.normalizedWords("this actu works on lyd")
        let alignment = WordErrorRate.compute(reference: reference, hypothesis: hypothesis)
        #expect(WordErrorRate.truncatedWords(reference: reference, hypothesis: hypothesis, alignment: alignment) == ["actu", "lyd"])
    }

    @Test func formattingStats() {
        let punctuated = WordErrorRate.Formatting.measure("Hello there. How are you? Fine, 10 of 10.")
        #expect(punctuated.capitalizedSentenceShare == 1)
        #expect(punctuated.usesDigits)
        let flat = WordErrorRate.Formatting.measure("hello there how are you")
        #expect(flat.sentenceMarksPer100Words == 0)
    }
}

// MARK: - Engine plan

@Suite("Live engine plan")
struct LiveEnginePlanTests {
    @Test func appleAnalyzerIsTheDefaultLiveEngineWhenInstalled() {
        let plan = LiveEnginePlan.make(requested: .parakeet, parakeetLiveModelPresent: true, appleOnDeviceAvailable: false, analyzer: .installed)
        #expect(plan.primary == .appleSpeech && plan.fallback == .parakeet && plan.downloadModelFor == nil)
    }

    @Test func parakeetRunsWhileMacOSDownloadsTheSpeechModel() {
        let plan = LiveEnginePlan.make(requested: .parakeet, parakeetLiveModelPresent: true, appleOnDeviceAvailable: false, analyzer: .needsDownload)
        #expect(plan.primary == .parakeet && plan.downloadModelFor == .appleSpeech)
    }

    @Test func unsupportedLanguageKeepsTheOldPlan() {
        let plan = LiveEnginePlan.make(requested: .parakeet, parakeetLiveModelPresent: true, appleOnDeviceAvailable: false, analyzer: .unsupported)
        #expect(plan.primary == .parakeet && plan.fallback == nil)
    }

    @Test func onlyAppleLiveTranscriptsAreKeptAsFinal() {
        #expect(STTEngineFactory.liveTranscriptIsFinal(engine: .appleSpeech))
        #expect(!STTEngineFactory.liveTranscriptIsFinal(engine: .parakeet))
        #expect(!STTEngineFactory.liveTranscriptIsFinal(engine: nil))
    }
}
