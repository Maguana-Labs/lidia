import FluidAudio
import Foundation
import os

/// Splits one recorded track (16 kHz mono) into speaker turns after the meeting:
/// speech-swift's pyannote + WeSpeaker pipeline, falling back to FluidAudio's offline
/// diarizer. Returns no segments when both fail; the transcript then keeps its
/// source labels (You / Others).
enum RecordingDiarizer {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "RecordingDiarizer")

    static func segments(samples: [Float]) async -> [SpeakerAttribution.Segment] {
        guard samples.count > 16_000 else { return [] }
        do {
            let segments = try await SpeechSwiftDiarizer.shared.diarize(samples: samples)
            logger.info("speech-swift diarization: \(Set(segments.map(\.speakerId)).count) speakers")
            return segments.map { .init(speaker: $0.speakerId, start: TimeInterval($0.startTime), end: TimeInterval($0.endTime)) }
        } catch {
            logger.warning("speech-swift diarization failed, trying FluidAudio: \(error.localizedDescription, privacy: .public)")
        }
        do {
            let diarizer = OfflineDiarizerManager(config: OfflineDiarizerConfig(
                segmentationMinDurationOn: 1.0,
                segmentationMinDurationOff: 0.5
            ))
            try await diarizer.prepareModels()
            let result = try await diarizer.process(audio: samples)
            let ids = Array(Set(result.segments.map(\.speakerId))).sorted()
            let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
            logger.info("FluidAudio diarization: \(ids.count) speakers")
            return result.segments.map {
                .init(speaker: index[$0.speakerId] ?? 0, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds))
            }
        } catch {
            logger.error("Diarization failed; keeping source labels: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
