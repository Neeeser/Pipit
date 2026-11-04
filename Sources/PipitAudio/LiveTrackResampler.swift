import AVFoundation
import Foundation
import PipitCore

/// Turns the buffers one capture source delivers into 16 kHz mono samples,
/// placed on a shared timeline by the host time each buffer carries.
///
/// The live transcript reads the same buffers the segment writer saves, so it
/// sees whatever the hardware delivers: 48 kHz, two channels, or a bare
/// three-capsule microphone array. Channels are averaged to mono first, then
/// resampled; the converter keeps its state between calls, so a stream fed one
/// buffer at a time comes out continuous.
///
/// Not thread-safe: one per track, driven from one queue.
public final class LiveTrackResampler {
    public static let sampleRate: Double = 16_000

    private let origin: Double
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var monoFormat: AVAudioFormat?
    private let targetFormat: AVAudioFormat
    /// The timeline index the next output sample belongs at.
    private var nextIndex: Int?
    /// Running level of a bare microphone array, which arrives without the
    /// gain macOS applies on its processed path and needs lifting the way the
    /// after-call reader lifts it.
    private var arrayEnergy: Double = 0
    private var arrayFrames = 0
    private var arrayPeak: Float = 0

    /// - Parameter origin: host time, in seconds, of timeline index zero.
    public init(origin: Double) {
        self.origin = origin
        // Standard 16 kHz mono float always exists.
        // swiftlint:disable:next force_unwrapping
        targetFormat = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
    }

    /// The samples in `packet`, and the timeline index of the first one.
    ///
    /// A gap of more than a tenth of a second between buffers, from a device
    /// change or a dropped callback, moves the output to where the host time
    /// says it belongs, so the two tracks stay lined up for the echo remover.
    public func convert(_ packet: AudioBufferPacket) -> (samples: [Float], start: Int)? {
        let buffer = packet.buffer
        guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { return nil }
        let format = buffer.format
        if sourceFormat?.sampleRate != format.sampleRate || sourceFormat?.channelCount != format.channelCount {
            rebuild(for: format)
        }
        guard let converter, let monoFormat,
            let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
            let monoData = mono.floatChannelData?[0]
        else { return nil }

        let frames = Int(buffer.frameLength)
        let count = Int(format.channelCount)
        let stride = buffer.stride
        let interleaved = stride > 1
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<count {
                sum += interleaved ? channels[0][frame * stride + channel] : channels[channel][frame]
            }
            monoData[frame] = sum / Float(count)
        }
        mono.frameLength = buffer.frameLength
        if count > 2 { liftArray(monoData, frames: frames) }

        let ratio = Self.sampleRate / format.sampleRate
        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(Double(frames) * ratio) + 64
            )
        else { return nil }
        let pending = LockedBox<AVAudioPCMBuffer?>(mono)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            pending.withLock { next in
                guard let buffer = next else {
                    status.pointee = .noDataNow
                    return nil
                }
                next = nil
                status.pointee = .haveData
                return buffer
            }
        }
        guard error == nil, output.frameLength > 0, let data = output.floatChannelData?[0] else { return nil }
        let samples = Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))

        let expected = Int(((packet.hostTime - origin) * Self.sampleRate).rounded())
        let start: Int
        if let next = nextIndex, abs(expected - next) <= Int(Self.sampleRate / 10) {
            start = next
        } else {
            start = max(expected, nextIndex ?? 0)
        }
        nextIndex = start + samples.count
        return (samples, start)
    }

    private func rebuild(for format: AVAudioFormat) {
        sourceFormat = format
        monoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)
        converter = monoFormat.flatMap { AVAudioConverter(from: $0, to: targetFormat) }
        converter?.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
        arrayEnergy = 0
        arrayFrames = 0
        arrayPeak = 0
    }

    private func liftArray(_ data: UnsafeMutablePointer<Float>, frames: Int) {
        for frame in 0..<frames {
            let value = data[frame]
            arrayEnergy += Double(value) * Double(value)
            arrayPeak = max(arrayPeak, abs(value))
        }
        arrayFrames += frames
        let gain = TrackAudioReader.arrayGain(
            meanSquare: arrayEnergy / Double(max(arrayFrames, 1)), peak: arrayPeak
        )
        guard gain != 1 else { return }
        for frame in 0..<frames { data[frame] *= gain }
    }
}
