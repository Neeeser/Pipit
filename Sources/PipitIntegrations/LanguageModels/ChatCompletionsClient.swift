import Foundation
import PipitCore

/// Writes about a meeting through any server that answers
/// `POST {base}/chat/completions`: OpenRouter, LM Studio, vLLM, llama.cpp, and
/// the gateways in front of them.
///
/// Servers differ in how much of the request they honour. The answer is asked
/// for as a JSON schema first. A server that refuses that, or a model that
/// ignores it and answers in prose, gets one more request with the schema
/// written into the instructions instead, and the object is read out of
/// whatever comes back.
public struct ChatCompletionsClient: LanguageModelBackend {
    public struct Configuration: Sendable {
        public var provider: LanguageModelProvider
        public var baseURL: URL
        public var extraHeaders: [String: String]
        /// A model on someone's own machine can take minutes over a long prompt,
        /// and nothing arrives until it has finished.
        public var requestTimeout: TimeInterval

        public init(
            provider: LanguageModelProvider, baseURL: URL, extraHeaders: [String: String] = [:],
            requestTimeout: TimeInterval = 600
        ) {
            self.provider = provider
            self.baseURL = baseURL
            self.extraHeaders = extraHeaders
            self.requestTimeout = requestTimeout
        }

        /// OpenRouter asks an app to say which one it is.
        public static func openRouter(
            baseURL: URL = URL(string: LanguageModelProvider.openRouter.defaultBaseURL)!
        ) -> Configuration {
            Configuration(
                provider: .openRouter, baseURL: baseURL,
                extraHeaders: ["X-Title": "Pipit", "HTTP-Referer": "https://github.com/Neeeser/Pipit"],
                requestTimeout: 180
            )
        }
    }

    private enum Mode: CaseIterable {
        case schema
        case promptOnly
    }

    private let configuration: Configuration
    private let keyProvider: (any APIKeyProviding)?
    private let transport: LanguageModelTransport

    public init(
        configuration: Configuration, keyProvider: (any APIKeyProviding)?,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.keyProvider = keyProvider
        var transport = LanguageModelTransport(provider: configuration.provider, session: session)
        transport.onAuthenticationFailure = { [keyProvider] in keyProvider?.invalidateCachedKey() }
        self.transport = transport
    }

    // MARK: - credentials

    /// Same rule as the OpenAI client: false only when the store positively
    /// says there is no key, so a read that merely failed still attempts the
    /// stage and fails where the person can see it.
    public func isConfigured() async -> Bool {
        guard configuration.provider.keyRequirement == .required else { return true }
        guard let keyProvider else { return false }
        if (try? keyProvider.apiKey())?.isEmpty == false { return true }
        return !keyProvider.isKnownAbsent
    }

    /// With a model chosen, a one word reply proves the address, the key and the
    /// model together. Without one, listing the models proves the address and,
    /// on a server that checks keys there, the key.
    public func verifyCredentials(model: String) async throws {
        if model.isEmpty {
            var request = URLRequest(url: configuration.baseURL.appendingPathComponent("models"))
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            try authorize(&request)
            _ = try await transport.send(request)
            return
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "Reply with OK."]],
            "max_tokens": 16,
            "stream": false,
        ]
        _ = try await post(body, timeout: 120)
    }

    // MARK: - reasoning

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

    // MARK: - transport

    /// The JSON object a model answers with, trying the strict request first
    /// and the plain one if the server or the model does not manage it.
    private func answer(
        to prompt: LanguageModelPrompt, model: String, accepts: ([String: Any]) -> Bool
    ) async throws -> [String: Any] {
        var lastFailure = transport.failure(.unexpectedResponse)
        for mode in Mode.allCases {
            do {
                let data = try await post(Self.body(model: model, prompt: prompt, mode: mode))
                if let text = Self.replyText(from: data), let object = ModelJSON.object(from: text),
                    accepts(object)
                {
                    return object
                }
                lastFailure = transport.failure(.unexpectedResponse)
            } catch let error as ProcessingError {
                // Only a refusal of the request itself is worth another shape of
                // it. A bad key or an unreachable server would fail the same way.
                guard case .languageModel(_, let failure) = error, mode == .schema,
                    failure == .modelNotFound || isRejection(failure)
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

    private static func body(model: String, prompt: LanguageModelPrompt, mode: Mode) -> [String: Any] {
        var system = prompt.instructions
        var body: [String: Any] = ["model": model, "stream": false]
        switch mode {
        case .schema:
            system += "\n\nReply with a single JSON object."
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": prompt.schemaName, "schema": prompt.schema, "strict": true],
            ]
        case .promptOnly:
            system +=
                "\n\nReply with only a JSON object that matches this JSON Schema. "
                + "Add no other text and no code fence.\n\(schemaText(prompt.schema))"
        }
        body["messages"] = [
            ["role": "system", "content": system],
            ["role": "user", "content": prompt.userContent],
        ]
        return body
    }

    static func schemaText(_ schema: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    /// The text of the first choice. Some servers return the content as a list
    /// of parts rather than a string.
    static func replyText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else { return nil }
        if let text = message["content"] as? String { return text.isEmpty ? nil : text }
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private func post(_ body: [String: Any], timeout: TimeInterval? = nil) async throws -> Data {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout ?? configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try authorize(&request)
        return try await transport.send(request)
    }

    private func authorize(_ request: inout URLRequest) throws {
        for (name, value) in configuration.extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        switch configuration.provider.keyRequirement {
        case .none:
            return
        case .required:
            guard let key = try? keyProvider?.apiKey(), !key.isEmpty else {
                throw transport.failure(.authenticationFailed)
            }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .optional:
            if let key = try? keyProvider?.apiKey(), !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
    }
}
