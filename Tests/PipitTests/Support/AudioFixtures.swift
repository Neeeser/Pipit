import AVFoundation
import Accelerate
import Foundation

/// Synthetic audio buffers and sample runs. No hardware and no files.
public enum AudioFixtures {
    /// A deinterleaved tone, which is the shape a process tap delivers. Its
    /// format is always `standardFormatWithSampleRate:channels:`, so every
    /// channel has its own pointer.
    ///
    /// `toneChannel` puts the tone on one channel and leaves the others at
    /// zero, which is what call audio talking on one side of a stereo mixdown
    /// sounds like.
    public static func makeTone(
        seconds: Double, sampleRate: Double, channels: AVAudioChannelCount = 1,
        frequency: Double = 440, amplitude: Float = 0.5, toneChannel: Int? = nil
    ) -> AVAudioPCMBuffer {
        // The standard initializer returns nil above two channels, so those get
        // a discrete layout, as a capture format does.
        let format =
            (channels <= 2
            ? AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)
            : AVAudioChannelLayout(
                layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)
            ).map { AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: $0) })!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData!
        // Vectorised, because the test build is unoptimised and a sample-by-
        // sample loop over a minute of audio took seconds per fixture.
        let count = Int(frames)
        var phases = [Double](repeating: 0, count: count)
        var start = 0.0
        var step = 2 * Double.pi * frequency / sampleRate
        vDSP_vrampD(&start, &step, &phases, 1, vDSP_Length(count))
        var values = [Double](repeating: 0, count: count)
        var length = Int32(count)
        vvsin(&values, phases, &length)
        var gain = amplitude
        for channel in 0..<Int(channels) {
            if toneChannel == nil || toneChannel == channel {
                vDSP_vdpsp(values, 1, data[channel], 1, vDSP_Length(count))
                vDSP_vsmul(data[channel], 1, &gain, data[channel], 1, vDSP_Length(count))
            } else {
                vDSP_vclr(data[channel], 1, vDSP_Length(count))
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

    /// Energy summed across the whole band.
    ///
    /// Use this where the microphone holds no copy of the call audio. There is
    /// nothing to subtract, so the difference between input and output is
    /// what the canceller took out of the user.
    public static func energy(_ samples: [Float]) -> Double {
        samples.reduce(0.0) { $0 + Double($1) * Double($1) }
    }

    /// Energy at one frequency, by the Goertzel recurrence.
    ///
    /// One narrow band rather than the whole spectrum. Where the microphone
    /// does hold a copy of the call audio, broadband energy after cancellation is
    /// mostly residue from subtracting it, so it says nothing about whether
    /// the user's own voice came through.
    public static func toneEnergy(
        _ samples: [Float], frequency: Double, sampleRate: Double
    ) -> Double {
        let coefficient = 2 * cos(2 * Double.pi * frequency / sampleRate)
        var previous = 0.0
        var older = 0.0
        for sample in samples {
            let current = Double(sample) + coefficient * previous - older
            older = previous
            previous = current
        }
        return previous * previous + older * older - coefficient * previous * older
    }
}
