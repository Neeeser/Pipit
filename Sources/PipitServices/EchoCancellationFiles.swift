import AVFoundation
import Foundation
import PipitAudio
import PipitCore

extension EchoCancellationPass {
    /// What one file-based run of the pass produced, for a caller that scores
    /// the cleaned audio somewhere else.
    public struct FileRun: Sendable, Equatable {
        /// Frames of cleaned microphone written to the output file.
        public let frames: Int64
        /// The measurement grid the pass keeps, one entry per quarter second.
        public let windows: [Window]
        /// Where the far end was measured to sit against the microphone.
        public let alignment: Alignment
        /// The offset the run actually used.
        public let referenceOffset: Double
    }

    /// Runs the shipped pass over two audio files and writes the cleaned
    /// microphone as 16 kHz mono Float32 WAV.
    ///
    /// This is the canceller exactly as `MicrophoneCleaner` runs it, minus the
    /// meeting folder: the same alignment measurement, the same block loop and
    /// the same window grid. `pipit-eval aec` calls it so a recording from a
    /// public corpus can be scored against the pass that ships, and so a port
    /// of the canceller can be checked against a reference output.
    ///
    /// - Parameter referenceOffset: seconds the far end has to move to line up
    ///   with the microphone, as `run` takes it. Nil measures the alignment
    ///   from the envelopes and uses it when it clears the usual bars, else 0.
    /// - Parameter canceller: the canceller to run. The shipped one by
    ///   default; a harness comparing one stage against its reference passes
    ///   that stage alone.
    public static func clean(
        microphoneFile: URL, referenceFile: URL, referenceOffset: Double?, to output: URL,
        canceller: @escaping () throws -> any EchoCancelling = {
            try EchoModels.shippedCanceller(sampleRate: 16_000)
        }
    ) throws -> FileRun {
        let microphone = try location(of: microphoneFile, track: .mic)
        let reference = try location(of: referenceFile, track: .remote)
        let alignment = try measureAlignment(
            microphone: microphone, reference: reference, timelineOffset: 0
        )
        let offset = referenceOffset ?? (alignment.isUsable ? alignment.offsetSeconds : 0)

        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: readFormat.sampleRate, channels: 1,
                interleaved: false
            )
        else {
            throw ProcessingError.audioUnreadable(path: output.lastPathComponent)
        }
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: output)
        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: output,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: readFormat.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                ],
                commonFormat: .pcmFormatFloat32, interleaved: false
            )
        } catch {
            throw ProcessingError.audioUnreadable(path: output.lastPathComponent)
        }

        let result = try run(
            microphone: microphone, reference: reference, referenceOffset: offset,
            canceller: canceller
        ) { samples in
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)
                ), let channel = buffer.floatChannelData?[0]
            else {
                throw ProcessingError.audioUnreadable(path: output.lastPathComponent)
            }
            for (index, sample) in samples.enumerated() { channel[index] = sample }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            try file.write(from: buffer)
        }
        return FileRun(
            frames: result.frames, windows: result.windows, alignment: alignment,
            referenceOffset: offset
        )
    }

    /// One audio file standing in as a whole track, read from its first frame.
    static func location(of file: URL, track: CaptureTrack) throws -> TrackAudioLocation {
        let audio: AVAudioFile
        do {
            audio = try AVAudioFile(forReading: file)
        } catch {
            throw ProcessingError.audioUnreadable(path: file.lastPathComponent)
        }
        let rate = audio.fileFormat.sampleRate
        let record = AudioArchive.Track(
            file: file.lastPathComponent, sampleRate: rate,
            channelCount: Int(audio.fileFormat.channelCount), frameCount: audio.length,
            seconds: Double(audio.length) / rate, firstFrameHostTime: nil
        )
        return TrackAudioLocation.archived(
            track: track, record: record, directory: file.deletingLastPathComponent(),
            compactedAt: Date()
        )
    }
}
