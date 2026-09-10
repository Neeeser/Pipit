import AVFoundation
import Foundation
import PipitAudio
import PipitCore
import Testing

/// Reading a microphone track that was captured from the bare built-in array.
///
/// The condition, measured on this Mac on 10 September 2026: `BuiltInMicrophoneDevice`
/// presents one channel normally and three the moment a call application opens it
/// with voice processing, which Firefox does on every call and the Slack
/// application never does. Those three are the raw capsules, ahead of the gain
/// and beamforming macOS applies on the processed path. A capture taken from
/// them lands about 38 dB below a healthy one: the local speaker measured
/// -55.7 dB against -17.9 dB through the processed path in the same room, and
/// across 36 stored meetings the affected ones average -52.5 dB against -22.9 dB.
///
/// The archive is unusable at that level and, worse, `MicrophoneCleaner` cannot
/// converge on it: the affected meetings removed 0.4 to 4.1 dB of echo where the
/// unaffected ones removed 9 to 13 dB.
@Suite("Raw microphone array")
struct RawMicrophoneArrayTests {
    private static let rate = 48_000.0

    /// dBFS of a block of samples.
    private static func level(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -.infinity }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        let rms = (sum / Double(samples.count)).squareRoot()
        return rms <= 0 ? -.infinity : 20 * log10(rms)
    }

    private static func peak(_ samples: [Float]) -> Double {
        let top = samples.reduce(0.0 as Float) { Swift.max($0, abs($1)) }
        return top <= 0 ? -.infinity : 20 * log10(Double(top))
    }

    /// Writes one segment carrying `channels` copies of a tone at `dbfs`.
    ///
    /// Every capsule carries the same signal because that is what the array
    /// delivers for a source in front of the machine: measured inter-capsule
    /// correlation for a real source was 0.77 to 0.83 at lags of 2 to 3 samples.
    private static func writeSegment(
        into directory: URL, name: String, channels: AVAudioChannelCount,
        dbfs: Double, seconds: Double = 4, index: Int = 0,
        burst: (at: Double, seconds: Double, amplitude: Float)? = nil
    ) throws -> RecordedSegment {
        // Mono and stereo have standard layouts. Three channels do not, which
        // is exactly why the reader has to choose one rather than let the
        // converter mix. Discrete-in-order is what a bare capsule array is.
        let format: AVAudioFormat
        if channels <= 2 {
            format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        } else {
            let layout = AVAudioChannelLayout(
                layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
            )!
            format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate,
                interleaved: false, channelLayout: layout
            )
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let url = directory.appendingPathComponent(name)
        let file = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
        let frames = Int(seconds * rate)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)
        )!
        buffer.frameLength = AVAudioFrameCount(frames)
        // A sine's RMS is its amplitude over root two.
        let amplitude = dbfs.isFinite ? Float(pow(10, dbfs / 20) * 2.0.squareRoot()) : 0
        let burstRange: Range<Int>? = burst.map {
            Int($0.at * rate)..<Int(($0.at + $0.seconds) * rate)
        }
        let data = buffer.floatChannelData!
        for frame in 0..<frames {
            let level = burstRange?.contains(frame) == true ? burst!.amplitude : amplitude
            let value = level * Float(sin(2 * Double.pi * 300 * Double(frame) / rate))
            for channel in 0..<Int(channels) { data[channel][frame] = value }
        }
        try file.write(from: buffer)

        return RecordedSegment(
            track: .mic, index: index, file: name,
            format: AudioFormatDescriptor(sampleRate: rate, channelCount: Int(channels)),
            startFrame: 0, firstFrameHostTime: 0,
            openedAt: Date(timeIntervalSince1970: 1_787_070_000), openReason: "test"
        )
    }

    /// Reads a whole track the way the pipeline does, at 16 kHz mono.
    private static func readAll(
        segments: [RecordedSegment], directory: URL
    ) throws -> [Float] {
        let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let reader = TrackAudioReader(
            segments: segments, segmentsDirectory: directory, targetFormat: target
        )
        var out: [Float] = []
        while let buffer = try reader.read(frames: 4_096), buffer.frameLength > 0 {
            let data = buffer.floatChannelData![0]
            out.append(contentsOf: (0..<Int(buffer.frameLength)).map { data[$0] })
        }
        return out
    }

    @Test("a track captured from the raw array reads back at a usable level")
    func aTrackCapturedFromTheRawArrayReadsBackAtAUsableLevel() throws {
        let directory = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let segment = try Self.writeSegment(
            into: directory, name: "mic-000.caf", channels: 3, dbfs: -55
        )
        let samples = try Self.readAll(segments: [segment], directory: directory)

        #expect(!samples.isEmpty, "the reader produced audio")
        let read = Self.level(samples)
        #expect(
            read > -30,
            "a -55 dB raw-array capture must read back above -30 dB, got \(read) dB"
        )
    }

    @Test("a two-channel track is left at its own level")
    func aTwoChannelTrackIsLeftAtItsOwnLevel() throws {
        let directory = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Two channels is the boundary. A stereo capture is a device the user
        // chose, and a quiet one is theirs to keep: only the bare array, which
        // nothing chose, gets lifted.
        let segment = try Self.writeSegment(
            into: directory, name: "mic-000.caf", channels: 2, dbfs: -45
        )
        let samples = try Self.readAll(segments: [segment], directory: directory)

        let read = Self.level(samples)
        #expect(
            abs(read - (-45)) < 1,
            "a two-channel capture must keep its own level, expected -45 dB, got \(read) dB"
        )
    }

    @Test("lifting a raw-array track leaves the loudest moment below full scale")
    func liftingARawArrayTrackLeavesTheLoudestMomentBelowFullScale() throws {
        let directory = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Quiet nearly all the way through with one short loud moment, which is
        // what a meeting with a door slam in it looks like. Aiming at the
        // average alone would drive that moment well past full scale.
        let segment = try Self.writeSegment(
            into: directory, name: "mic-000.caf", channels: 3, dbfs: -55, seconds: 20,
            burst: (at: 4.0, seconds: 0.005, amplitude: 0.5)
        )
        let samples = try Self.readAll(segments: [segment], directory: directory)

        let top = Self.peak(samples)
        #expect(
            top < 0,
            "the lifted track must stay below full scale, peaked at \(top) dBFS"
        )
    }

    @Test("a later segment louder than the first is not driven into clipping")
    func aLaterSegmentLouderThanTheFirstIsNotDrivenIntoClipping() throws {
        let directory = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // The shape that broke a real meeting on 10 September 2026. The gain was
        // measured from the opening of the first segment, where the peak sat at
        // -47.8 dB, and applied to the whole group. A later segment peaked at
        // -29.2 dB, which the same gain drove to +10.8 dBFS. Clipped audio is
        // what made the speech model loop and fail the meeting.
        var segments: [RecordedSegment] = []
        segments.append(
            try Self.writeSegment(
                into: directory, name: "mic-000.caf", channels: 3, dbfs: -55, index: 0
            ))
        segments.append(
            try Self.writeSegment(
                into: directory, name: "mic-001.caf", channels: 3, dbfs: -55, index: 1,
                burst: (at: 1.0, seconds: 0.5, amplitude: 0.5)
            ))
        let samples = try Self.readAll(segments: segments, directory: directory)

        let top = Self.peak(samples)
        #expect(
            top < 0,
            "a louder later segment must not clip, peaked at \(top) dBFS"
        )
    }

    @Test("the lift is capped so a nearly silent track stays quiet")
    func theLiftIsCappedSoANearlySilentTrackStaysQuiet() throws {
        let directory = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // An empty room, 64 dB below where a lift would aim. Without a cap this
        // is dragged up to speaking level and the meeting is archived as a
        // recording of its own noise floor.
        let segment = try Self.writeSegment(
            into: directory, name: "mic-000.caf", channels: 3, dbfs: -90
        )
        let samples = try Self.readAll(segments: [segment], directory: directory)

        let read = Self.level(samples)
        #expect(
            read < -45,
            "a nearly silent track must not be lifted to speaking level, got \(read) dB"
        )
    }
}
