import Foundation

/// Cuts one track's audio into phrases while it is still being recorded.
///
/// The voice detector scores the track one window at a time. A phrase opens at
/// the first window that sounds like speech and closes once the speaker has
/// paused long enough, or once it reaches the longest stretch the speech model
/// takes in a single pass. Each closed phrase is transcribed on its own, so the
/// text for a phrase appears a pause plus one model call after the speaker
/// stops, instead of after the meeting ends.
///
/// Pure arithmetic over window indices: the caller owns the samples and the
/// clock.
public struct LiveSpeechSegmenter: Sendable {
    public struct Tuning: Sendable, Equatable {
        /// A window at or above this probability counts as speech.
        public var speechThreshold: Float
        /// Windows of silence that end a phrase.
        public var pauseWindows: Int
        /// The longest phrase, in windows, before it is cut mid-speech.
        public var maximumWindows: Int
        /// Windows of audio kept before the first speech window and after
        /// the last, so a soft first or last syllable reaches the model.
        public var paddingWindows: Int
        /// Phrases with fewer speech windows than this are dropped as a
        /// cough, a click or a breath.
        public var minimumSpeechWindows: Int

        public init(
            speechThreshold: Float, pauseWindows: Int, maximumWindows: Int,
            paddingWindows: Int, minimumSpeechWindows: Int
        ) {
            self.speechThreshold = speechThreshold
            self.pauseWindows = pauseWindows
            self.maximumWindows = maximumWindows
            self.paddingWindows = paddingWindows
            self.minimumSpeechWindows = minimumSpeechWindows
        }

        /// Silero's 256 ms windows: a pause of about 0.75 s ends a phrase,
        /// and a phrase stops short of Parakeet's 15-second model window.
        public static let `default` = Tuning(
            speechThreshold: 0.5, pauseWindows: 3, maximumWindows: 54,
            paddingWindows: 1, minimumSpeechWindows: 2
        )
    }

    /// Window indices of one phrase, `end` exclusive, padding included.
    public struct Phrase: Sendable, Equatable {
        public var start: Int
        public var end: Int
        /// The window after the last one that held speech, so the speaker
        /// stopped at `lastSpeechEnd` and the phrase was cut later.
        public var lastSpeechEnd: Int

        public init(start: Int, end: Int, lastSpeechEnd: Int) {
            self.start = start
            self.end = end
            self.lastSpeechEnd = lastSpeechEnd
        }
    }

    public let tuning: Tuning
    private var index = 0
    private var openedAt: Int?
    private var lastSpeech = 0
    private var speechWindows = 0
    /// Where the last phrase ended, so the next one's leading padding never
    /// reaches back into audio that was already transcribed.
    private var closedAt = 0

    public init(tuning: Tuning = .default) {
        self.tuning = tuning
    }

    /// Takes the next window's speech probability and returns the phrase
    /// that window closed, if any.
    public mutating func push(_ probability: Float) -> Phrase? {
        defer { index += 1 }
        let isSpeech = probability >= tuning.speechThreshold
        guard let opened = openedAt else {
            guard isSpeech else { return nil }
            openedAt = max(closedAt, index - tuning.paddingWindows)
            lastSpeech = index
            speechWindows = 1
            return nil
        }
        if isSpeech {
            lastSpeech = index
            speechWindows += 1
        }
        if index - lastSpeech >= tuning.pauseWindows {
            return close(from: opened, end: min(index + 1, lastSpeech + 1 + tuning.paddingWindows))
        }
        if index + 1 - opened >= tuning.maximumWindows {
            return close(from: opened, end: index + 1)
        }
        return nil
    }

    /// Closes whatever phrase is open when the track ends.
    public mutating func finish() -> Phrase? {
        guard let opened = openedAt else { return nil }
        return close(from: opened, end: index)
    }

    private mutating func close(from start: Int, end: Int) -> Phrase? {
        let kept = speechWindows
        let spoke = lastSpeech + 1
        openedAt = nil
        speechWindows = 0
        closedAt = end
        guard kept >= tuning.minimumSpeechWindows, end > start else { return nil }
        return Phrase(start: start, end: end, lastSpeechEnd: min(spoke, end))
    }
}
