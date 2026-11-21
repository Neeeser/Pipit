import Foundation

/// One steady bar for the speaker separation update, from the click until the
/// model is usable.
///
/// The download reports its own fraction and fills the first part of the bar.
/// The Core ML compile that follows reports nothing, so its part fills on an
/// estimate of its length instead of an indeterminate bar, which reads as stuck
/// over several minutes. First loads measured on Apple silicon took 158 s to
/// 590 s, the longest under load. The curve slows as it goes and stops short of
/// full; the bar is full only when the compile reports done.
public enum SpeakerSeparationProgress {
    /// The download's share of the bar: it takes seconds, the compile minutes.
    public static let downloadShare = 0.2
    /// Seconds after which the compile part has covered about 63% of its span.
    public static let compileTimeConstant: TimeInterval = 120
    /// The highest the bar goes before the compile reports done.
    public static let ceiling = 0.97

    public static func downloading(_ fraction: Double) -> Double {
        downloadShare * min(max(fraction, 0), 1)
    }

    public static func compiling(elapsed: TimeInterval) -> Double {
        let span = ceiling - downloadShare
        return downloadShare + span * (1 - exp(-max(elapsed, 0) / compileTimeConstant))
    }
}
