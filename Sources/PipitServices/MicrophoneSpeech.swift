import Foundation
import PipitAudio
import PipitCore

/// Where the voice activity detector heard speech on the microphone as it was
/// recorded, before any echo was taken out of it.
///
/// `EchoCancellationPass.judge` uses it to decide which windows count as the
/// user's own. It has to be measured on the raw microphone: on the cleaned one
/// the canceller has already removed the speech the judge needs to find.
public struct MicrophoneSpeech: Sendable, Equatable {
    /// Detector probability at or above which a stretch holds speech. The
    /// threshold the audit replayed the decision with over 46 calls on
    /// speakers.
    public static let speechProbability: Float = 0.5

    /// Seconds one probability covers, from the microphone's first frame.
    public let windowSeconds: Double
    public let probabilities: [Float]

    public init(windowSeconds: Double, probabilities: [Float]) {
        self.windowSeconds = windowSeconds
        self.probabilities = probabilities
    }

    /// Whether the detector marked speech at an instant, in seconds from the
    /// microphone's first frame. An instant past the end of the series holds
    /// none, because nothing was measured there.
    public func holdsSpeech(at seconds: Double) -> Bool {
        guard windowSeconds > 0, seconds >= 0, seconds.isFinite else { return false }
        let index = Int(seconds / windowSeconds)
        guard index < probabilities.count else { return false }
        return probabilities[index] >= Self.speechProbability
    }

    /// Runs the detector over the raw microphone.
    ///
    /// Nil where there is nothing to say: no detector (not installed, or a
    /// test), no audio, a detector that wants another sample rate, or one that
    /// failed. The judge then falls back to the level rule alone. A cancelled
    /// pass throws instead, because a decision made on the fallback would be
    /// recorded and never revisited.
    public static func measure(
        microphone: TrackAudioLocation, detector: (any VoiceActivityBackend)?
    ) async throws -> MicrophoneSpeech? {
        let format = SpeechEvidenceBuilder.readFormat
        guard let detector, !microphone.isEmpty, detector.sampleRate == format.sampleRate else {
            return nil
        }
        let stream = TrackAudioStream(
            segments: microphone.segments, segmentsDirectory: microphone.directory, format: format
        )
        do {
            let profile = try await SpeechEvidenceBuilder.detect(stream: stream, detector: detector)
            return MicrophoneSpeech(windowSeconds: profile.windowSeconds, probabilities: profile.values)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.processing.notice(
                "echo judgement without voice detection: \(logSafeDescription(error), privacy: .public)"
            )
            return nil
        }
    }
}
