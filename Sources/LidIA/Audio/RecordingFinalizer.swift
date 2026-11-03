@preconcurrency import AVFoundation
import Foundation
import os

/// Turns the raw tracks a `MeetingAudioRecorder` left on disk into playable files.
///
/// Used both when a recording stops normally and, on the next launch, for recordings
/// interrupted by a crash or force-quit. Safe to run more than once: if the raw tracks are
/// already gone it returns the final files that exist.
enum RecordingFinalizer {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "RecordingFinalizer")

    struct Output: Sendable {
        var directory: URL
        /// The file to play back: the mic+system mix, or the only track there is.
        var audioURL: URL
        var micURL: URL?
        var systemURL: URL?
        var duration: TimeInterval
        /// 16 kHz samples, filled only when `loadSamples` was requested.
        var micSamples: [Float] = []
        var systemSamples: [Float] = []
    }

    enum FinalizeError: Error, LocalizedError {
        case noAudio
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudio: "No recorded audio was found on disk."
            case .verificationFailed(let name): "The encoded audio file \(name) couldn't be read back."
            }
        }
    }

    enum Container: String, CaseIterable {
        case m4a
        case caf
    }

    // MARK: - Inspection

    /// Whether the directory holds raw or finished audio for a meeting.
    static func hasAudio(in directory: URL) -> Bool {
        rawFrames(in: directory).mic > 0
            || rawFrames(in: directory).system > 0
            || finishedFile(named: RecordingAudioStore.mixedBaseName, in: directory) != nil
            || finishedFile(named: RecordingAudioStore.micBaseName, in: directory) != nil
            || finishedFile(named: RecordingAudioStore.systemBaseName, in: directory) != nil
    }

    static func rawFrames(in directory: URL) -> (mic: Int64, system: Int64) {
        (
            PCMTrackWriter.frameCount(at: directory.appendingPathComponent(RecordingAudioStore.micRawName)),
            PCMTrackWriter.frameCount(at: directory.appendingPathComponent(RecordingAudioStore.systemRawName))
        )
    }

    static func finishedFile(named baseName: String, in directory: URL) -> URL? {
        for container in Container.allCases {
            let url = directory.appendingPathComponent("\(baseName).\(container.rawValue)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: - Finalize

    /// Encodes raw tracks to compressed files, checks that each file reads back with the
    /// expected length, and returns the result. Raw tracks are deleted afterwards unless
    /// `keepRawTracks` is set; callers that still need to transcribe keep them and call
    /// `discardRawTracks(in:)` once the transcript is saved.
    ///
    /// Blocking and potentially slow (seconds for an hour of audio); call it off the main actor.
    static func finalize(directory: URL, loadSamples: Bool, keepRawTracks: Bool = false) throws -> Output {
        let fm = FileManager.default
        let micRaw = directory.appendingPathComponent(RecordingAudioStore.micRawName)
        let systemRaw = directory.appendingPathComponent(RecordingAudioStore.systemRawName)
        let frames = rawFrames(in: directory)

        guard frames.mic > 0 || frames.system > 0 else {
            if !keepRawTracks {
                try? fm.removeItem(at: micRaw)
                try? fm.removeItem(at: systemRaw)
            }
            return try existingOutput(in: directory, loadSamples: loadSamples)
        }

        var output: Output
        if frames.mic > 0 && frames.system > 0 {
            let micURL = try encode(baseName: RecordingAudioStore.micBaseName, in: directory) { write in
                try PCMTrackWriter.forEachBlock(of: micRaw, write)
            }
            try verify(micURL, expectedFrames: frames.mic)
            let systemURL = try encode(baseName: RecordingAudioStore.systemBaseName, in: directory) { write in
                try PCMTrackWriter.forEachBlock(of: systemRaw, write)
            }
            try verify(systemURL, expectedFrames: frames.system)
            let mixURL = try encode(baseName: RecordingAudioStore.mixedBaseName, in: directory) { write in
                try mix(micRaw, systemRaw, write)
            }
            try verify(mixURL, expectedFrames: max(frames.mic, frames.system))
            output = Output(
                directory: directory,
                audioURL: mixURL,
                micURL: micURL,
                systemURL: systemURL,
                duration: Double(max(frames.mic, frames.system)) / Double(PCMTrackWriter.sampleRate)
            )
        } else {
            let isMic = frames.mic > 0
            let raw = isMic ? micRaw : systemRaw
            let url = try encode(
                baseName: isMic ? RecordingAudioStore.micBaseName : RecordingAudioStore.systemBaseName,
                in: directory
            ) { write in
                try PCMTrackWriter.forEachBlock(of: raw, write)
            }
            try verify(url, expectedFrames: max(frames.mic, frames.system))
            output = Output(
                directory: directory,
                audioURL: url,
                micURL: isMic ? url : nil,
                systemURL: isMic ? nil : url,
                duration: Double(max(frames.mic, frames.system)) / Double(PCMTrackWriter.sampleRate)
            )
        }

        if loadSamples {
            if frames.mic > 0 { output.micSamples = try PCMTrackWriter.readSamples(from: micRaw) }
            if frames.system > 0 { output.systemSamples = try PCMTrackWriter.readSamples(from: systemRaw) }
        }

        // Only now that every final file exists and reads back is it safe to drop the raw tracks.
        if !keepRawTracks {
            discardRawTracks(in: directory)
        }
        logger.info("Finalized recording in \(directory.lastPathComponent): \(String(format: "%.1f", output.duration))s")
        return output
    }

    /// Deletes the raw tracks, but only when a finished playable file exists to replace them.
    static func discardRawTracks(in directory: URL) {
        guard finishedFile(named: RecordingAudioStore.mixedBaseName, in: directory) != nil
            || finishedFile(named: RecordingAudioStore.micBaseName, in: directory) != nil
            || finishedFile(named: RecordingAudioStore.systemBaseName, in: directory) != nil else {
            logger.warning("Keeping raw tracks in \(directory.lastPathComponent): no finished audio file")
            return
        }
        let fm = FileManager.default
        try? fm.removeItem(at: directory.appendingPathComponent(RecordingAudioStore.micRawName))
        try? fm.removeItem(at: directory.appendingPathComponent(RecordingAudioStore.systemRawName))
    }

    /// Checks that an encoded file opens and holds about as many frames as were written
    /// (AAC adds or trims a few milliseconds at the edges).
    static func verify(_ url: URL, expectedFrames: Int64) throws {
        let length: Int64
        let rate: Double
        do {
            let file = try AVAudioFile(forReading: url)
            length = file.length
            rate = file.fileFormat.sampleRate
        } catch {
            throw FinalizeError.verificationFailed(url.lastPathComponent)
        }
        guard rate.isFinite, rate > 0 else {
            throw FinalizeError.verificationFailed(url.lastPathComponent)
        }
        let frames = rate == Double(PCMTrackWriter.sampleRate)
            ? length
            : Int64((Double(length) * Double(PCMTrackWriter.sampleRate) / rate).rounded())
        let tolerance = max(Int64(PCMTrackWriter.sampleRate) / 2, expectedFrames / 100)
        guard frames > 0 || expectedFrames == 0, abs(frames - expectedFrames) <= tolerance else {
            logger.error("Encoded \(url.lastPathComponent) has \(frames) frames, expected \(expectedFrames)")
            throw FinalizeError.verificationFailed(url.lastPathComponent)
        }
    }

    /// Builds the output from already-finished files (a second finalize, or recovery after
    /// a crash that happened between encoding and saving the meeting).
    private static func existingOutput(in directory: URL, loadSamples: Bool) throws -> Output {
        let micURL = finishedFile(named: RecordingAudioStore.micBaseName, in: directory)
        let systemURL = finishedFile(named: RecordingAudioStore.systemBaseName, in: directory)
        let mixURL = finishedFile(named: RecordingAudioStore.mixedBaseName, in: directory)
        guard let audioURL = mixURL ?? micURL ?? systemURL else { throw FinalizeError.noAudio }

        var output = Output(
            directory: directory,
            audioURL: audioURL,
            micURL: micURL,
            systemURL: systemURL,
            duration: (try? fileDuration(audioURL)) ?? 0
        )
        if loadSamples {
            if let micURL { output.micSamples = try readAudioFile(micURL) }
            if let systemURL { output.systemSamples = try readAudioFile(systemURL) }
        }
        return output
    }

    // MARK: - Encoding

    /// Writes 16 kHz mono blocks to `<baseName>.m4a` (AAC). Falls back to a 16-bit `.caf`
    /// if AAC encoding is unavailable. Writes to a temporary name first, so a crash during
    /// encoding never leaves a truncated file under the final name.
    static func encode(
        baseName: String,
        in directory: URL,
        preferring containers: [Container] = [.m4a, .caf],
        produce: (_ write: ([Float]) throws -> Void) throws -> Void
    ) throws -> URL {
        var lastError: Error = FinalizeError.noAudio
        for container in containers {
            do {
                return try write(container: container, baseName: baseName, in: directory, produce: produce)
            } catch {
                logger.warning("Encoding \(baseName).\(container.rawValue) failed: \(error.localizedDescription)")
                lastError = error
            }
        }
        throw lastError
    }

    private static func write(
        container: Container,
        baseName: String,
        in directory: URL,
        produce: (_ write: ([Float]) throws -> Void) throws -> Void
    ) throws -> URL {
        let fm = FileManager.default
        let finalURL = directory.appendingPathComponent("\(baseName).\(container.rawValue)")
        let tempURL = directory.appendingPathComponent("\(baseName)-partial.\(container.rawValue)")
        try? fm.removeItem(at: tempURL)

        let settings: [String: Any]
        switch container {
        case .m4a:
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: PCMTrackWriter.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ]
        case .caf:
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: PCMTrackWriter.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        }

        do {
            let file = try AVAudioFile(
                forWriting: tempURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            let format = file.processingFormat
            try produce { block in
                guard !block.isEmpty else { return }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block.count)),
                      let channel = buffer.floatChannelData?[0] else {
                    throw CocoaError(.fileWriteUnknown)
                }
                buffer.frameLength = AVAudioFrameCount(block.count)
                block.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: block.count) }
                try file.write(from: buffer)
            }
            file.close()
        } catch {
            try? fm.removeItem(at: tempURL)
            throw error
        }

        // Replace any earlier result (for example from an interrupted finalize).
        for other in Container.allCases {
            try? fm.removeItem(at: directory.appendingPathComponent("\(baseName).\(other.rawValue)"))
        }
        try fm.moveItem(at: tempURL, to: finalURL)
        return finalURL
    }

    /// Streams the sum of two raw tracks (the shorter one padded with silence).
    static func mix(_ a: URL, _ b: URL, _ write: ([Float]) throws -> Void) throws {
        let readerA = try PCMTrackReader(url: a)
        let readerB = try PCMTrackReader(url: b)
        let block = PCMTrackWriter.sampleRate * 10
        while true {
            let x = try readerA.read(maxFrames: block)
            let y = try readerB.read(maxFrames: block)
            if x.isEmpty && y.isEmpty { break }
            try write(mixBlocks(x, y))
        }
    }

    static func mixBlocks(_ x: [Float], _ y: [Float]) -> [Float] {
        let count = max(x.count, y.count)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let sum = (i < x.count ? x[i] : 0) + (i < y.count ? y[i] : 0)
            out[i] = max(-1, min(1, sum))
        }
        return out
    }

    // MARK: - Decoding

    /// Reads a finished audio file back as 16 kHz mono samples.
    static func readAudioFile(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let blockFrames: AVAudioFrameCount = 16_384
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else { break }
            try file.read(into: buffer, frameCount: blockFrames)
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        let rate = Int(format.sampleRate)
        return rate == PCMTrackWriter.sampleRate
            ? samples
            : AudioResampler.resample(samples, from: rate, to: PCMTrackWriter.sampleRate)
    }

    static func fileDuration(_ url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.fileFormat.sampleRate
    }
}
