import Foundation
import PipitAudio
import PipitCore

/// The call audio over one run of the microphone, read against the microphone's
/// clock.
///
/// The microphone is the clock. The sample asked for at microphone position
/// `p` is the call audio as it stood against the microphone at `p`, which is
/// `p - offset` seconds into the remote track. Nothing outside
/// `remoteSpan` is handed over. A run's call audio is the stretch of the track that
/// run wrote, and the audio before it was recorded in an earlier run and the
/// audio after it in a later one, neither of which was playing here. Without
/// that, a run whose call audio began a few seconds after its microphone would be
/// handed the tail of the run before it for those seconds.
final class RunReferenceReader {
    private var reader: TimelineTrackReader?
    private var silenceRemaining: Int
    private var audioRemaining: Int

    /// - Parameter micStartSeconds: where on the microphone's clock the first
    ///   sample read belongs.
    /// - Parameter offsetSeconds: seconds the call audio moves to line up with the
    ///   microphone, in the sense `EchoCancellationPass.run` takes it.
    /// - Parameter leadSeconds: seconds the call audio is handed over early, on
    ///   top of the offset.
    /// - Parameter remoteSpan: the part of the remote track this run may draw
    ///   on, in the track's own seconds.
    /// - Returns: nil when the track cannot be read.
    init?(
        location: TrackAudioLocation, format: AudioFormatDescriptor, micStartSeconds: Double,
        offsetSeconds: Double, leadSeconds: Double, remoteSpan: ClosedRange<Double>
    ) {
        let rate = format.sampleRate
        // Where in the remote track the first sample asks to be, and where
        // reading actually has to begin.
        let wanted = micStartSeconds - offsetSeconds + leadSeconds
        let begin = max(wanted, remoteSpan.lowerBound)
        silenceRemaining = Int(((begin - wanted) * rate).rounded())
        let available = remoteSpan.upperBound - begin
        audioRemaining =
            available <= 0 ? 0 : (available.isFinite ? Int((available * rate).rounded()) : .max)
        if audioRemaining > 0 {
            guard
                let opened = TimelineTrackReader(
                    location: location, format: format, offsetSeconds: -begin
                )
            else { return nil }
            reader = opened
        }
    }

    /// The next `count` samples, padded with silence where the call audio has run
    /// out.
    func next(count: Int) throws -> [Float] {
        var out = try nextUnpadded(count: count)
        if out.count < count {
            out.append(contentsOf: repeatElement(0, count: count - out.count))
        }
        return out
    }

    /// The next `count` samples, or fewer once the call audio has run out. The
    /// silence before it begins is still handed back, as it is the part of the
    /// run the call audio had not reached yet.
    func nextUnpadded(count: Int) throws -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(count)
        let silence = min(silenceRemaining, count)
        out.append(contentsOf: repeatElement(0, count: silence))
        silenceRemaining -= silence
        let audio = min(audioRemaining, count - out.count)
        if audio > 0, let reader {
            let block = try reader.next(count: audio)
            out += block
            // A track that ends before its span does has nothing more to give.
            audioRemaining = block.count < audio ? 0 : audioRemaining - block.count
        }
        return out
    }
}

/// The call audio read against the microphone's clock, one run at a time.
///
/// A call that dropped and was rejoined is several runs under one manifest, and
/// the call audio does not sit the same distance from the microphone in all of
/// them. Each stretch of the microphone has a placement of its own, and this
/// hands back the call audio for whichever one the position is in.
///
/// Each run is read by a `RunReferenceReader` of its own, opened when the
/// position reaches it and dropped when it leaves. A reader only moves forward,
/// and the next run's placement can ask for an earlier part of the call audio than
/// the last one reached, so it starts again and skips to where it is needed.
final class PlacedReferenceReader {
    private let location: TrackAudioLocation
    private let format: AudioFormatDescriptor
    private let placements: [EchoCancellationPass.Placement]
    private let leadSeconds: Double
    /// The microphone frame each placement begins at.
    private let starts: [Int]
    private var position = 0
    private var current = 0
    private var reader: RunReferenceReader?

    /// - Parameter leadSeconds: seconds the call audio is handed over early, on
    ///   top of wherever each placement put it.
    init(
        location: TrackAudioLocation, format: AudioFormatDescriptor,
        placements: [EchoCancellationPass.Placement], leadSeconds: Double
    ) throws {
        self.location = location
        self.format = format
        self.placements = placements.isEmpty ? [.init(startSeconds: 0, offsetSeconds: 0)] : placements
        self.leadSeconds = leadSeconds
        var starts = self.placements.map { Int(($0.startSeconds * format.sampleRate).rounded()) }
        // The first placement governs from the microphone's first frame.
        starts[0] = 0
        self.starts = starts
        reader = try open(0)
    }

    /// The next `count` samples of the call audio, padded with silence where it
    /// has run out or where a run recorded none.
    func next(count: Int) throws -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(count)
        while out.count < count {
            var index = current
            while index + 1 < starts.count, starts[index + 1] <= position { index += 1 }
            if index != current {
                current = index
                reader = try open(index)
            }
            let end = index + 1 < starts.count ? starts[index + 1] : Int.max
            let take = min(count - out.count, end - position)
            if let reader {
                out += try reader.next(count: take)
            } else {
                out.append(contentsOf: repeatElement(0, count: take))
            }
            position += take
        }
        return out
    }

    /// The reader for one run, or nil where the call audio recorded nothing and
    /// the run is silence.
    private func open(_ index: Int) throws -> RunReferenceReader? {
        let placement = placements[index]
        guard let offset = placement.offsetSeconds else { return nil }
        guard
            let opened = RunReferenceReader(
                location: location, format: format,
                micStartSeconds: index == 0 ? 0 : placement.startSeconds,
                offsetSeconds: offset, leadSeconds: leadSeconds, remoteSpan: placement.remoteSpan
            )
        else {
            throw ProcessingError.audioUnreadable(path: location.directory.lastPathComponent)
        }
        return opened
    }
}
