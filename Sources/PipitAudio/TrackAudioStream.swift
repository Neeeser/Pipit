import AVFoundation
import Foundation
import PipitCore

/// Reads one recorded track as a continuous signal at a chosen format.
///
/// Segments are recorded at whatever the hardware was doing at the time, so a
/// track can hold 48 kHz and 16 kHz files side by side. The reader resamples as it
/// goes and never materialises the whole meeting: two hours at 16 kHz float32
/// would be well over 400 MB.
///
/// The resampler is kept alive across segments that share a format, so a boundary
/// between two 30-second files costs nothing. It is only drained and rebuilt where
/// the format actually changes.
public final class TrackAudioReader {
    private let segments: [RecordedSegment]
    private let segmentsDirectory: URL
    public let targetFormat: AVAudioFormat

    private var segmentIndex = 0
    private var currentFile: AVAudioFile?
    private var currentSourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var inputBuffer: AVAudioPCMBuffer?
    private var isDrained = false
    /// Linear gain applied to the output of the current segment group, which is
    /// 1 for everything except a track captured from the bare microphone array.
    private var gain: Float = 1
    /// Seconds of output produced so far, which is the position on the track.
    public private(set) var timelinePosition: Double = 0

    public init(segments: [RecordedSegment], segmentsDirectory: URL, targetFormat: AVAudioFormat) {
        self.segments = segments.sorted { $0.index < $1.index }
        self.segmentsDirectory = segmentsDirectory
        self.targetFormat = targetFormat
    }

    public var durationSeconds: Double { segments.reduce(0) { $0 + $1.seconds } }

    /// Skips forward to `offset` seconds by reading and discarding.
    public func seek(to offset: Double) throws {
        guard offset > timelinePosition else { return }
        let frames = AVAudioFrameCount(targetFormat.sampleRate * 0.5)
        while timelinePosition < offset {
            let remaining = offset - timelinePosition
            let request = min(AVAudioFrameCount(remaining * targetFormat.sampleRate) + 1, frames)
            guard let buffer = try read(frames: max(1, request)), buffer.frameLength > 0 else { return }
        }
    }

    /// Reads up to `frames` of output, or nil once the track is exhausted.
    public func read(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        guard frames > 0 else { return nil }
        while true {
            if converter == nil, !openNextSegmentGroup() { return nil }
            guard let converter,
                let output = AVAudioPCMBuffer(
                    pcmFormat: targetFormat, frameCapacity: frames
                )
            else { return nil }

            var conversionError: NSError?
            // The converter calls the input block synchronously on this thread,
            // but the block is typed `@Sendable`. The reader is not `Sendable`,
            // so it reaches the block through the box, which serialises the one
            // call the block makes.
            let source = LockedBox(self)
            let status = converter.convert(to: output, error: &conversionError) { _, statusPointer in
                source.withLock { reader in reader.nextInputBuffer(statusPointer) }
            }

            if let conversionError {
                Log.processing.notice("resampler stopped: \(conversionError.code, privacy: .public)")
                self.converter = nil
                continue
            }
            switch status {
            case .haveData:
                timelinePosition += Double(output.frameLength) / targetFormat.sampleRate
                return lifted(output)
            case .inputRanDry:
                if output.frameLength > 0 {
                    timelinePosition += Double(output.frameLength) / targetFormat.sampleRate
                    return lifted(output)
                }
                continue
            case .endOfStream:
                if output.frameLength > 0 {
                    timelinePosition += Double(output.frameLength) / targetFormat.sampleRate
                    return lifted(output)
                }
                self.converter = nil
                if segmentIndex >= segments.count { return nil }
                continue
            case .error:
                self.converter = nil
                continue
            @unknown default:
                return nil
            }
        }
    }

