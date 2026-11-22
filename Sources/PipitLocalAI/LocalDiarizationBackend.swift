import Foundation
import PipitCore

/// The diarizer Pipit ships for a finished meeting's remote speakers: Nemotron
/// 3 Diarization, with the offline clusterer behind it for the meetings
/// Nemotron cannot do.
///
/// On the held-out `deciding` suite, leaving out the ICSI cases Nemotron trained
/// on, Nemotron cut mean tcpWER from 53.6% to 38.2% and found the right speaker
/// count on 10 of 10 cases against 2 of 10, at word error unchanged and similar
/// speed. The clusterer still runs in three places, and the run's provenance
/// says which one it was:
///
/// - The model's eight speaker slots all filled, so the meeting may hold more
///   people than it can keep apart.
/// - Its files are not installed, or the model failed on this audio, which
///   includes returning no speakers for audio loud enough to hold speech.
/// - A person asked for a speaker count, which Nemotron cannot be told. That
///   path never reaches this type; `LocalModelManager.reanalyzeSpeakers` sends
///   it straight to the clusterer.
///
/// Live diarization during a call stays on the clusterer: it reruns on growing
/// scratch files and has not been measured with Nemotron.
public struct LocalDiarizationBackend: DiarizationBackend {
    /// Why the offline clusterer ran in place of Nemotron. Recorded as the
    /// run's `diarizerReason`.
    public enum Reason: String, Sendable {
        case speakerCountRequested
        case allSpeakerSlotsUsed
        case modelNotInstalled
        case modelFailed
        /// Nemotron ran and the meeting was within its limits.
        case preferred
    }

    private let primary: any DiarizationBackend
    private let fallback: any DiarizationBackend
    private let slotLimit: Int

    public init(
        primary: any DiarizationBackend, fallback: any DiarizationBackend,
        slotLimit: Int = LocalSpeechStack.nemotron3SpeakerSlots
    ) {
        self.primary = primary
        self.fallback = fallback
        self.slotLimit = slotLimit
    }

    /// `cacheKey` keeps the clusterer's segmentation and embeddings when it
    /// runs, so a later re-analysis at a typed speaker count re-clusters
    /// instead of starting again.
    public init(models: LocalModelManager, cacheKey: String? = nil) {
        self.init(
            primary: Nemotron3DiarizationBackend(models: models, preset: .offline),
            fallback: FluidAudioDiarizationBackend(models: models, cacheKey: cacheKey)
        )
    }

    public var identifier: String { primary.identifier }
    public var isLocal: Bool { true }
    public var limits: BackendAudioLimits { .none }
    /// False because the common answer carries no vectors. When the clusterer
    /// ran, its vectors come back in the output and the pipeline keeps them;
    /// otherwise voice memory embeds the intervals afterwards.
    public var producesEmbeddings: Bool { false }
    public var producesTranscript: Bool { false }

    public func diarize(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DiarizationOutput {
        // Nemotron's progress fills the first half and the clusterer's the
        // second, so a fallback continues the bar instead of restarting it. A
        // finished Nemotron run reports the rest itself.
        let reason: Reason
        do {
            let output = try await primary.diarize(
                audio: audio, progress: { progress(min(max($0, 0), 1) * 0.5) }
            )
            if Self.foundNoSpeakerInLoudAudio(output) {
                reason = .modelFailed
                Log.processing.notice("nemotron diarization found no speaker in audible audio, using the clusterer")
            } else if output.clusters.count >= slotLimit {
                reason = .allSpeakerSlotsUsed
            } else {
                progress(1)
                return Self.recording(.preferred, in: output)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch LocalModelError.notInstalled {
            reason = .modelNotInstalled
        } catch {
            if Task.isCancelled { throw error }
            // The clusterer reads the same file the same way, so an audio
            // decode failure would only fail twice.
            if Self.isDecodeFailure(error) { throw error }
            // The error's category, never its text: some carry file paths.
            Log.processing.notice(
                "nemotron diarization failed, using the clusterer error=\(String(describing: type(of: error)), privacy: .public)"
            )
            reason = .modelFailed
        }
        let output = try await fallback.diarize(
            audio: audio, progress: { progress(0.5 + min(max($0, 0), 1) * 0.5) }
        )
        return Self.recording(reason, in: output)
    }

    /// An empty answer is correct for a file with no speech, and Nemotron marks
    /// those itself (`silentAudio`). Anything else that comes back empty is a
    /// file with a signal the model failed to place a speaker in, and the
    /// meeting would otherwise end with nobody in it.
    private static func foundNoSpeakerInLoudAudio(_ output: DiarizationOutput) -> Bool {
        output.intervals.isEmpty && output.configuration["silentAudio"] != "true"
    }

    private static func isDecodeFailure(_ error: any Error) -> Bool {
        if case ProcessingError.audioUnreadable = error { return true }
        if case LocalModelError.audioUnreadable = error { return true }
        return false
    }

    private static func recording(_ reason: Reason, in output: DiarizationOutput) -> DiarizationOutput {
        var output = output
        output.configuration["diarizerReason"] = reason.rawValue
        return output
    }
}

extension LocalModelManager {
    /// Re-analysis entry point for the speaker control.
    ///
    /// A typed count goes to the offline clusterer, which can be told one and
    /// whose cache lets a second count re-cluster in about a second. Without a
    /// count the meeting gets what a first pass gets, Nemotron with its
    /// fallbacks, and the clusterer's work is cached under the meeting for
    /// the next typed count.
    public func reanalyzeSpeakers(
        meetingID: String, audio: URL, speakerCount: Int?
    ) async throws -> DiarizationOutput {
        if speakerCount != nil {
            return try await reanalyze(meetingID: meetingID, audio: audio, speakerCount: speakerCount)
        }
        return try await LocalDiarizationBackend(models: self, cacheKey: meetingID)
            .diarize(audio: audio, progress: { _ in })
    }
}
