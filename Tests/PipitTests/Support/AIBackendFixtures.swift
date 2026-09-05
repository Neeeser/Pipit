import Foundation
import PipitCore
import PipitIntegrations

/// A scripted AI backend. Records what it was asked and returns what the test
/// says, so the pipeline can be exercised end to end without the network.
public final class FakeAIBackend: AIBackend, @unchecked Sendable {
    public init() {}

    public struct Call: Sendable, Equatable {
        public let kind: String
        public let model: String
        public let file: String

        public init(kind: String, model: String, file: String) {
            self.kind = kind
            self.model = model
            self.file = file
        }
    }

    private let lock = NSLock()
    public private(set) var calls: [Call] = []
    public var transcriptionSegments: [RawTranscriptSegment] = []
    public var diarizationSegments: [RawTranscriptSegment] = []
    public var suggestions: [SpeakerSuggestion] = []
    public var enrichment = MeetingEnrichment(title: "Retrieval logic", summary: "Discussed retrieval.")
    public var failNextTranscription: ProcessingError?
    /// Fails every enrichment request, for the lost-connection path.
    public var failEnrichment: ProcessingError?
    public var failNextDiarization: ProcessingError?
    /// Fails every request, for the bounded-retry path.
    public var alwaysFailTranscription: ProcessingError?
    /// Returns a different segment set per chunk index, for overlap tests.
    public var diarizationByChunk: [[RawTranscriptSegment]] = []
    /// False models a user who never entered a key.
    public var configured = true
    /// Runs inside the enrichment request, for the paths that need something to
    /// happen to the meeting while a call is in flight.
    public var enrichInterference: (@Sendable () async -> Void)?
    /// The folder catalogue the last enrichment request carried, so a test can
    /// check what the model was and was not shown.
    public private(set) var lastEnrichmentFolders: [EnrichmentFolder]?

    public func isConfigured() async -> Bool { configured }

    public func record(_ call: Call) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    public func verifyCredentials(model: String) async throws {}

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResponse {
        if let failure = alwaysFailTranscription {
            record(Call(kind: "transcribe", model: request.model, file: request.audio.lastPathComponent))
            throw failure
        }
        if let failure = failNextTranscription {
            failNextTranscription = nil
            throw failure
        }
        record(Call(kind: "transcribe", model: request.model, file: request.audio.lastPathComponent))
        return TranscriptionResponse(
            segments: transcriptionSegments,
            text: transcriptionSegments.map(\.text).joined(separator: " "),
            durationSeconds: nil,
            rawBody: Data("{}".utf8)
        )
    }

    public func diarize(_ request: DiarizationRequest) async throws -> TranscriptionResponse {
        if let failure = failNextDiarization {
            failNextDiarization = nil
            throw failure
        }
        let index = lock.withLock { () -> Int in
            calls.filter { $0.kind == "diarize" }.count
        }
        record(Call(kind: "diarize", model: request.model, file: request.audio.lastPathComponent))
        let segments = index < diarizationByChunk.count ? diarizationByChunk[index] : diarizationSegments
        return TranscriptionResponse(
            segments: segments,
            text: segments.map(\.text).joined(separator: " "),
            durationSeconds: nil,
            rawBody: Data("{}".utf8)
        )
    }

    public func resolveSpeakers(
        _ request: SpeakerResolutionRequest, model: String
    ) async throws -> [SpeakerSuggestion] {
        record(Call(kind: "resolve", model: model, file: ""))
        // What the real client does with no key, and the reason these stages
        // have to ask before calling: the error is not retryable.
        if !configured { throw ProcessingError.missingAPIKey }
        return suggestions
    }

    public func enrich(_ request: EnrichmentRequest, model: String) async throws -> MeetingEnrichment {
        record(Call(kind: "enrich", model: model, file: ""))
        lock.withLock { lastEnrichmentFolders = request.folders }
        if !configured { throw ProcessingError.missingAPIKey }
        if let enrichInterference { await enrichInterference() }
        if let failEnrichment { throw failEnrichment }
        return enrichment
    }
}
