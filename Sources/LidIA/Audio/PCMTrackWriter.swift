import Foundation
import os

/// The shared timeline that keeps a recording's tracks aligned.
///
/// Callers place chunks by their position on the recording's timeline (wall-clock time
/// since start, minus pauses). A clock jump, for example sleep/wake, would otherwise mean
/// padding hours of silence. When a chunk lands more than `maxGapFillFrames` past the
/// furthest point any track has reached, the timeline origin moves forward so the jump
/// costs at most one capped fill. Every track sharing this timeline sees the same shift,
/// so the tracks stay aligned with each other.
final class PCMTrackTimeline: @unchecked Sendable {
    private struct State {
        /// Frames removed from the timeline by capped clock jumps.
        var shift: Int64 = 0
        /// Furthest timeline frame any track has been asked to reach.
        var highWater: Int64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let maxGapFillFrames: Int64

    init(maxGapFillFrames: Int64 = PCMTrackWriter.maxGapFillFrames) {
        self.maxGapFillFrames = maxGapFillFrames
    }

    /// Frames cut from the timeline so far. Subtract this from raw timeline positions to
    /// get positions in the recorded files.
    var shiftFrames: Int64 {
        state.withLock { $0.shift }
    }

    /// Records audio already on disk (a reopened track), so it counts as reached.
    func noteExisting(frames: Int64) {
        state.withLock { $0.highWater = max($0.highWater, frames) }
    }

    /// Maps a raw timeline frame to the file frame where `count` samples should start,
    /// moving the origin forward when the jump is larger than one capped fill.
    func place(rawFrame: Int64, count: Int) -> Int64 {
        state.withLock { s in
            var target = rawFrame - s.shift
            let jump = target - s.highWater
            if jump > maxGapFillFrames {
                s.shift += jump - maxGapFillFrames
                target = s.highWater + maxGapFillFrames
            }
            s.highWater = max(s.highWater, target + Int64(count))
            return target
        }
    }
}

/// Appends one mono audio track to a raw 16 kHz, 16-bit little-endian PCM file.
///
/// The file has no header, so every byte that reaches the disk stays readable after a crash
/// or force-quit. Samples are buffered in memory and written by `flush()`; the recorder
/// flushes every second, so a force-quit loses at most about a second of audio.
///
/// Thread-safe: `append` can be called from audio callback threads while `flush` runs on a
/// background queue.
final class PCMTrackWriter: @unchecked Sendable {
    static let sampleRate = 16_000
    static let bytesPerFrame = MemoryLayout<Int16>.size

    /// Gaps shorter than this are treated as callback jitter and are not padded.
    static let gapToleranceFrames: Int64 = Int64(sampleRate) / 4
    /// Upper bound for the silence one clock jump (for example sleep/wake) can add, so it
    /// can't write hours of zeros. Enforced by `PCMTrackTimeline`.
    static let maxGapFillFrames: Int64 = Int64(sampleRate) * 300

    private static let logger = Logger(subsystem: "io.lidia.app", category: "PCMTrackWriter")

    let url: URL
    let timeline: PCMTrackTimeline

    private struct State {
        /// Samples not yet written. Removed only once a write succeeds.
        var pending: [Int16] = []
        /// Frames appended so far: written plus pending.
        var totalFrames: Int64 = 0
        var closed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Serialises file I/O. Never taken by `append`, so audio threads don't wait on disk.
    private let io = NSLock()
    /// Guarded by `io`.
    private var handle: FileHandle?
    /// Performs the file write. Guarded by `io`; tests replace it to simulate a full disk.
    var writeData: (FileHandle, Data) throws -> Void = { handle, data in
        try handle.write(contentsOf: data)
    }

    /// Opens (or creates) the file and appends after any existing audio.
    ///
    /// - Parameter timeline: share one between a recording's tracks to keep them aligned.
    init(url: URL, timeline: PCMTrackTimeline = PCMTrackTimeline()) throws {
        self.url = url
        self.timeline = timeline
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        var existing = try handle.seekToEnd()
        if existing % UInt64(Self.bytesPerFrame) != 0 {
            // A crash mid-write left half a sample; drop it so frames stay aligned.
            existing -= existing % UInt64(Self.bytesPerFrame)
            try handle.truncate(atOffset: existing)
            try handle.seek(toOffset: existing)
        }
        self.handle = handle
        let frames = Int64(existing) / Int64(Self.bytesPerFrame)
        state.withLock { $0.totalFrames = frames }
        timeline.noteExisting(frames: frames)
    }

    /// Frames appended so far, including those not yet flushed and any silence padding.
    var totalFrames: Int64 {
        state.withLock { $0.totalFrames }
    }

    /// Frames buffered in memory and not yet written (for example after a failed write).
    var pendingFrames: Int {
        state.withLock { $0.pending.count }
    }

    var duration: TimeInterval {
        Double(totalFrames) / Double(Self.sampleRate)
    }

