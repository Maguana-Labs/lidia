import Foundation

/// Mirrors `Sources/LidIA/Models/TranscriptWord.swift`; keep the two in step.
public struct TranscriptWord: Codable, Sendable, Equatable {
    public var word: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var confidence: Double
    public var speaker: Int?
    public var speakerName: String?
    public var isLocalSpeaker: Bool?

    public init(
        word: String,
        start: TimeInterval,
        end: TimeInterval,
        confidence: Double,
        speaker: Int? = nil,
        speakerName: String? = nil,
        isLocalSpeaker: Bool? = nil
    ) {
        self.word = word
        self.start = start
        self.end = end
        self.confidence = confidence
        self.speaker = speaker
        self.speakerName = speakerName
        self.isLocalSpeaker = isLocalSpeaker
    }
}
