import Foundation
import PipitCore

/// Writes about a meeting with a model running in Ollama.
///
/// This speaks Ollama's own chat endpoint rather than the OpenAI compatible one
/// for a reason: only the native request can set `num_ctx`. Ollama's default
/// window is a few thousand tokens, far short of a meeting, and a prompt past it
/// is cut short with no error, so the summary describes the start of the call
/// and says nothing about the rest. Every request here names the window the
/// person chose.
public struct OllamaClient: LanguageModelBackend {
    public struct Configuration: Sendable {
        public var baseURL: URL
        public var contextTokens: Int
        /// A model on this Mac reading a full window can take several minutes,
        /// and nothing arrives until it has finished.
        public var requestTimeout: TimeInterval

        public init(
            baseURL: URL = OllamaServer.defaultBaseURL,
            contextTokens: Int = ContextWindow.defaultTokens,
            requestTimeout: TimeInterval = 900
        ) {
            self.baseURL = baseURL
            self.contextTokens = contextTokens
            self.requestTimeout = requestTimeout
        }
    }

    private enum Mode: CaseIterable {
        case schema
        case promptOnly
    }

    private let configuration: Configuration
    private let transport: LanguageModelTransport
    private let server: OllamaServer

    public init(configuration: Configuration = Configuration(), session: URLSession = .shared) {
        self.configuration = configuration
        self.transport = LanguageModelTransport(provider: .ollama, session: session)
        self.server = OllamaServer(baseURL: configuration.baseURL, session: session, installLocations: [])
    }

    /// Ollama takes no key, and whether it is running is a question for the
    /// request: a server that is down fails the stage where it can be seen,
    /// which is what a person who chose it wants.
    public func isConfigured() async -> Bool { true }

    public func verifyCredentials(model: String) async throws {
        let models = try await server.models()
        if !model.isEmpty, !OllamaServer.hasModel(model, in: models) {
            throw transport.failure(.modelNotFound)
        }
    }

    public func resolveSpeakers(
        _ request: SpeakerResolutionRequest, model: String
    ) async throws -> [SpeakerSuggestion] {
        let prompt = LanguageModelPrompts.speakerResolution(request)
        let object = try await answer(to: prompt, model: model) {
            LanguageModelPrompts.speakerSuggestions(from: $0, labels: request.labels) != nil
        }
        return LanguageModelPrompts.speakerSuggestions(from: object, labels: request.labels) ?? []
    }

    public func enrich(_ request: EnrichmentRequest, model: String) async throws -> MeetingEnrichment {
        guard let prompt = LanguageModelPrompts.enrichment(request) else { return MeetingEnrichment() }
        let object = try await answer(to: prompt, model: model) {
            LanguageModelPrompts.acceptsEnrichment($0, for: request)
        }
        return LanguageModelPrompts.enrichment(from: object)
    }

    private func answer(
        to prompt: LanguageModelPrompt, model: String, accepts: ([String: Any]) -> Bool
    ) async throws -> [String: Any] {
        var lastFailure = transport.failure(.unexpectedResponse)
        for mode in Mode.allCases {
            do {
                let data = try await post(body(model: model, prompt: prompt, mode: mode))
                if let text = Self.replyText(from: data), let object = ModelJSON.object(from: text),
                    accepts(object)
                {
                    return object
                }
                lastFailure = transport.failure(.unexpectedResponse)
            } catch let error as ProcessingError {
                // An older Ollama refuses a schema as the format, and a model
                // that cannot think refuses to be told not to. Both are fixed by
                // asking in plain words. A server that is down is not.
                guard case .languageModel(_, let failure) = error, mode == .schema,
                    isRejection(failure)
                else { throw error }
                lastFailure = error
            }
        }
        throw lastFailure
    }

    private func isRejection(_ failure: LanguageModelFailure) -> Bool {
        if case .rejected = failure { return true }
        return false
    }

    private func body(model: String, prompt: LanguageModelPrompt, mode: Mode) -> [String: Any] {
        var system = prompt.instructions
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "options": ["num_ctx": configuration.contextTokens],
        ]
        switch mode {
        case .schema:
            system += "\n\nReply with a single JSON object."
            body["format"] = prompt.schema
            // Reasoning models spend minutes thinking before they summarise.
            // Ones that cannot be told not to ignore this.
            body["think"] = false
        case .promptOnly:
            system +=
                "\n\nReply with only a JSON object that matches this JSON Schema. "
                + "Add no other text and no code fence.\n\(ChatCompletionsClient.schemaText(prompt.schema))"
        }
        body["messages"] = [
            ["role": "system", "content": system],
            ["role": "user", "content": prompt.userContent],
        ]
        return body
    }

    static func replyText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = object["message"] as? [String: Any],
            let text = message["content"] as? String, !text.isEmpty
        else { return nil }
        return text
    }

    private func post(_ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await transport.send(request)
    }
}