    /// Applies the current segment group's gain in place.
    ///
    /// Segments are float32 on disk, so a track recorded 38 dB down still holds
    /// every bit of the signal and lifting it here costs nothing. Doing it on
    /// the read path rather than at capture is what keeps `raw/` immutable.
    private func lifted(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard gain != 1, let data = buffer.floatChannelData else { return buffer }
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) { data[channel][frame] *= gain }
        }
        return buffer
    }

    /// Supplies the resampler with the next block of source audio, moving between
    /// segments that share a format without interrupting it.
    private func nextInputBuffer(
        _ statusPointer: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioPCMBuffer? {
        guard let sourceFormat = currentSourceFormat, let buffer = inputBuffer else {
            statusPointer.pointee = .endOfStream
            return nil
        }
        while true {
            guard let file = currentFile else {
                statusPointer.pointee = .endOfStream
                return nil
            }
            if file.framePosition < file.length {
                buffer.frameLength = 0
                do {
                    try file.read(into: buffer)
                } catch {
                    currentFile = nil
                    continue
                }
                if buffer.frameLength > 0 {
                    statusPointer.pointee = .haveData
                    return buffer
                }
                currentFile = nil
                continue
            }
            // Segment exhausted: continue into the next one if the format matches.
            guard let next = openSegment(at: segmentIndex, matching: sourceFormat) else {
                statusPointer.pointee = .endOfStream
                return nil
            }
            currentFile = next
            segmentIndex += 1
        }
    }

    /// Opens the next run of segments that share one source format.
    private func openNextSegmentGroup() -> Bool {
        guard !isDrained else { return false }
        while segmentIndex < segments.count {
            let segment = segments[segmentIndex]
            let url = segmentsDirectory.appendingPathComponent(segment.file)
            guard let file = try? AVAudioFile(forReading: url), file.length > 0 else {
                Log.processing.notice("skipping unreadable segment \(segment.file, privacy: .public)")
                segmentIndex += 1
                continue
            }
            segmentIndex += 1
            let sourceFormat = file.processingFormat
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                continue
            }
            converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            // A file with more than two channels and no surround layout, which is
            // what a raw built-in microphone produces, has no mixdown matrix, and
            // the converter answers with silence. One channel is kept instead,
            // and which one is decided by measuring them.
            //
            // Channel 0 was kept before this, and it does not always carry the
            // voice. On 2026-09-02 and 2026-09-03 channel 0 of a three-channel
            // microphone track read about 30 dB below the other channels,
            // -47.8 dBFS at p99 against the usual -17 to -18 dBFS, and the
            // meeting recorded that way transcribed badly from end to end.
            gain = 1
            if sourceFormat.channelCount > 2 {
                let levels = groupLevels(from: segmentIndex - 1, matching: sourceFormat)
                let chosen = levels.dominant
                converter.channelMap = Array(
                    repeating: NSNumber(value: chosen), count: Int(targetFormat.channelCount)
                )
                // A capsule on its own arrives without the gain macOS applies on
                // the processed path, so the track has to be lifted here or the
                // meeting is archived about 38 dB down and `MicrophoneCleaner`
                // cannot converge on it. Choosing a channel is not enough: the
                // three capsules measured within 2.3 dB of each other, so there
                // is nothing to choose between.
                gain = Self.arrayGain(
                    meanSquare: levels.meanSquare(chosen), peak: levels.peak[chosen]
                )
                Log.processing.info(
                    """
                    mic channel \(chosen, privacy: .public) of \
                    \(sourceFormat.channelCount, privacy: .public) chosen by energy, \
                    lifted \(String(format: "%.1f", 20 * log10(Double(self.gain))), privacy: .public) dB
                    """
                )
            }
            self.converter = converter
            currentSourceFormat = sourceFormat
            currentFile = file
            inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 16_384)
            return inputBuffer != nil
        }
        isDrained = true
        return false
    }

    /// What each channel was doing over the measured audio, and which one won.
    ///
    /// Energy and frames are kept separately so measurements of several
    /// segments can be added together before the mean is taken.
    private struct ChannelLevels {
        var energy: [Double]
        var peak: [Float]
        var frames: Int

        var dominant: Int {
            var chosen = 0
            for channel in energy.indices where energy[channel] > energy[chosen] { chosen = channel }
            return chosen
        }

        func meanSquare(_ channel: Int) -> Double {
            guard frames > 0, energy.indices.contains(channel) else { return 0 }
            return energy[channel] / Double(frames)
        }

        mutating func add(_ other: ChannelLevels) {
            guard energy.count == other.energy.count else { return }
            for channel in energy.indices {
                energy[channel] += other.energy[channel]
                peak[channel] = max(peak[channel], other.peak[channel])
            }
            frames += other.frames
        }
    }

    /// Every segment in the group measured together.
    ///
    /// The gain is applied to the whole group, so it has to be decided from the
    /// whole group. Measuring only the first file is what drove a real meeting
    /// into clipping on 10 September 2026: its opening peaked at -47.8 dB and
    /// allowed the full lift, while a later segment peaked at -29.2 dB and was
    /// pushed to +10.8 dBFS. The speech model looped on the clipped audio and
    /// the meeting failed to transcribe.
    ///
    /// This reads each segment once more than the resampler will. Segments are
    /// float32 and a meeting is minutes of them, so the pass is bounded by the
    /// recording rather than by anything unbounded, and it happens once per
    /// group at processing time.
    private func groupLevels(from start: Int, matching format: AVAudioFormat) -> ChannelLevels {
        let channels = Int(format.channelCount)
        var combined = ChannelLevels(
            energy: [Double](repeating: 0, count: channels),
            peak: [Float](repeating: 0, count: channels), frames: 0
        )
        var index = start
        while index < segments.count {
            let segment = segments[index]
            guard segment.format.sampleRate == format.sampleRate,
                segment.format.channelCount == channels
            else { break }
            let url = segmentsDirectory.appendingPathComponent(segment.file)
            if let file = try? AVAudioFile(forReading: url), file.length > 0 {
                combined.add(channelLevels(of: file))
            }
            index += 1
        }
        return combined
    }

    /// Mean square and peak per channel over one whole file, and the channel
    /// holding the most energy.
    ///
    /// The file is rewound afterwards, so a caller that goes on to read it
    /// starts at the first frame. A file of one channel, or one that cannot be
    /// buffered, measures as silence and answers channel 0, and so does a tie.
    private func channelLevels(of file: AVAudioFile) -> ChannelLevels {
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let empty = ChannelLevels(
            energy: [Double](repeating: 0, count: max(channels, 1)),
            peak: [Float](repeating: 0, count: max(channels, 1)), frames: 0
        )
        guard channels > 1, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384)
        else { return empty }
        defer { file.framePosition = 0 }

        var energy = [Double](repeating: 0, count: channels)
        var peak = [Float](repeating: 0, count: channels)
        var counted = 0
        while file.framePosition < file.length {
            buffer.frameLength = 0
            do {
                try file.read(into: buffer)
            } catch {
                break
            }
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            let frames = Int(buffer.frameLength)
            for channel in 0..<channels {
                var sum: Double = 0
                var high: Float = 0
                for frame in 0..<frames {
                    let value = data[channel][frame]
                    sum += Double(value) * Double(value)
                    high = max(high, abs(value))
                }
                energy[channel] += sum
                peak[channel] = max(peak[channel], high)
            }
            counted += frames
        }
        guard counted > 0 else { return empty }
        return ChannelLevels(energy: energy, peak: peak, frames: counted)
    }

    /// How far to lift one bare capsule so the track is worth keeping.
    ///
    /// Aims the track at `targetLevel` and stops short of `ceiling` so a lifted
    /// peak cannot clip, then refuses to invent more than `limit`. Silence
    /// answers 1: there is nothing to lift and no sensible level to aim at.
    ///
    /// The numbers come from the stored archive. Unaffected captures sit around
    /// -26 dBFS, affected ones around -55 dBFS, so the usual answer here is a
    /// little under 30 dB. The limit is what keeps a genuinely silent meeting
    /// from being amplified into its own noise floor.
    static func arrayGain(
        meanSquare: Double, peak: Float,
        targetLevel: Double = -26, ceiling: Double = -3, limit: Double = 40
    ) -> Float {
        let rms = meanSquare.squareRoot()
        guard rms > 0, peak > 0 else { return 1 }
        let measured = 20 * log10(rms)
        let headroom = ceiling - 20 * log10(Double(peak))
        let decibels = min(targetLevel - measured, headroom, limit)
        guard decibels > 0 else { return 1 }
        return Float(pow(10, decibels / 20))
    }

    private func openSegment(at index: Int, matching format: AVAudioFormat) -> AVAudioFile? {
        guard index < segments.count else { return nil }
        let segment = segments[index]
        guard segment.format.sampleRate == format.sampleRate,
            segment.format.channelCount == Int(format.channelCount)
        else { return nil }
        let url = segmentsDirectory.appendingPathComponent(segment.file)
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        return file
    }
}