    /// Appends 16 kHz mono samples.
    ///
    /// - Parameter timelineFrame: where these samples start on the recording's shared timeline.
    ///   If the track is behind that point by more than `gapToleranceFrames`, silence is inserted
    ///   first, so mic and system tracks stay aligned when one of them starts late or drops out.
    ///   A clock jump past every track is capped by the shared `timeline`.
    func append(_ samples: [Float], timelineFrame: Int64? = nil) {
        guard !samples.isEmpty else { return }
        let converted = Self.toInt16(samples)
        let target = timelineFrame.map { timeline.place(rawFrame: $0, count: converted.count) }
        state.withLock { s in
            guard !s.closed else { return }
            if let target {
                let gap = target - s.totalFrames
                if gap > Self.gapToleranceFrames {
                    // Bounded: the timeline never places a chunk more than one capped fill
                    // past the furthest point any track has reached.
                    s.pending.append(contentsOf: repeatElement(Int16(0), count: Int(gap)))
                    s.totalFrames += gap
                }
            }
            s.pending.append(contentsOf: converted)
            s.totalFrames += Int64(converted.count)
        }
    }

    /// Writes buffered samples to the file. With `sync`, also asks the OS to commit them to
    /// storage (only needed to survive power loss; a process crash keeps written data).
    ///
    /// If the write fails (for example the disk is full), the samples stay buffered and the
    /// next flush retries them, so the file never falls behind `totalFrames` for good.
    @discardableResult
    func flush(sync: Bool = false) throws -> Int {
        io.lock()
        defer { io.unlock() }
        guard let handle else { return 0 }
        // Appends only add to the end, so these are still the first `chunk.count` pending
        // samples once the write finishes.
        let chunk = state.withLock { $0.pending }
        if !chunk.isEmpty {
            let data = chunk.withUnsafeBufferPointer { Data(buffer: $0) }
            let offset = try handle.offset()
            do {
                try writeData(handle, data)
            } catch {
                // Drop any partial write so the retry doesn't duplicate samples.
                try? handle.truncate(atOffset: offset)
                throw error
            }
            state.withLock { $0.pending.removeFirst(chunk.count) }
        }
        if sync {
            try handle.synchronize()
        }
        return chunk.count
    }

    /// Flushes, syncs and closes the file. Later appends are ignored, even when the final
    /// flush fails.
    func close() throws {
        state.withLock { $0.closed = true }
        defer {
            io.lock()
            try? handle?.close()
            handle = nil
            io.unlock()
        }
        try flush(sync: true)
    }

    // MARK: - Conversion

    static func toInt16(_ samples: [Float]) -> [Int16] {
        samples.map { sample in
            let clamped = max(-1, min(1, sample.isFinite ? sample : 0))
            return Int16((clamped * Float(Int16.max)).rounded())
        }
    }

    static func toFloat(_ samples: UnsafeBufferPointer<Int16>) -> [Float] {
        let scale = 1 / Float(Int16.max)
        return samples.map { Float($0) * scale }
    }

    // MARK: - Reading

    /// Number of whole frames in a raw track file (0 if missing).
    static func frameCount(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.int64Value / Int64(bytesPerFrame)
    }

    /// Reads a whole raw track as Float samples in [-1, 1]. A trailing half sample is ignored.
    static func readSamples(from url: URL) throws -> [Float] {
        var result: [Float] = []
        result.reserveCapacity(Int(frameCount(at: url)))
        try forEachBlock(of: url) { result.append(contentsOf: $0) }
        return result
    }

    /// Streams a raw track in blocks of at most `blockFrames` frames.
    static func forEachBlock(
        of url: URL,
        blockFrames: Int = sampleRate * 10,
        _ body: ([Float]) throws -> Void
    ) throws {
        let reader = try PCMTrackReader(url: url)
        while true {
            let block = try reader.read(maxFrames: blockFrames)
            guard !block.isEmpty else { break }
            try body(block)
        }
    }
}

/// Sequential reader for raw 16-bit PCM track files written by `PCMTrackWriter`.
final class PCMTrackReader {
    private let handle: FileHandle
    private var carry = Data()

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit {
        try? handle.close()
    }

    /// Returns up to `maxFrames` samples, or an empty array at end of file.
    func read(maxFrames: Int) throws -> [Float] {
        let bytesPerFrame = PCMTrackWriter.bytesPerFrame
        let wanted = max(0, maxFrames * bytesPerFrame - carry.count)
        let data = wanted > 0 ? (try handle.read(upToCount: wanted) ?? Data()) : Data()
        var bytes = carry + data
        carry = Data()
        let usable = bytes.count - bytes.count % bytesPerFrame
        if usable < bytes.count {
            carry = Data(bytes.suffix(bytes.count - usable))
            bytes = Data(bytes.prefix(usable))
        }
        // Empty means end of file, or only half a sample left from a torn write.
        guard !bytes.isEmpty else { return [] }
        var ints = [Int16](repeating: 0, count: bytes.count / bytesPerFrame)
        _ = ints.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
        return ints.withUnsafeBufferPointer { PCMTrackWriter.toFloat($0) }
    }
}
