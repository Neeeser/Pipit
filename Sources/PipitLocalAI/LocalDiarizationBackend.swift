import Foundation
import PipitCore
import Synchronization

/// The diarizer Pipit ships for a finished meeting's remote speakers: Nemotron
/// 3 Diarization, with the offline clusterer behind it for the meetings
/// Nemotron cannot do.
///
/// On the held-out `deciding` suite, leaving out the ICSI cases Nemotron trained
/// on, Nemotron cut mean tcpWER from 53.6% to 38.2% and found the right speaker
/// count on 10 of 10 cases against 2 of 10, at word error unchanged and similar
/// speed. The clusterer still runs in two places, and the run's provenance
/// says which one it was:
///
/// - Its files are not installed, or the model failed on this audio, which
///   includes returning no speakers for audio loud enough to hold speech.
/// - A person asked for a speaker count, which Nemotron cannot be told. That
///   path never reaches this type; `LocalModelManager.reanalyzeSpeakers` sends
///   it straight to the clusterer.
///
/// A meeting that fills all eight of Nemotron's speaker slots keeps Nemotron's
/// answer. With more than eight people Nemotron usually merges voices and
/// reports fewer than eight, so a full set of slots is not a reliable sign of
/// a crowded meeting, and the clusterer over-counts real meetings. A person who
/// knows the count types it, which sends the meeting to the clusterer.
///
/// Live diarization during a call stays on the clusterer: it reruns on growing
/// scratch files and has not been measured with Nemotron.
public struct LocalDiarizationBackend: DiarizationBackend {
    /// Why the offline clusterer ran in place of Nemotron. Recorded as the
    /// run's `diarizerReason`.
    public enum Reason: String, Sendable {
        case speakerCountRequested
        case modelNotInstalled
        case modelFailed
        /// Nemotron ran and its answer was kept.
        case preferred
    }

    private let primary: any DiarizationBackend
    private let fallback: any DiarizationBackend

    public init(primary: any DiarizationBackend, fallback: any DiarizationBackend) {
        self.primary = primary
        self.fallback = fallback
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

    /// How much of the bar Nemotron's own progress fills.
    static let primaryShare = 0.9

    public func diarize(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DiarizationOutput {
        // Nemotron fills nine tenths of the bar, and only an answer that is
        // kept fills the rest. A rejected or failed run hands the clusterer the
        // bar from where Nemotron stopped, so it never sits full or goes back.
        let sent = Mutex(0.0)
        let send: @Sendable (Double) -> Void = { value in
            let forward = sent.withLock { last -> Double in
                last = max(last, min(max(value, 0), 1))
                return last
            }
            progress(forward)
        }
        let reason: Reason
        do {
            let output = try await primary.diarize(
                audio: audio, progress: { send(min(max($0, 0), 1) * Self.primaryShare) })
            if Self.foundNoSpeakerInLoudAudio(output) {
                reason = .modelFailed
                Log.processing.notice("nemotron diarization found no speaker in audible audio, using the clusterer")
            } else {
                send(1)
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
        let start = sent.withLock { $0 }
        let output = try await fallback.diarize(
            audio: audio, progress: { send(start + (1 - start) * min(max($0, 0), 1)) }
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