/// Push-style access to a track, for callers that just want every buffer in order.
///
/// The read format is held as a plain descriptor rather than an `AVAudioFormat`,
/// which is not `Sendable` on every SDK this builds against.
public struct TrackAudioStream: Sendable {
    public let segments: [RecordedSegment]
    public let segmentsDirectory: URL
    public let format: AudioFormatDescriptor

    public init(segments: [RecordedSegment], segmentsDirectory: URL, targetFormat: AVAudioFormat) {
        self.init(
            segments: segments,
            segmentsDirectory: segmentsDirectory,
            format: AudioFormatDescriptor(
                sampleRate: targetFormat.sampleRate, channelCount: Int(targetFormat.channelCount)
            )
        )
    }

    public init(segments: [RecordedSegment], segmentsDirectory: URL, format: AudioFormatDescriptor) {
        self.segments = segments
        self.segmentsDirectory = segmentsDirectory
        self.format = format
    }

    public var targetFormat: AVAudioFormat? {
        AVAudioFormat(
            standardFormatWithSampleRate: format.sampleRate,
            channels: AVAudioChannelCount(format.channelCount)
        )
    }

    public var durationSeconds: Double { segments.reduce(0) { $0 + $1.seconds } }

    public func makeReader() -> TrackAudioReader? {
        guard let targetFormat else { return nil }
        return TrackAudioReader(
            segments: segments, segmentsDirectory: segmentsDirectory, targetFormat: targetFormat
        )
    }

