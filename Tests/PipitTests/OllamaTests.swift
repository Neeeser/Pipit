import Foundation
import PipitCore
import PipitIntegrations
import Testing

/// Ollama on this Mac: finding it, listing what it holds, and writing about a
/// meeting with one of its models.
@Suite("Ollama")
struct OllamaTests {
    /// What Ollama lists for two downloaded models.
    private func tagsReply() -> StubReply {
        .json([
            "models": [
                [
                    "name": "qwen3:8b", "size": 5_225_376_047,
                    "details": ["parameter_size": "8.2B", "quantization_level": "Q4_K_M"],
                ],
                [
                    "name": "llama3.1:8b", "size": 4_920_753_328,
                    "details": ["parameter_size": "8.0B", "quantization_level": "Q4_K_M"],
                ],
            ]
        ])
    }

    private func chatReply(_ content: String) -> StubReply {
        .json(["message": ["role": "assistant", "content": content], "done": true])
    }

    private func request() -> EnrichmentRequest {
        EnrichmentRequest(
            transcript: "[00:01] Ana: We ship on Friday.", humanNotes: nil, participants: [],
            provider: .unknown, durationSeconds: 300, wantsTitle: true, wantsDescription: false,
            wantsSummary: false, wantsNotes: false
        )
    }

    @Test("incomplete enrichment JSON is retried and then reported as a failure")
    func incompleteEnrichmentIsRejected() async {
        let server = StubServer { [self] _ in chatReply("{}") }
        let client = OllamaClient(
            configuration: .init(baseURL: server.baseURL()), session: server.session
        )
        await #expect(
            throws: ProcessingError.languageModel(provider: "Ollama", failure: .unexpectedResponse)
        ) {
            _ = try await client.enrich(request(), model: "m")
        }
        #expect(server.requests.count == 2)
    }

    @Test("a running Ollama is found with its models, by name")
    func aRunningOllamaIsFoundWithItsModelsByName() async throws {
        let server = StubServer { [self] _ in tagsReply() }
        let status = await OllamaServer(
            baseURL: server.baseURL(), session: server.session, installLocations: []
        ).status()

        guard case .running(let models) = status else {
            Issue.record("expected a running server, got \(status)")
            return
        }
        #expect(models.map(\.name) == ["llama3.1:8b", "qwen3:8b"])
        #expect(models.first?.parameterSize == "8.0B")
        #expect(models.first?.quantization == "Q4_K_M")
        #expect(models.first?.sizeBytes == 4_920_753_328)
        #expect(server.requests.first?.path == "/api/tags")
    }

    @Test("an Ollama that is installed but not answering is told apart from none")
    func anOllamaThatIsInstalledButNotAnsweringIsToldApartFromNone() async throws {
        let server = StubServer { _ in .down }
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("stub-\(UUID().uuidString)/Ollama.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        let installed = OllamaServer(
            baseURL: server.baseURL(), session: server.session, installLocations: [app]
        )
        #expect(await installed.status() == .installedNotRunning)
        #expect(installed.applicationURL == app)

        let absent = OllamaServer(
            baseURL: server.baseURL(), session: server.session,
            installLocations: [app.appendingPathComponent("missing")]
        )
        #expect(await absent.status() == .notInstalled)
    }

    @Test("a model's own limit is read from its description")
    func aModelsOwnLimitIsReadFromItsDescription() async {
        let server = StubServer { _ in
            .json(["model_info": ["general.architecture": "llama", "llama.context_length": 131_072]])
        }
        let ollama = OllamaServer(baseURL: server.baseURL(), session: server.session, installLocations: [])
        #expect(await ollama.maximumContext(of: "llama3.1:8b") == 131_072)
        #expect(server.requests.first?.path == "/api/show")

        let silent = StubServer { _ in .json(["model_info": ["general.architecture": "llama"]]) }
        let none = OllamaServer(baseURL: silent.baseURL(), session: silent.session, installLocations: [])
        #expect(await none.maximumContext(of: "x") == nil)
    }

    @Test("a model typed without a tag means its latest")
    func aModelTypedWithoutATagMeansItsLatest() {
        let models = [OllamaModel(name: "llama3.2:latest", sizeBytes: 1), OllamaModel(name: "qwen3:8b", sizeBytes: 1)]
        #expect(OllamaServer.hasModel("llama3.2", in: models))
        #expect(OllamaServer.hasModel("qwen3:8b", in: models))
        #expect(!OllamaServer.hasModel("qwen3", in: models))
        #expect(!OllamaServer.hasModel("mistral", in: models))
    }

    @Test("every request names the context window the person chose")
    func everyRequestNamesTheContextWindowThePersonChose() async throws {
        let server = StubServer { [self] _ in chatReply(#"{"title":"Ship on Friday"}"#) }
        let client = OllamaClient(
            configuration: OllamaClient.Configuration(
                baseURL: server.baseURL(), contextTokens: 24_576
            ),
            session: server.session
        )
        let result = try await client.enrich(request(), model: "llama3.1:8b")
        #expect(result.title == "Ship on Friday")

        let sent = try #require(server.requests.first)
        #expect(sent.path == "/api/chat")
        let body = try #require(sent.json)
        #expect((body["options"] as? [String: Any])?["num_ctx"] as? Int == 24_576)
        #expect(body["stream"] as? Bool == false)
        #expect(body["think"] as? Bool == false)
        let format = try #require(body["format"] as? [String: Any])
        #expect(format["type"] as? String == "object", "the answer is held to the schema")
        #expect(sent.header("Authorization") == nil, "Ollama takes no key")
    }

    @Test("an Ollama that refuses the schema is asked again, still with the window")
    func anOllamaThatRefusesTheSchemaIsAskedAgainStillWithTheWindow() async throws {
        let server = StubServer { [self] request in
            request.json?["format"] != nil
                ? .json(["error": "invalid format"], status: 400)
                : chatReply("```json\n{\"title\":\"Plain words\"}\n```")
        }
        let client = OllamaClient(
            configuration: OllamaClient.Configuration(baseURL: server.baseURL(), contextTokens: 8_192),
            session: server.session
        )
        let result = try await client.enrich(request(), model: "old-model")
        #expect(result.title == "Plain words")

        let second = try #require(server.requests.last?.json)
        #expect(server.requests.count == 2)
        #expect(second["format"] == nil && second["think"] == nil)
        #expect((second["options"] as? [String: Any])?["num_ctx"] as? Int == 8_192)
    }

    @Test("a server that is not running fails where the person can see it, and is retried")
    func aServerThatIsNotRunningFailsWhereThePersonCanSeeItAndIsRetried() async {
        let server = StubServer { _ in .down }
        let client = OllamaClient(
            configuration: OllamaClient.Configuration(baseURL: server.baseURL()), session: server.session
        )
        #expect(await client.isConfigured(), "whether it is running is the request's question")
        await #expect(throws: ProcessingError.languageModel(provider: "Ollama", failure: .unreachable)) {
            _ = try await client.enrich(request(), model: "llama3.1:8b")
        }
    }

    @Test("a model that is not installed is reported as missing, not as a failed request")
    func aModelThatIsNotInstalledIsReportedAsMissingNotAsAFailedRequest() async throws {
        let server = StubServer { [self] _ in tagsReply() }
        let client = OllamaClient(
            configuration: OllamaClient.Configuration(baseURL: server.baseURL()), session: server.session
        )
        try await client.verifyCredentials(model: "llama3.1:8b")
        try await client.verifyCredentials(model: "")
        await #expect(throws: ProcessingError.languageModel(provider: "Ollama", failure: .modelNotFound)) {
            try await client.verifyCredentials(model: "mistral:7b")
        }
    }
}

