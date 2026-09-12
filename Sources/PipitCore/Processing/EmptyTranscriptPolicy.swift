import Foundation

/// How loud a piece of audio is, as the two measures that separate speech from
/// an idle input: the loudest sample and the average level, both in dBFS.
///
/// Digital silence has no logarithm, so both are reported as
/// `EmptyTranscriptPolicy.silenceFloorDBFS` rather than as minus infinity.
public struct AudioLevel: Sendable, Equatable {
    public var peakDBFS: Double
    public var rmsDBFS: Double
    /// Seconds of quarter-second windows whose own level clears
    /// `EmptyTranscriptPolicy.silentPeakDBFS`: how long the audio was
    /// audible, whatever its loudest moment was. Nil where only the peak and
    /// the mean were measured, which is read as audible throughout.
    public var audibleSeconds: Double?
    /// How long the audio runs, so the audible seconds can be read as a share
    /// of it.
    public var seconds: Double?

    public init(
        peakDBFS: Double, rmsDBFS: Double, audibleSeconds: Double? = nil, seconds: Double? = nil
    ) {
        self.peakDBFS = peakDBFS
        self.rmsDBFS = rmsDBFS
        self.audibleSeconds = audibleSeconds
        self.seconds = seconds
    }
}

/// Whether a transcription response that carried neither segments nor text is a
/// finished chunk or a failed one.
///
/// A backend that returns nothing is indistinguishable, from the response
/// alone, from audio that genuinely holds no speech. Filing both as success
/// cost 47% of one meeting's words: a 168-second chunk of ordinary conversation
/// came back as `{"text":""}` with HTTP 200, was billed, was appended as a
/// completed chunk, and the meeting reported `complete`. The audio decides
/// which of the two it was.
public enum EmptyTranscriptPolicy {
    /// Reported for audio with no signal at all, where dBFS is undefined.
    public static let silenceFloorDBFS: Double = -120

    /// Peak level at or below which a chunk holds no speech to lose.
    ///
    /// -50 dBFS is about 0.3% of full scale. A muted microphone, a paused
    /// meeting application and a lossily encoded silent chunk all sit far below
    /// it; the chunk that was silently dropped measured -39 dB *mean*, with
    /// peaks well above that. The gap between the two is more than 10 dB, so
    /// neither ordinary room tone nor quiet speech reads as silence here.
    public static let silentPeakDBFS: Double = -50

    /// Mean level required alongside the peak, so that one stray sample of
    /// interference cannot make an otherwise empty chunk fail forever.
    public static let silentRMSDBFS: Double = -60

    /// Audible seconds under which, together with the share below, an empty
    /// transcript is the audio's own answer whatever its peak.
    ///
    /// The microphone of a user who said two words in an hour, once the far
    /// end has been subtracted from it, is silence with a couple of loud
    /// moments in it: on the call of 11 September 2026 the cleaned track
    /// held 5.5 s above -50 dBFS in 58 minutes and a peak of -20 dBFS, and
    /// the peak alone failed the meeting for good. A chunk that a backend
    /// dropped holds minutes of speech, not seconds, so a bound this size
    /// leaves that case failing and keeps the loss on a wrong call under ten
    /// seconds of words.
    public static let minimumAudibleSeconds: Double = 10
    /// And the audible seconds have to be a sliver of the whole, so a short
    /// chunk that is audible from end to end is still a dropped chunk.
    public static let minimumAudibleShare: Double = 0.02

    public enum Decision: Sendable, Equatable {
        /// Record the chunk as it came back.
        case accept
        /// Fail the chunk so the stage retries and, if it keeps failing, the
        /// meeting is left failed and retryable rather than falsely complete.
        case fail
    }

    /// - Parameters:
    ///   - hasSegments: the response carried at least one segment.
    ///   - hasText: the response carried non-empty text.
    ///   - level: the level of the audio that was sent.
    public static func decide(hasSegments: Bool, hasText: Bool, level: AudioLevel) -> Decision {
        guard !hasSegments, !hasText else { return .accept }
        let silent = level.peakDBFS <= silentPeakDBFS && level.rmsDBFS <= silentRMSDBFS
        let brief: Bool
        if let audible = level.audibleSeconds, let seconds = level.seconds, seconds > 0 {
            brief = audible < minimumAudibleSeconds && audible / seconds < minimumAudibleShare
        } else {
            brief = false
        }
        return silent || brief ? .accept : .fail
    }
}
