import Foundation
import PipitCore

/// The client for the provider the settings name.
public enum LanguageModelFactory {
    /// `openAI` is the client that also does the audio work, so the pipeline
    /// that was handed one keeps using it. `keys` supplies the stored key for a
    /// provider that takes one.
    public static func make(
        models: AIModelSettings,
        openAI: any LanguageModelBackend,
        keys: (LanguageModelProvider) -> (any APIKeyProviding)?,
        session: URLSession = .shared
    ) -> any LanguageModelBackend {
        let provider = models.metadataProvider
        let context = models.metadataContextTokens
        switch provider {
        case .openAI:
            return openAI
        case .openRouter:
            let client = ChatCompletionsClient(
                configuration: .openRouter(), keyProvider: keys(.openRouter), session: session
            )
            return ChunkedLanguageModel(client, contextTokens: context)
        case .ollama:
            let client = OllamaClient(
                configuration: OllamaClient.Configuration(contextTokens: context), session: session
            )
            return ChunkedLanguageModel(client, contextTokens: context)
        case .custom:
            guard let baseURL = EndpointAddress.normalized(models.customEndpoint) else {
                return UnconfiguredLanguageModel(provider: .custom)
            }
            let client = ChatCompletionsClient(
                configuration: ChatCompletionsClient.Configuration(provider: .custom, baseURL: baseURL),
                keyProvider: keys(.custom), session: session
            )
            return ChunkedLanguageModel(client, contextTokens: context)
        }
    }
}

/// Stands in for a provider that has no address yet. It reports itself not
/// configured, so the stages that would use it are passed over; asking it to
/// do anything anyway fails as an unreachable server.
public struct UnconfiguredLanguageModel: LanguageModelBackend {
    private let provider: LanguageModelProvider

    public init(provider: LanguageModelProvider) {
        self.provider = provider
    }

    public func isConfigured() async -> Bool { false }

    public func verifyCredentials(model: String) async throws { throw unreachable }

    public func resolveSpeakers(
        _ request: SpeakerResolutionRequest, model: String
    ) async throws -> [SpeakerSuggestion] { throw unreachable }

    public func enrich(_ request: EnrichmentRequest, model: String) async throws -> MeetingEnrichment {
        throw unreachable
    }

    private var unreachable: ProcessingError {
        .languageModel(provider: provider.displayName, failure: .unreachable)
    }
}
