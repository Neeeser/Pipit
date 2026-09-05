import Foundation
import PipitCore
import PipitIntegrations
import Testing

/// The cloud transcription models differ in what timing structure they return,
/// and the request and the parser both have to follow the model. whisper-1 is
/// the only model with word timings; gpt-4o-transcribe-diarize returns speaker
/// segments; gpt-transcribe returns the best text and no timings at all, which
/// the local alignment stage supplies afterwards.
@Suite("CloudModels")
struct CloudModelTests {
    @Test("each cloud model declares the timing it returns")
    func eachCloudModelDeclaresTheTimingItReturns() async throws {
        #expect(AIModelSettings.transcriptionTiming(for: "gpt-transcribe") == .text)
        #expect(AIModelSettings.transcriptionTiming(for: "gpt-4o-transcribe-diarize") == .segments)
        #expect(AIModelSettings.transcriptionTiming(for: "whisper-1") == .words)
        #expect(
            AIModelSettings.transcriptionTiming(for: "some-future-model") == .segments,
            "an unknown model is requested as verbose_json, which returns segments"
        )
    }

    @Test("the transcription backend reports its model's timing")
    func theTranscriptionBackendReportsItsModelsTiming() async throws {
        let stub = StubAIBackend()
        #expect(OpenAITranscriptionBackend(backend: stub, model: "gpt-transcribe").timing == .text)
        #expect(OpenAITranscriptionBackend(backend: stub, model: "whisper-1").timing == .words)
    }

    @Test("flat word timings nest into their segments")
    func flatWordTimingsNestIntoTheirSegments() async throws {
        // whisper-1 with word granularity returns `words` at the top
        // level, not inside each segment.
        let body = """
        {"text": "hello there general",
         "duration": 4.0,
         "segments": [
           {"start": 0.0, "end": 2.0, "text": "hello there"},
           {"start": 2.0, "end": 4.0, "text": "general"}
         ],
         "words": [
           {"word": "hello", "start": 0.1, "end": 0.6},
           {"word": "there", "start": 0.7, "end": 1.2},
           {"word": "general", "start": 2.2, "end": 2.9}
         ]}
        """.data(using: .utf8)!
        let response = try OpenAIClient.parseTranscription(body, allowTextOnly: false)
        #expect(response.segments.count == 2)
        #expect(
            response.segments.first?.words?.map(\.text) == [" hello", " there"],
            "words land in their segment, spaced the way the assembler joins"
        )
        #expect(response.segments.last?.words?.map(\.text) == [" general"])
    }

    @Test("a text-only response is valid for a model without timings")
    func aTextOnlyResponseIsValidForAModelWithoutTimings() async throws {
        let body = #"{"text": "just the words"}"#.data(using: .utf8)!
        let response = try OpenAIClient.parseTranscription(body, allowTextOnly: true)
        #expect(response.text == "just the words")
        #expect(response.segments.count == 0, "no timings invented")
    }

    @Test("a text-only response still fails for a model that promised timings")
    func aTextOnlyResponseStillFailsForAModelThatPromisedTimings() async throws {
        let body = #"{"text": "just the words"}"#.data(using: .utf8)!
        #expect(
            throws: (any Error).self,
            "segmentless output from a segment model is a malformed response"
        ) {
            _ = try OpenAIClient.parseTranscription(body, allowTextOnly: false)
        }
    }

    @Test("vocabulary hints split into keywords")
    func vocabularyHintsSplitIntoKeywords() async throws {
        var models = AIModelSettings()
        models.vocabularyHints = "Pipit, FluidAudio\n WhisperKit ,,\n"
        #expect(
            models.keywordList == ["Pipit", "FluidAudio", "WhisperKit"],
            "commas and newlines both separate; blanks are dropped"
        )
        #expect(AIModelSettings().keywordList == [], "empty field means no hints")
    }
}

/// An AIBackend that is never called; the tests above only read capabilities.
private struct StubAIBackend: AIBackend {
    func isConfigured() async -> Bool { false }
    func verifyCredentials(model: String) async throws {}
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResponse {
        throw ProcessingError.malformedResponse(reason: "stub")
    }
    func diarize(_ request: DiarizationRequest) async throws -> TranscriptionResponse {
        throw ProcessingError.malformedResponse(reason: "stub")
    }
    func resolveSpeakers(
        _ request: SpeakerResolutionRequest, model: String
    ) async throws -> [SpeakerSuggestion] { [] }
    func enrich(_ request: EnrichmentRequest, model: String) async throws -> MeetingEnrichment {
        MeetingEnrichment()
    }
}
