import Foundation

enum AudioSource: String, Codable, Sendable {
    case mic
    case system
    case unknown
}

struct AudioChunk: Sendable {
    let samples: [Float]
    let sampleRate: Int
    let timestamp: TimeInterval
    let source: AudioSource

    var duration: TimeInterval {
        Double(samples.count) / Double(sampleRate)
    }

    init(samples: [Float], sampleRate: Int, timestamp: TimeInterval, source: AudioSource = .unknown) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.timestamp = timestamp
        self.source = source
    }

    /// Compute RMS on demand — avoids O(n) work on every chunk creation.
    static func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = sqrt(sumOfSquares / Float(samples.count))
        // A malformed buffer (NaN or huge samples) must not reach the meters as NaN/inf.
        return rms.isFinite ? rms : 0
    }
}
