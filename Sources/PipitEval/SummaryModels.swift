import Foundation
import PipitCore
import PipitIntegrations

/// A model named on the command line, such as `ollama:qwen3.5:4b` or
/// `openai:gpt-6-luna`, and the client the app would use for it.
///
/// Built the way `LanguageModelFactory` builds the app's own: OpenAI as one
/// request, every other provider cut into parts when a meeting does not fit its
/// window. A score is then a score for what the app would write.
struct SummaryModel: Sendable {
    var provider: LanguageModelProvider
    var model: String
    /// For a custom endpoint, the address it answers at.
    var baseURL: URL?

    /// `provider:model`, or `custom:<base url>|<model>` for any server that
    /// speaks chat completions.
    init?(_ spec: String) {
        guard let colon = spec.firstIndex(of: ":") else { return nil }
        let name = String(spec[..<colon])
        let rest = String(spec[spec.index(after: colon)...])
        guard !rest.isEmpty else { return nil }
        switch name {
        case "openai": provider = .openAI
        case "openrouter": provider = .openRouter
        case "ollama": provider = .ollama
        case "custom":
            let parts = rest.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let url = URL(string: parts[0]) else { return nil }
            provider = .custom
            baseURL = url
            model = parts[1]
            return
        default: return nil
        }
        model = rest
    }

    /// A name for files and tables.
    var label: String {
        provider == .custom ? "custom:\(model)" : "\(provider.rawValue):\(model)"
    }

    var slug: String {
        label.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }.map(String.init).joined()
    }

    private var keys: any APIKeyProviding {
        var layers: [any APIKeyProviding] = []
        // The environment first, so a CI job's secret wins over whatever this
        // machine's keychain holds.
        if let variable = provider.environmentKeyVariable {
            layers.append(EnvironmentAPIKeyStore(variableName: variable))
        }
        layers.append(KeychainAPIKeyStore(provider: provider))
        return LayeredAPIKeyStore(providers: layers)
    }

    private func chatClient() -> ChatCompletionsClient {
        let configuration: ChatCompletionsClient.Configuration =
            provider == .openRouter
            ? .openRouter()
            : .init(provider: .custom, baseURL: baseURL ?? URL(string: "http://127.0.0.1")!)
        return ChatCompletionsClient(configuration: configuration, keyProvider: keys)
    }

    /// The client that writes the summary, as the app would build it.
    func summarizer(contextTokens: Int) -> any LanguageModelBackend {
        switch provider {
        case .openAI:
            return OpenAIClient(keyProvider: keys)
        case .ollama:
            let client = OllamaClient(configuration: .init(contextTokens: contextTokens))
            return ChunkedLanguageModel(client, contextTokens: contextTokens)
        case .openRouter, .custom:
            return ChunkedLanguageModel(chatClient(), contextTokens: contextTokens)
        }
    }

    /// The same provider asked a question of the tool's own, for judging.
    func structured(contextTokens: Int) -> any StructuredLanguageModel {
        switch provider {
        case .openAI: return OpenAIClient(keyProvider: keys)
        case .ollama: return OllamaClient(configuration: .init(contextTokens: contextTokens))
        case .openRouter, .custom: return chatClient()
        }
    }
}