@Suite("LanguageModelCatalogue")
struct LanguageModelCatalogueTests {
    private let listing: [String: Any] = [
        "data": [
            [
                "id": "meta-llama/llama-3.3-70b-instruct", "name": "Meta: Llama 3.3 70B Instruct",
                "context_length": 131_072,
                "pricing": ["prompt": "0.00000012", "completion": "0.0000003"],
                "architecture": ["output_modalities": ["text"]],
            ],
            [
                "id": "meta-llama/llama-3.3-70b-instruct:free", "name": "Meta: Llama 3.3 70B Instruct (free)",
                "top_provider": ["context_length": 65_536],
                "pricing": ["prompt": "0", "completion": "0"],
            ],
            [
                "id": "black-forest-labs/image-model", "name": "Image Model",
                "architecture": ["output_modalities": ["image"]],
            ],
            ["id": "plain-server-model"],
            ["id": "meta-llama/llama-3.3-70b-instruct"],
        ]
    ]

    @Test("a listing becomes options with prices and windows where the server gave them")
    func aListingBecomesOptionsWithPricesAndWindowsWhereTheServerGaveThem() throws {
        let data = try JSONSerialization.data(withJSONObject: listing)
        let options = LanguageModelCatalogue.parse(data)

        #expect(
            options.map(\.id) == [
                "meta-llama/llama-3.3-70b-instruct", "meta-llama/llama-3.3-70b-instruct:free",
                "plain-server-model",
            ],
            "sorted by name, one entry per model, and nothing that does not write text"
        )
        let paid = try #require(options.first)
        #expect(paid.contextTokens == 131_072)
        #expect(abs((paid.promptPrice ?? 0) - 0.12) < 0.0001)
        #expect(abs((paid.completionPrice ?? 0) - 0.30) < 0.0001)
        #expect(!paid.isFree)

        let free = options[1]
        #expect(free.isFree)
        #expect(free.contextTokens == 65_536, "falls back to the provider's figure")

        let bare = options[2]
        #expect(bare.name == "plain-server-model", "a server that names nothing is shown by id")
        #expect(bare.contextTokens == nil && bare.promptPrice == nil && !bare.isFree)
    }

    @Test("the listing is fetched from the models path, with the key if there is one")
    func theListingIsFetchedFromTheModelsPathWithTheKeyIfThereIsOne() async throws {
        struct Key: APIKeyProviding {
            func apiKey() throws -> String { "sk-test" }
        }
        let server = StubServer { _ in .json(["data": [["id": "a"], ["id": "b"]]]) }
        let catalogue = LanguageModelCatalogue(
            provider: .custom, baseURL: server.baseURL(path: "/v1"), keyProvider: Key(),
            session: server.session
        )
        let options = try await catalogue.fetch()
        #expect(options.map(\.id) == ["a", "b"])
        #expect(server.requests.first?.path == "/v1/models")
        #expect(server.requests.first?.header("Authorization") == "Bearer sk-test")

        let missing = StubServer { _ in StubReply(status: 404) }
        await #expect(throws: ProcessingError.languageModel(provider: "Custom endpoint", failure: .modelNotFound)) {
            _ = try await LanguageModelCatalogue(
                provider: .custom, baseURL: missing.baseURL(path: "/v1"), keyProvider: nil,
                session: missing.session
            ).fetch()
        }
    }
}
