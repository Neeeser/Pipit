import Foundation

/// The service that reads a transcript and writes about it: titles, summaries,
/// notes and speaker suggestions.
///
/// Transcription and diarization are a separate choice, made on the Processing
/// page. Adding a provider is one case here, one case in `LanguageModelFactory`,
/// and a row in Settings that already iterates `allCases`.
public enum LanguageModelProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case openAI = "openai"
    case openRouter = "openrouter"
    case ollama
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .ollama: "Ollama"
        case .custom: "Custom endpoint"
        }
    }

    public var blurb: String {
        switch self {
        case .openAI: "GPT models from OpenAI"
        case .openRouter: "One key for hundreds of hosted models"
        case .ollama: "Models running on this Mac"
        case .custom: "Any OpenAI-compatible server"
        }
    }

    /// The request format the provider speaks.
    public enum Wire: Sendable, Equatable {
        /// OpenAI's responses endpoint, which the OpenAI client has always used.
        case openAIResponses
        /// `POST {base}/chat/completions`, which OpenRouter, LM Studio, vLLM,
        /// llama.cpp and most hosted gateways accept.
        case chatCompletions
        /// Ollama's own chat endpoint. The compatible one cannot size the
        /// context window, and a prompt past the default is cut short without
        /// an error.
        case ollamaChat
    }

    public var wire: Wire {
        switch self {
        case .openAI: .openAIResponses
        case .openRouter, .custom: .chatCompletions
        case .ollama: .ollamaChat
        }
    }

    public enum KeyRequirement: Sendable, Equatable {
        case required
        /// A server on a home network often takes none, and a gateway may.
        case optional
        case none
    }

    public var keyRequirement: KeyRequirement {
        switch self {
        case .openAI, .openRouter: .required
        case .custom: .optional
        case .ollama: .none
        }
    }

    /// Whether Settings shows a key field at all.
    public var acceptsKey: Bool { keyRequirement != .none }

    public var keyPlaceholder: String {
        switch self {
        case .openAI: "sk-…"
        case .openRouter: "sk-or-…"
        case .custom: "Optional"
        case .ollama: ""
        }
    }

    /// The Keychain service the key is stored under. OpenAI keeps the service it
    /// has always used, so an existing key is found without a migration.
    public var keychainService: String {
        switch self {
        case .openAI: "com.pipit.app.openai"
        case .openRouter: "com.pipit.app.openrouter"
        case .custom: "com.pipit.app.custom-endpoint"
        case .ollama: ""
        }
    }

    /// A variable that supplies the key in a debug build, as `OPENAI_API_KEY`
    /// does for OpenAI.
    public var environmentKeyVariable: String? {
        switch self {
        case .openAI: "OPENAI_API_KEY"
        case .openRouter: "OPENROUTER_API_KEY"
        case .custom, .ollama: nil
        }
    }

    /// Where the provider lives. Empty for a custom endpoint, which is typed.
    public var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .ollama: "http://127.0.0.1:11434"
        case .custom: ""
        }
    }

    /// Whether Settings offers the context window slider. The hosted providers
    /// publish a window per model, so there is nothing to ask.
    public var choosesContextWindow: Bool {
        switch self {
        case .ollama, .custom: true
        case .openAI, .openRouter: false
        }
    }

    /// The model used before one is chosen. Only OpenAI has a sensible answer.
    public var defaultModel: String {
        switch self {
        case .openAI: AIModelSettings.defaultMetadataModel
        case .openRouter, .ollama, .custom: ""
        }
    }

    /// The window assumed before one is chosen or read from the model.
    ///
    /// Small for the providers that run a model on hardware the person owns,
    /// where a bigger window costs memory. Large for OpenRouter, whose models
    /// mostly offer far more than a transcript needs, and which Settings sets
    /// from the model's own figure once one is picked.
    public var defaultContextTokens: Int {
        switch self {
        case .ollama, .custom: ContextWindow.defaultTokens
        case .openAI, .openRouter: ContextWindow.hostedDefaultTokens
        }
    }
}

/// What a person typed or picked for one provider.
public struct LanguageModelChoice: Codable, Sendable, Equatable {
    public var model: String
    public var contextTokens: Int?

    public init(model: String = "", contextTokens: Int? = nil) {
        self.model = model
        self.contextTokens = contextTokens
    }

    /// An absent key keeps its default instead of discarding the choice.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        contextTokens = try container.decodeIfPresent(Int.self, forKey: .contextTokens)
    }
}

/// Reads the address a person types for a custom endpoint.
public enum EndpointAddress {
    /// The base URL a pasted address means, or nil when it is not a web address.
    ///
    /// People paste whatever their server printed: the root, the `/v1` base, or
    /// the full path of the chat call. All three name the same server. A bare
    /// host gets `/v1`, which is where the servers that matter put the API.
    public static func normalized(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        for suffix in ["/chat/completions", "/models"] where trimmed.hasSuffix(suffix) {
            trimmed.removeLast(suffix.count)
        }
        guard var components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else { return nil }
        if components.path.isEmpty { components.path = "/v1" }
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