    /// Walks the track from `startOffset` to `endOffset`. Returning false stops.
    public func forEachBuffer(
        from startOffset: Double = 0,
        to endOffset: Double = .greatestFiniteMagnitude,
        bufferFrames: AVAudioFrameCount = 8_192,
        body: (AVAudioPCMBuffer, Double) throws -> Bool
    ) throws {
        guard let reader = makeReader() else {
            throw ProcessingError.audioUnreadable(path: segmentsDirectory.lastPathComponent)
        }
        try reader.seek(to: startOffset)
        while true {
            let position = reader.timelinePosition
            if position >= endOffset { return }
            guard let buffer = try reader.read(frames: bufferFrames), buffer.frameLength > 0 else { return }
            if try !body(buffer, position) { return }
        }
    }
}

/// Computes an energy profile by streaming a recorded track once.
extension EnergyProfile {
    public static func compute(stream: TrackAudioStream, windowSeconds: Double = 0.1) throws -> EnergyProfile {
        let samplesPerWindow = Int(windowSeconds * stream.format.sampleRate)
        guard samplesPerWindow > 0 else { return EnergyProfile(windowSeconds: windowSeconds, values: []) }

        var values: [Float] = []
        var accumulator: Double = 0
        var count = 0

        try stream.forEachBuffer { buffer, _ in
            guard let channelData = buffer.floatChannelData else { return true }
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            for frame in 0..<frames {
                var sample: Float = 0
                for channel in 0..<channels { sample += channelData[channel][frame] }
                sample /= Float(max(1, channels))
                accumulator += Double(sample * sample)
                count += 1
                if count == samplesPerWindow {
                    values.append(Float((accumulator / Double(count)).squareRoot()))
                    accumulator = 0
                    count = 0
                }
            }
            return true
        }
        if count > 0 {
            values.append(Float((accumulator / Double(count)).squareRoot()))
        }
        return EnergyProfile(windowSeconds: windowSeconds, values: values)
    }
}
