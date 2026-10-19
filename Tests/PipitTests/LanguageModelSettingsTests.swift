import Foundation
import PipitCore
import Testing

/// The choice of which model writes about a meeting, and the arithmetic that
/// sizes what it is sent.
@Suite("LanguageModelSettings")
struct LanguageModelSettingsTests {
    private func decode(_ json: String) throws -> AIModelSettings {
        try JSONDecoder().decode(AIModelSettings.self, from: Data(json.utf8))
    }

    @Test("a settings file from before providers keeps its model and its provider")
    func aSettingsFileFromBeforeProvidersKeepsItsModelAndItsProvider() throws {
        let settings = try decode(
            """
            {"transcription":"gpt-transcribe","diarization":"gpt-4o-transcribe-diarize",
             "metadata":"gpt-5.1","vocabularyHints":"Pipit"}
            """
        )
        #expect(settings.metadataProvider == .openAI)
        #expect(settings.metadata == "gpt-5.1")
        #expect(settings.transcription == "gpt-transcribe")
        #expect(settings.vocabularyHints == "Pipit")
    }

    @Test("each provider keeps its own model")
    func eachProviderKeepsItsOwnModel() {
        var settings = AIModelSettings()
        #expect(settings.metadata == AIModelSettings.defaultMetadataModel)

        settings.metadataProvider = .ollama
        #expect(settings.metadata.isEmpty, "a local model is chosen, never assumed")
        settings.metadata = "llama3.1:8b"
        settings.metadataContextTokens = 32_768

        settings.metadataProvider = .openRouter
        #expect(settings.metadata.isEmpty)
        settings.metadata = "meta-llama/llama-3.3-70b-instruct"

        settings.metadataProvider = .openAI
        #expect(settings.metadata == AIModelSettings.defaultMetadataModel)

        settings.metadataProvider = .ollama
        #expect(settings.metadata == "llama3.1:8b")
        #expect(settings.metadataContextTokens == 32_768)
        #expect(
            settings.metadataContextTokens != LanguageModelProvider.openRouter.defaultContextTokens,
            "a window set for one provider is not carried to the next"
        )
    }

    @Test("a control about one provider can read and write its model whichever is selected")
    func aControlAboutOneProviderCanReadAndWriteItsModelWhicheverIsSelected() {
        var settings = AIModelSettings()
        settings.metadataProvider = .ollama
        settings.metadata = "llama3.1:8b"

        #expect(settings.metadataModel(for: .openAI) == AIModelSettings.defaultMetadataModel)
        settings.setMetadataModel("gpt-4.1", for: .openAI)
        #expect(settings.metadataModel(for: .openAI) == "gpt-4.1")
        #expect(settings.metadata == "llama3.1:8b", "the selected provider's model is untouched")
        #expect(settings.metadataProvider == .ollama)
    }

    @Test("the model in use is still written under the key an older build reads")
    func theModelInUseIsStillWrittenUnderTheKeyAnOlderBuildReads() throws {
        var settings = AIModelSettings()
        settings.metadataProvider = .ollama
        settings.metadata = "qwen3:8b"
        let data = try JSONEncoder().encode(settings)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["metadata"] as? String == "qwen3:8b")

        let restored = try JSONDecoder().decode(AIModelSettings.self, from: data)
        #expect(restored == settings)
    }

    @Test("a provider this build does not know falls back without losing the rest")
    func aProviderThisBuildDoesNotKnowFallsBackWithoutLosingTheRest() throws {
        let settings = try decode(
            """
            {"transcription":"gpt-transcribe","metadata":"gpt-4.1","metadataProvider":"somethingNew"}
            """
        )
        #expect(settings.metadataProvider == .openAI)
        #expect(settings.transcription == "gpt-transcribe")
        #expect(settings.metadata == "gpt-4.1")
    }

    @Test("a damaged choice does not reset the other model identifiers")
    func aDamagedChoiceDoesNotResetTheOtherModelIdentifiers() throws {
        let settings = try decode(
            """
            {"transcription":"gpt-transcribe","metadata":"gpt-4.1",
             "metadataSelections":{"ollama":"not an object"}}
            """
        )
        #expect(settings.transcription == "gpt-transcribe")
        #expect(settings.metadata == "gpt-4.1")
    }

    @Test("a custom endpoint address means the server whatever part of it was pasted")
    func aCustomEndpointAddressMeansTheServerWhateverPartOfItWasPasted() {
        let expected: [(String, String?)] = [
            ("http://localhost:1234", "http://localhost:1234/v1"),
            ("http://localhost:1234/v1/", "http://localhost:1234/v1"),
            ("  http://192.168.1.20:8080/v1/chat/completions  ", "http://192.168.1.20:8080/v1"),
            ("https://openrouter.ai/api/v1/models", "https://openrouter.ai/api/v1"),
            ("https://gateway.example.com/openai?key=1#top", "https://gateway.example.com/openai"),
            ("localhost:1234", nil),
            ("ftp://example.com/v1", nil),
            ("http://", nil),
            ("", nil),
        ]
        for (typed, wanted) in expected {
            #expect(EndpointAddress.normalized(typed)?.absoluteString == wanted, "for \(typed)")
        }
    }

    @Test("the context window says how long a meeting it holds")
    func theContextWindowSaysHowLongAMeetingItHolds() {
        let expected: [(Int, String)] = [
            (4_096, "under 10 minutes"),
            (8_192, "about 20 minutes"),
            (16_384, "about 55 minutes"),
            (32_768, "about 2 hours"),
            (65_536, "about 4 hours"),
            (131_072, "about 8.5 hours"),
        ]
        for (tokens, wanted) in expected {
            #expect(ContextWindow.fitDescription(context: tokens) == wanted, "for \(tokens)")
        }
        #expect(ContextWindow.meetingMinutes(context: 1_000) == 0)
    }

    @Test("window sizes read as the figures people know them by")
    func windowSizesReadAsTheFiguresPeopleKnowThemBy() {
        #expect(ContextWindow.label(4_096) == "4K")
        #expect(ContextWindow.label(131_072) == "128K")
        #expect(ContextWindow.label(40_960) == "40K")
        #expect(ContextWindow.label(1_048_576) == "1M")
    }

    @Test("a published window reads the way the provider states it")
    func aPublishedWindowReadsTheWayTheProviderStatesIt() {
        #expect(ContextWindow.publishedLabel(128_000) == "128K")
        #expect(ContextWindow.publishedLabel(131_072) == "131K")
        #expect(ContextWindow.publishedLabel(200_000) == "200K")
        #expect(ContextWindow.publishedLabel(1_048_576) == "1M")
        #expect(ContextWindow.publishedLabel(2_000_000) == "2M")
        #expect(ContextWindow.publishedLabel(1_500_000) == "1.5M")
        #expect(ContextWindow.largestSize(atMost: 128_000) == 65_536)
        #expect(ContextWindow.largestSize(atMost: 131_072) == 131_072)
        #expect(ContextWindow.largestSize(atMost: 1_000) == ContextWindow.sizes[0])
    }

    @Test("a model can offer no more than it supports")
    func aModelCanOfferNoMoreThanItSupports() {
        #expect(ContextWindow.sizes(upTo: nil) == ContextWindow.sizes)
        #expect(ContextWindow.sizes(upTo: 8_192) == [4_096, 8_192])
        #expect(
            ContextWindow.sizes(upTo: 40_960) == [4_096, 8_192, 16_384, 32_768, 40_960],
            "a limit between two sizes is offered as well"
        )
        #expect(ContextWindow.sizes(upTo: 2_000) == [4_096], "never an empty slider")
        #expect(ContextWindow.sizes(upTo: 1_000_000) == ContextWindow.sizes)
        #expect(ContextWindow.nearest(20_000, in: ContextWindow.sizes) == 16_384)
        #expect(ContextWindow.nearest(1, in: []) == ContextWindow.defaultTokens)
    }

    @Test("the transcript budget leaves room for the instructions and the answer")
    func theTranscriptBudgetLeavesRoomForTheInstructionsAndTheAnswer() {
        let characters = ContextWindow.transcriptCharacters(context: 16_384)
        #expect(characters > 40_000 && characters < 48_000)
        #expect(
            ContextWindow.transcriptCharacters(context: 16_384, overheadCharacters: 10_000) < characters,
            "folder names and notes come out of the same window"
        )
        #expect(
            ContextWindow.transcriptCharacters(context: 4_096, overheadCharacters: 50_000)
                == ContextWindow.minimumTranscriptCharacters
        )
    }

    @Test("a failure reads as a fact in Settings and as a plan on a meeting")
    func aFailureReadsAsAFactInSettingsAndAsAPlanOnAMeeting() {
        let all: [LanguageModelFailure] = [
            .authenticationFailed, .unreachable, .rateLimited(retryAfter: nil),
            .serverError(status: 500), .modelNotFound, .rejected(status: 400), .unexpectedResponse,
        ]
        for failure in all {
            let fact = failure.statement(provider: "Ollama")
            #expect(fact.contains("Ollama") && !fact.hasSuffix("."), "\(failure)")
            #expect(failure.message(provider: "Ollama").hasPrefix(fact))
            #expect(failure.message(provider: "Ollama").hasSuffix("."))
            #expect(
                failure.message(provider: "Ollama").contains("retry") == failure.isRetryable,
                "only a failure that is retried says so: \(failure)"
            )
        }
    }

    @Test("an error from a model names the provider that failed")
    func anErrorFromAModelNamesTheProviderThatFailed() {
        let error = ProcessingError.languageModel(provider: "Ollama", failure: .unreachable)
        #expect(error.isRetryable)
        #expect(error.userMessage.contains("Ollama"))
        #expect(!error.userMessage.contains("OpenAI"))
        #expect(
            !ProcessingError.languageModel(provider: "OpenRouter", failure: .authenticationFailed)
                .isRetryable
        )
        #expect(
            !ProcessingError.languageModel(provider: "Ollama", failure: .modelNotFound).logSafeDescription
                .contains("Ollama"),
            "the log line carries the category, not the provider's name or any content"
        )
    }
}

