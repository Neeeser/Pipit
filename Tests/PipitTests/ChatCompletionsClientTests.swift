import Foundation
import PipitCore
import PipitIntegrations
import Testing

/// Writing about a meeting through a server that speaks chat completions:
/// OpenRouter, or an address the person typed.
@Suite("ChatCompletionsClient")
struct ChatCompletionsClientTests {
    private final class RecordingKey: APIKeyProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var invalidations = 0
        let key: String?

        init(_ key: String?) { self.key = key }

        func apiKey() throws -> String {
            guard let key else { throw ProcessingError.missingAPIKey }
            return key
        }

        var isKnownAbsent: Bool { key == nil }
        func invalidateCachedKey() { lock.withLock { invalidations += 1 } }
        var invalidated: Int { lock.withLock { invalidations } }
    }

    private func reply(_ content: String) -> StubReply {
        .json(["choices": [["message": ["role": "assistant", "content": content]]]])
    }

    private func enrichment(title: Bool = true, summary: Bool = true) -> EnrichmentRequest {
        EnrichmentRequest(
            transcript: "[00:01] Ana: We ship on Friday.\n[00:09] Ben: Agreed.",
            humanNotes: nil, participants: ["Ana", "Ben"], provider: .zoom, durationSeconds: 600,
            wantsTitle: title, wantsDescription: false, wantsSummary: summary, wantsNotes: false
        )
    }

    private func client(
        _ server: StubServer, provider: LanguageModelProvider = .custom, key: (any APIKeyProviding)? = nil
    ) -> ChatCompletionsClient {
        let configuration =
            provider == .openRouter
            ? ChatCompletionsClient.Configuration.openRouter(baseURL: server.baseURL(path: "/api/v1"))
            : ChatCompletionsClient.Configuration(provider: provider, baseURL: server.baseURL(path: "/v1"))
        return ChatCompletionsClient(configuration: configuration, keyProvider: key, session: server.session)
    }

    @Test("the answer is asked for as a schema, with the key and the app's name")
    func theAnswerIsAskedForAsASchemaWithTheKeyAndTheAppsName() async throws {
        let server = StubServer { [self] _ in reply(#"{"title":"Ship on Friday","summary":"Ana and Ben agreed."}"#) }
        let result = try await client(server, provider: .openRouter, key: RecordingKey("sk-or-test"))
            .enrich(enrichment(), model: "meta-llama/llama-3.3-70b-instruct")

        #expect(result.title == "Ship on Friday")
        #expect(result.summary == "Ana and Ben agreed.")

        let sent = try #require(server.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.path == "/api/v1/chat/completions")
        #expect(sent.header("Authorization") == "Bearer sk-or-test")
        #expect(sent.header("X-Title") == "Pipit")
        let body = try #require(sent.json)
        #expect(body["model"] as? String == "meta-llama/llama-3.3-70b-instruct")
        #expect(body["stream"] as? Bool == false)
        let format = try #require(body["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect((messages[1]["content"] as? String)?.contains("We ship on Friday.") == true)
    }

    @Test("a server that refuses the schema is asked again in plain words")
    func aServerThatRefusesTheSchemaIsAskedAgainInPlainWords() async throws {
        let server = StubServer { [self] request in
            request.json?["response_format"] != nil
                ? .json(["error": ["message": "response_format is not supported"]], status: 400)
                : reply(#"{"title":"Ship on Friday"}"#)
        }
        let result = try await client(server).enrich(enrichment(summary: false), model: "local-model")

        #expect(result.title == "Ship on Friday")
        #expect(server.requests.count == 2)
        let second = try #require(server.requests.last?.json)
        #expect(second["response_format"] == nil)
        let system = try #require((second["messages"] as? [[String: Any]])?.first?["content"] as? String)
        #expect(system.contains("JSON Schema"), "the shape of the answer moved into the instructions")
    }

    @Test("the object is found in a reply that wraps it in a fence, prose or thinking")
    func theObjectIsFoundInAReplyThatWrapsItInAFenceProseOrThinking() async throws {
        let replies = [
            "```json\n{\"title\":\"Fenced\"}\n```",
            "Here is the result:\n{\"title\":\"After prose\"}\nHope that helps.",
            "<think>Let me {think} about it.</think>\n{\"title\":\"After thinking\"}",
            "{\"title\":\"Braces } in { a string\"}",
        ]
        let wanted = ["Fenced", "After prose", "After thinking", "Braces } in { a string"]
        for (content, title) in zip(replies, wanted) {
            let server = StubServer { [self] _ in reply(content) }
            let result = try await client(server).enrich(enrichment(summary: false), model: "m")
            #expect(result.title == title)
        }
    }

    @Test("a reply that is not JSON, twice, fails as an unexpected response")
    func aReplyThatIsNotJSONTwiceFailsAsAnUnexpectedResponse() async {
        let server = StubServer { [self] _ in reply("I would be happy to help with that.") }
        await #expect(
            throws: ProcessingError.languageModel(provider: "Custom endpoint", failure: .unexpectedResponse)
        ) {
            _ = try await client(server).enrich(enrichment(), model: "m")
        }
        #expect(server.requests.count == 2, "once as a schema, once in plain words")
    }

    @Test("a refused key stops at once and drops the cached copy")
    func aRefusedKeyStopsAtOnceAndDropsTheCachedCopy() async {
        let key = RecordingKey("sk-or-old")
        let server = StubServer { _ in .json(["error": ["message": "No auth"]], status: 401) }
        await #expect(
            throws: ProcessingError.languageModel(provider: "OpenRouter", failure: .authenticationFailed)
        ) {
            _ = try await client(server, provider: .openRouter, key: key).enrich(enrichment(), model: "m")
        }
        #expect(server.requests.count == 1, "a different request would be refused the same way")
        #expect(key.invalidated == 1)
    }

    @Test("a provider that needs a key does not send a request without one")
    func aProviderThatNeedsAKeyDoesNotSendARequestWithoutOne() async {
        let server = StubServer { [self] _ in reply("{}") }
        await #expect(
            throws: ProcessingError.languageModel(provider: "OpenRouter", failure: .authenticationFailed)
        ) {
            _ = try await client(server, provider: .openRouter, key: RecordingKey(nil))
                .enrich(enrichment(), model: "m")
        }
        #expect(server.requests.isEmpty)
    }

    @Test("a custom endpoint works with no key at all")
    func aCustomEndpointWorksWithNoKeyAtAll() async throws {
        let server = StubServer { [self] _ in reply(#"{"title":"No key needed"}"#) }
        let result = try await client(server).enrich(enrichment(summary: false), model: "m")
        #expect(result.title == "No key needed")
        #expect(server.requests.first?.header("Authorization") == nil)
    }

    @Test("rate limits and server errors are worth retrying, a missing model is not")
    func rateLimitsAndServerErrorsAreWorthRetryingAMissingModelIsNot() async {
        let cases: [(StubReply, LanguageModelFailure)] = [
            (StubReply(status: 429, headers: ["Retry-After": "7"]), .rateLimited(retryAfter: 7)),
            (StubReply(status: 503), .serverError(status: 503)),
            (StubReply(status: 404), .modelNotFound),
            (.down, .unreachable),
        ]
        for (answer, failure) in cases {
            let server = StubServer { _ in answer }
            await #expect(throws: ProcessingError.languageModel(provider: "Custom endpoint", failure: failure)) {
                _ = try await client(server).enrich(enrichment(), model: "m")
            }
            #expect(failure.isRetryable == (failure != .modelNotFound))
        }
    }

    @Test("a stage is passed over only when the store says there is no key")
    func aStageIsPassedOverOnlyWhenTheStoreSaysThereIsNoKey() async {
        let server = StubServer { _ in StubReply() }
        #expect(await client(server, provider: .openRouter, key: RecordingKey("k")).isConfigured())
        #expect(await !client(server, provider: .openRouter, key: RecordingKey(nil)).isConfigured())
        #expect(await !client(server, provider: .openRouter, key: nil).isConfigured())
        #expect(await client(server, provider: .custom, key: nil).isConfigured())
    }

    @Test("speaker suggestions come back with the line they rest on")
    func speakerSuggestionsComeBackWithTheLineTheyRestOn() async throws {
        let answer = """
            {"mapping":[{"label":"Speaker 2","name":"Ben","confidence":0.9,
              "quote":"Thanks, Ben.","at_seconds":12.5,"expanded_from_known_names":false},
             {"label":"Speaker 7","name":"Nobody","confidence":0.9,"quote":"x","at_seconds":1.5,
              "expanded_from_known_names":false}],"unresolved":[]}
            """
        let server = StubServer { [self] _ in reply(answer) }
        let suggestions = try await client(server).resolveSpeakers(
            SpeakerResolutionRequest(
                transcript: "[00:12] Speaker 2: Thanks, Ben.", labels: ["Speaker 2"],
                humanContext: nil, nameHints: ["Ben"], localUserName: nil
            ),
            model: "m"
        )
        #expect(suggestions.map(\.name) == ["Ben"], "a label that was not asked about is dropped")
        #expect(suggestions.first?.quote == "Thanks, Ben.")
        #expect(suggestions.first?.atSeconds == 12.5)
    }

    @Test("testing the connection sends a short request for the chosen model")
    func testingTheConnectionSendsAShortRequestForTheChosenModel() async throws {
        let server = StubServer { [self] _ in reply("OK") }
        try await client(server).verifyCredentials(model: "local-model")
        let sent = try #require(server.requests.first)
        #expect(sent.path == "/v1/chat/completions")
        #expect((sent.json?["max_tokens"] as? Int) == 16)

        let listing = StubServer { _ in .json(["data": []]) }
        try await client(listing).verifyCredentials(model: "")
        #expect(listing.requests.first?.method == "GET")
        #expect(listing.requests.first?.path == "/v1/models")
    }
}
