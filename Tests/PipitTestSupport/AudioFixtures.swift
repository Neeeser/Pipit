import AVFoundation
import Foundation

/// Synthetic audio buffers and sample runs. No hardware and no files.
public enum AudioFixtures {
    /// A deinterleaved tone, which is the shape a process tap delivers. Its
    /// format is always `standardFormatWithSampleRate:channels:`, so every
    /// channel has its own pointer.
    ///
    /// `toneChannel` puts the tone on one channel and leaves the others at
    /// zero, which is what a far end talking on one side of a stereo mixdown
    /// sounds like.
    public static func makeTone(
        seconds: Double, sampleRate: Double, channels: AVAudioChannelCount = 1,
        frequency: Double = 440, amplitude: Float = 0.5, toneChannel: Int? = nil
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData!
        for frame in 0..<Int(frames) {
            let value = amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
            for channel in 0..<Int(channels) {
                data[channel][frame] = toneChannel == nil || toneChannel == channel ? value : 0
            }
        }
        return buffer
    }

    /// A tone in a flat run of samples, which is the shape the echo canceller
    /// takes. `from` leaves everything before it silent.
    public static func makeToneSamples(
        count: Int, sampleRate: Double, frequency: Double, amplitude: Float, from: Int = 0
    ) -> [Float] {
        var samples = [Float](repeating: 0, count: count)
        for index in from..<count {
            let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
            samples[index] = amplitude * Float(sin(phase))
        }
        return samples
    }
}
