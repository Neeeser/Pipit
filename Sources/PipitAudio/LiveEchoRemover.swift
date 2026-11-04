import Foundation

/// Removes the far end from the microphone while the meeting records, so the
/// live transcript does not hear everyone twice on a call taken on speakers.
///
/// Both tracks arrive as 16 kHz samples placed on one timeline by host time.
/// The microphone is cleaned a block at a time once the far end's audio for
/// that block has arrived, or once the microphone is `maximumWaitSeconds`
/// ahead of it, when the missing far end is treated as silence: a tap that
/// stalls must not stop the microphone's live text.
///
/// The after-call pass measures the offset between the tracks before it
/// cleans; here the host times are the alignment, and the canceller's adaptive
/// filter absorbs the acoustic delay from speaker to microphone.
///
/// Not thread-safe: driven from one queue.
public final class LiveEchoRemover {
    public static let maximumWaitSeconds = 0.5
    /// A gap longer than this, from a paused recording, starts each stream
    /// again at the new position instead of cleaning minutes of silence.
    public static let restartGapSeconds = 2.0
    private static var restartGap: Int { Int(restartGapSeconds * LiveTrackResampler.sampleRate) }

    private let canceller: any EchoCancelling
    private let block: Int
    /// Microphone samples not cleaned yet, starting at `micStart`.
    private var mic: [Float] = []
    private var micStart = 0
    /// Far-end samples from `referenceStart`, kept until the microphone has
    /// been cleaned past them.
    private var reference: [Float] = []
    private var referenceStart = 0

    public init(canceller: any EchoCancelling) {
        self.canceller = canceller
        block = canceller.blockFrames
    }

    /// The shipped canceller at the live sample rate.
    public convenience init() throws {
        self.init(canceller: try EchoModels.shippedCanceller(sampleRate: Int(LiveTrackResampler.sampleRate)))
    }

    /// Adds far-end samples starting at timeline index `start`.
    public func addReference(_ samples: [Float], start: Int) {
        if reference.isEmpty || start - (referenceStart + reference.count) > Self.restartGap {
            reference = []
            referenceStart = start
        }
        let end = referenceStart + reference.count
        if start > end {
            reference += [Float](repeating: 0, count: start - end)
        } else if start < end {
            // Overlap after a resync: keep what is already there.
            let skip = end - start
            guard skip < samples.count else { return }
            reference += samples[skip...]
            return
        }
        reference += samples
    }

    /// Adds microphone samples starting at timeline index `start`, and returns
    /// whatever could be cleaned so far, with the index of its first sample.
    public func addMicrophone(_ samples: [Float], start: Int) -> (samples: [Float], start: Int)? {
        if mic.isEmpty || start - (micStart + mic.count) > Self.restartGap {
            // Less than a block is left over from before a pause, and the
            // live text loses nothing that matters by dropping it.
            mic = []
            micStart = start
        }
        let end = micStart + mic.count
        if start > end { mic += [Float](repeating: 0, count: start - end) }
        if start >= end {
            mic += samples
        } else if end - start < samples.count {
            mic += samples[(end - start)...]
        }
        return drain(force: false)
    }

    /// Cleans everything held, padding the far end with silence, for the end
    /// of the recording.
    public func flush() -> (samples: [Float], start: Int)? {
        drain(force: true)
    }

    private func drain(force: Bool) -> (samples: [Float], start: Int)? {
        let start = micStart
        var out: [Float] = []
        let wait = Int(Self.maximumWaitSeconds * LiveTrackResampler.sampleRate)
        while mic.count >= block || (force && !mic.isEmpty) {
            let blockEnd = micStart + block
            let referenceEnd = referenceStart + reference.count
            guard force || referenceEnd >= blockEnd || micStart + mic.count - blockEnd >= wait else { break }
            var chunk = Array(mic.prefix(block))
            let real = chunk.count
            if real < block { chunk += [Float](repeating: 0, count: block - real) }
            var played = [Float](repeating: 0, count: block)
            let from = micStart - referenceStart
            for offset in 0..<block {
                let index = from + offset
                if index >= 0, index < reference.count { played[offset] = reference[index] }
            }
            if !canceller.process(microphone: &chunk, reference: played) {
                // A refused block passes through rather than leaving a hole.
                chunk = Array(mic.prefix(block)) + [Float](repeating: 0, count: block - real)
            }
            out += chunk.prefix(real)
            mic.removeFirst(real)
            micStart += real
        }
        // The far end before the microphone's position is no longer needed.
        let keepFrom = micStart - referenceStart
        if keepFrom > 0 {
            let drop = min(keepFrom, reference.count)
            reference.removeFirst(drop)
            referenceStart += drop
        }
        return out.isEmpty ? nil : (out, start)
    }
}
