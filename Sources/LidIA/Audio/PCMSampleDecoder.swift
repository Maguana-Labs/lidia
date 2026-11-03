import CoreAudioTypes
import Foundation

/// Turns the first buffer of a Core Audio buffer list into mono Float32 samples.
///
/// ScreenCaptureKit delivers system audio as 32-bit float, but the format isn't guaranteed
/// (the microphone output follows the input device). Dropping every buffer that isn't
/// Float32 would silently drop a whole side of the meeting, so 16/32-bit integer PCM is
/// converted, interleaved channels are mixed down, and only formats that can't be read
/// return nil.
enum PCMSampleDecoder {
    /// - Parameters:
    ///   - data: start of the buffer's bytes.
    ///   - byteCount: `mDataByteSize` of the buffer.
    ///   - format: the stream description of the sample buffer.
    ///   - channelsInBuffer: `mNumberChannels` of this buffer (1 for non-interleaved data).
    static func decode(
        _ data: UnsafeRawPointer,
        byteCount: Int,
        format: AudioStreamBasicDescription,
        channelsInBuffer: Int
    ) -> [Float]? {
        guard format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate > 0 else { return nil }
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isBigEndian = format.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        let bits = Int(format.mBitsPerChannel)
        guard !isBigEndian, bits > 0, bits % 8 == 0 else { return nil }
        let bytesPerSample = bits / 8
        let channels = max(1, channelsInBuffer)
        let frameCount = byteCount / (bytesPerSample * channels)
        guard frameCount > 0 else { return [] }

        func sample(at index: Int) -> Float? {
            let offset = index * bytesPerSample
            switch (isFloat, bits) {
            case (true, 32):
                return data.loadUnaligned(fromByteOffset: offset, as: Float.self)
            case (true, 64):
                return Float(data.loadUnaligned(fromByteOffset: offset, as: Double.self))
            case (false, 16):
                return Float(data.loadUnaligned(fromByteOffset: offset, as: Int16.self)) / 32_768
            case (false, 32):
                return Float(data.loadUnaligned(fromByteOffset: offset, as: Int32.self)) / 2_147_483_648
            default:
                return nil
            }
        }

        guard sample(at: 0) != nil else { return nil }
        var output = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += sample(at: frame * channels + channel) ?? 0
            }
            let value = sum / Float(channels)
            output[frame] = value.isFinite ? value : 0
        }
        return output
    }
}
