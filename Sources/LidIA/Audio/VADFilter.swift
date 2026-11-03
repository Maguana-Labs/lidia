import Foundation
import SpeechVAD
import os

/// Filters audio samples to speech-only regions using Pyannote VAD.
///
/// Used in the batch post-processing path to strip silence before STT inference,
/// improving both speed (less audio to process) and accuracy (less noise/silence
/// confused as speech).
actor VADFilter {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "VADFilter")

    /// Shared singleton — the underlying model is expensive to load.
    static let shared = VADFilter()

    private var model: PyannoteVADModel?

    /// Load the VAD model if not already loaded. Downloads on first use.
    func loadIfNeeded() async throws {
        guard model == nil else { return }

        Self.logger.info("Loading Pyannote VAD model (first use downloads from HuggingFace)...")
        let loaded = try await PyannoteVADModel.fromPretrained(
            progressHandler: { progress, status in
                Self.logger.info("VAD model: \(status) (\(Int(progress * 100))%)")
            }
        )
        model = loaded
        Self.logger.info("Pyannote VAD model ready")
    }

    /// Filter audio samples to only include speech regions.
    ///
    /// Runs VAD to detect speech segments, then extracts and concatenates
    /// only the speech portions of the audio. Returns the original samples
    /// if VAD finds no speech (safety fallback).
    ///
    /// - Parameters:
    ///   - samples: PCM Float32 audio samples
    ///   - sampleRate: Sample rate in Hz (auto-resampled to 16kHz internally)
    /// - Returns: Filtered samples containing only speech regions
    func filterSpeech(samples: [Float], sampleRate: Int) async throws -> [Float] {
        try await loadIfNeeded()

        guard let model else {
            Self.logger.warning("VAD model not loaded, returning unfiltered audio")
            return samples
        }

        let segments = model.detectSpeech(audio: samples, sampleRate: sampleRate)

        guard !segments.isEmpty else {
            Self.logger.info("VAD found no speech segments, returning original audio")
            return samples
        }

        let totalDuration = Float(samples.count) / Float(sampleRate)
        let speechDuration = segments.reduce(Float(0)) { $0 + $1.duration }

        Self.logger.info("""
            VAD pre-filter: \(segments.count) speech segments, \
            \(String(format: "%.1f", speechDuration))s speech / \
            \(String(format: "%.1f", totalDuration))s total \
            (\(String(format: "%.0f", (1 - speechDuration / totalDuration) * 100))% silence removed)
            """)

        let (filtered, _) = Self.extract(
            samples: samples,
            sampleRate: sampleRate,
            ranges: segments.map { (start: TimeInterval($0.startTime), end: TimeInterval($0.endTime)) }
        )

        // Safety: if filtering produced nothing, return original
        if filtered.isEmpty {
            Self.logger.warning("VAD filtering produced empty result, returning original audio")
            return samples
        }

        return filtered
    }

    /// Like `filterSpeech`, but also returns a map from times in the filtered audio back to
    /// times in the original, so transcripts of the filtered audio keep real timings.
    /// Without it, removed silence shifts every later word earlier and two separately
    /// filtered tracks (mic, system) no longer interleave correctly.
    func filterSpeechKeepingTimeline(samples: [Float], sampleRate: Int) async throws -> (samples: [Float], timeMap: SpeechTimeMap) {
        try await loadIfNeeded()
        guard let model else { return (samples, .identity) }
        let segments = model.detectSpeech(audio: samples, sampleRate: sampleRate)
        guard !segments.isEmpty else { return (samples, .identity) }
        let (filtered, map) = Self.extract(
            samples: samples,
            sampleRate: sampleRate,
            ranges: segments.map { (start: TimeInterval($0.startTime), end: TimeInterval($0.endTime)) }
        )
        guard !filtered.isEmpty else { return (samples, .identity) }
        Self.logger.info("VAD pre-filter kept \(String(format: "%.1f", Double(filtered.count) / Double(sampleRate)))s of \(String(format: "%.1f", Double(samples.count) / Double(sampleRate)))s")
        return (filtered, map)
    }

    /// Concatenates the given time ranges of `samples` and records where each one came from.
    static func extract(
        samples: [Float],
        sampleRate: Int,
        ranges: [(start: TimeInterval, end: TimeInterval)]
    ) -> (samples: [Float], timeMap: SpeechTimeMap) {
        var filtered: [Float] = []
        var spans: [SpeechTimeMap.Span] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            let startSample = max(0, Int(range.start * Double(sampleRate)))
            let endSample = min(samples.count, Int(range.end * Double(sampleRate)))
            guard startSample < endSample else { continue }
            spans.append(.init(
                filteredStart: Double(filtered.count) / Double(sampleRate),
                originalStart: Double(startSample) / Double(sampleRate),
                duration: Double(endSample - startSample) / Double(sampleRate)
            ))
            filtered.append(contentsOf: samples[startSample..<endSample])
        }
        return (filtered, SpeechTimeMap(spans: spans))
    }
}

/// Maps times in VAD-filtered (silence-removed) audio back to the original recording.
struct SpeechTimeMap: Sendable, Equatable {
    struct Span: Sendable, Equatable {
        var filteredStart: TimeInterval
        var originalStart: TimeInterval
        var duration: TimeInterval
    }

    var spans: [Span]

    static let identity = SpeechTimeMap(spans: [])

    func originalTime(_ filteredTime: TimeInterval) -> TimeInterval {
        guard !spans.isEmpty else { return filteredTime }
        // Last span starting at or before this time; times past a span's end (rounding at
        // the seam) stay attached to that span.
        var lo = 0
        var hi = spans.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if spans[mid].filteredStart <= filteredTime { lo = mid } else { hi = mid - 1 }
        }
        let span = spans[lo]
        return span.originalStart + max(0, filteredTime - span.filteredStart)
    }

    func remap(_ words: [TranscriptWord]) -> [TranscriptWord] {
        guard !spans.isEmpty else { return words }
        return words.map { word in
            var w = word
            w.start = originalTime(word.start)
            w.end = max(w.start, originalTime(word.end))
            return w
        }
    }
}
