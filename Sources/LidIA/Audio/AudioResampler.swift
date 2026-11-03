import Foundation

/// Shared linear resampling utility used by STT engines.
enum AudioResampler {
    /// Simple linear interpolation resampling from one sample rate to another.
    static func resample(_ samples: [Float], from sourceRate: Int, to targetRate: Int) -> [Float] {
        guard sourceRate != targetRate, !samples.isEmpty else { return samples }
        // A 0 Hz rate (a device that reports no format) would make the ratio infinite
        // and `Int(_:)` trap. There is no meaningful audio to return.
        guard sourceRate > 0, targetRate > 0 else { return [] }
        let ratio = Double(targetRate) / Double(sourceRate)
        let outputCount = Int(Double(samples.count) * ratio)
        var output = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let srcIndex = Double(i) / ratio
            let idx = Int(srcIndex)
            let frac = Float(srcIndex - Double(idx))
            if idx + 1 < samples.count {
                output[i] = samples[idx] * (1 - frac) + samples[idx + 1] * frac
            } else if idx < samples.count {
                output[i] = samples[idx]
            }
        }
        return output
    }
}