@Suite("TranscriptChunker")
struct TranscriptChunkerTests {
    private func transcript(lines: Int) -> String {
        (0..<lines).map { "[\(String(format: "%02d", $0 % 60)):00] Speaker \($0 % 3): line \($0) of the call" }
            .joined(separator: "\n")
    }

    @Test("a transcript that fits stays whole")
    func aTranscriptThatFitsStaysWhole() {
        let text = transcript(lines: 5)
        #expect(TranscriptChunker.split(text, limit: 10_000) == [text])
        #expect(TranscriptChunker.split("", limit: 100).isEmpty)
    }

    @Test("a long transcript is cut between lines into near equal parts")
    func aLongTranscriptIsCutBetweenLinesIntoNearEqualParts() {
        let text = transcript(lines: 200)
        let limit = 1_800
        let parts = TranscriptChunker.split(text, limit: limit)

        #expect(parts.count >= Int((Double(text.count) / Double(limit)).rounded(.up)))
        #expect(parts.allSatisfy { $0.count <= limit })
        #expect(parts.joined(separator: "\n") == text, "nothing is lost or repeated")

        let original = Set(text.split(separator: "\n").map(String.init))
        for part in parts {
            #expect(part.split(separator: "\n").allSatisfy { original.contains(String($0)) })
        }
        let sizes = parts.map(\.count)
        let spread = (sizes.max() ?? 0) - (sizes.min() ?? 0)
        #expect(spread < limit / 2, "the last part is not a few stray lines: \(sizes)")
    }

    @Test("a line longer than the limit is cut at a space, not dropped")
    func aLineLongerThanTheLimitIsCutAtASpaceNotDropped() {
        let words = (0..<120).map { "word\($0)" }
        let text = "[00:01] A: " + words.joined(separator: " ")
        let parts = TranscriptChunker.split(text, limit: 200)

        #expect(parts.count > 1)
        #expect(parts.allSatisfy { $0.count <= 200 })
        let rejoined = parts.joined(separator: " ").split(separator: " ").map(String.init)
        #expect(rejoined == text.split(separator: " ").map(String.init))
    }
}
