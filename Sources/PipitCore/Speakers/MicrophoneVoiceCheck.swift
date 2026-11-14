import Foundation

/// Decides whether a microphone line is the local user's voice, from what it
/// sounds like.
///
/// The microphone track is filed under the local user by construction, and on
/// speakers it also carries the far end. The echo canceller removes the far end
/// only where the far-end track holds a copy of it, so a stretch where that
/// track recorded nothing leaves the far end at full level on the user's line.
/// On a Safari call of 12 November 2026 the far-end tap delivered digital
/// silence twice for 15 to 20 seconds, and both times the person talking was
/// written under the user's name.
///
/// The rule judges the line's voice instead of the audio around it, because the
/// audio around it does not separate the cases: on a recording of 10 September
/// 2026 the far-end tap was silent too and every line in those stretches was
/// the user. Measured on those two meetings, the user's own lines of three
/// seconds or more scored 0.63 to 0.95 against their profile and at most 0.43
/// against any far-end voice of the meeting. The leaked lines scored 0.12 to
/// 0.45 against the profile and 0.68 to 0.73 against the far-end voice that had
/// spoken them.
///
/// A line is never removed. It moves to the far-end voice it matches, or, when
/// it is clearly not the user and matches nobody, to an unattributed speaker.
///
/// Two cases leave the user's lines alone because the score cannot be trusted.
/// Across 158 recorded calls, every line averaging under -70 dB scored as not the
/// user, since the vector then describes near-silence, while every line that
/// moved to a far-end voice was at -55 dB or louder. And in two meetings almost
/// every line failed the profile, which says the profile does not fit that
/// recording rather than that the far end spoke all of it; elsewhere the
/// failing lines were at most half of a meeting and usually a few percent.
public enum MicrophoneVoiceCheck {
    /// Shorter lines are left alone: an embedding of under three seconds of
    /// speech is not reliable enough to take a line away from the user.
    public static let minimumSeconds = 3.0
    /// At or above this against the user's profile, the line is the user's.
    public static let ownVoiceScore = 0.55
    /// A far-end voice has to score at least this to take the line.
    public static let farEndScore = 0.6
    /// And beat the user's own score by this much.
    public static let farEndMargin = 0.15
    /// Below this against the user's profile, the line is not the user even
    /// when no far-end voice claims it.
    public static let notOwnVoiceScore = 0.3
    /// A line quieter than this on average is too quiet to judge.
    public static let minimumLevelDB = -60.0

    /// One microphone line's measurements.
    public struct Line: Sendable, Equatable {
        public var id: String
        /// Mean power of the line's microphone audio, in dB below full scale.
        public var levelDB: Double
        public var ownScore: Double
        public var farEnd: [String: Double]

        public init(id: String, levelDB: Double, ownScore: Double, farEnd: [String: Double]) {
            self.id = id
            self.levelDB = levelDB
            self.ownScore = ownScore
            self.farEnd = farEnd
        }
    }

    public enum Decision: Sendable, Equatable {
        case keep
        case farEnd(speakerKey: String)
        case unattributed
    }

    /// - Parameters:
    ///   - ownScore: cosine similarity of the line's voice to the user's profile.
    ///   - farEnd: the same against each far-end voice of this meeting, keyed by
    ///     the speaker key its lines carry.
    public static func decide(ownScore: Double, farEnd: [String: Double]) -> Decision {
        guard ownScore < ownVoiceScore else { return .keep }
        let best = farEnd.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }
        if let best, best.value >= farEndScore, best.value - ownScore >= farEndMargin {
            return .farEnd(speakerKey: best.key)
        }
        return ownScore < notOwnVoiceScore ? .unattributed : .keep
    }

    /// The decisions for every judged line of one meeting.
    ///
    /// Lines under `minimumLevelDB` stay with the user. When more than half of
    /// the rest score below `notOwnVoiceScore`, the profile does not fit this
    /// recording, so no line becomes unattributed; a line that clearly matches
    /// a far-end voice still moves, because that match is evidence of its own.
    public static func decide(_ lines: [Line]) -> [String: Decision] {
        let judged = lines.filter { $0.levelDB >= minimumLevelDB }
        let failing = judged.filter { $0.ownScore < notOwnVoiceScore }.count
        let profileFits = failing * 2 <= judged.count
        var decisions: [String: Decision] = [:]
        for line in judged {
            let decision = decide(ownScore: line.ownScore, farEnd: line.farEnd)
            decisions[line.id] = decision == .unattributed && !profileFits ? .keep : decision
        }
        return decisions
    }

    /// Mean power of a stretch of samples in dB below full scale.
    public static func levelDB(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return -.infinity }
        let power = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        return 10 * log10(max(power, 1e-12))
    }

    /// The transcript with each decided line moved to its new speaker.
    ///
    /// Only lines still filed under the local user are touched, so a line a
    /// person already moved somewhere else keeps where they put it.
    public static func apply(
        _ decisions: [String: Decision], to transcript: CanonicalTranscript
    ) -> CanonicalTranscript {
        var updated = transcript
        for index in updated.utterances.indices {
            let utterance = updated.utterances[index]
            guard utterance.speakerKey == SpeakerLabel.localUser,
                let decision = decisions[utterance.id]
            else { continue }
            switch decision {
            case .keep:
                continue
            case .farEnd(let speakerKey):
                updated.utterances[index].speakerKey = speakerKey
            case .unattributed:
                updated.utterances[index].speakerKey = SpeakerLabel.unattributed(track: .mic)
            }
        }
        return updated
    }
}
