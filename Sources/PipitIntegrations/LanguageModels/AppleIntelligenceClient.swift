import Foundation
import FoundationModels
import PipitCore

/// Whether Apple's on-device model can be used on this Mac, and if not, why.
///
/// Asked without an availability check of its own, so the provider list,
/// Settings and the first-launch default can all ask on any macOS.
public enum AppleIntelligenceAvailability: Sendable, Hashable {
    case available
    case needsNewerMacOS
    case deviceNotEligible
    case notEnabled
    case modelNotReady

    public static var current: AppleIntelligenceAvailability {
        guard #available(macOS 27.0, *) else { return .needsNewerMacOS }
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
        case .unavailable(.modelNotReady): return .modelNotReady
        @unknown default: return .modelNotReady
        }
    }
}

/// Writes about a meeting with Apple's Foundation Models: the model on this Mac,
/// or Apple's server model through Private Cloud Compute.
///
/// The on-device window is small (8,192 tokens on macOS 27), so the app wraps
/// this in `ChunkedLanguageModel` with `LanguageModelProvider.appleContextTokens`.
/// Each request opens a new session, because a session keeps its transcript and
/// a second request in the same one would carry the first meeting part along
/// with it. macOS 27 is the floor because reading Pipit's JSON schemas into a
/// `GenerationSchema` and the Private Cloud Compute model both arrived there.
@available(macOS 27.0, *)
public struct AppleIntelligenceClient: LanguageModelBackend, StructuredLanguageModel {
    public enum Model: String, Sendable {
        case onDevice = "on-device"
        case privateCloud = "private-cloud"
    }

    private let model: Model

    public init(model: Model) {
        self.model = model
    }

    private func languageModel() -> any LanguageModel {
        switch model {
        case .onDevice: SystemLanguageModel.default
        case .privateCloud: PrivateCloudComputeLanguageModel()
        }
    }

    public func isConfigured() async -> Bool {
        switch model {
        case .onDevice: SystemLanguageModel.default.isAvailable
        case .privateCloud: PrivateCloudComputeLanguageModel().isAvailable
        }
    }

    public func verifyCredentials(model: String) async throws {
        guard await isConfigured() else { throw Self.failure(.unreachable) }
    }

    public func resolveSpeakers(
        _ request: SpeakerResolutionRequest, model: String
    ) async throws -> [SpeakerSuggestion] {
        let prompt = LanguageModelPrompts.speakerResolution(request)
        let object = try await answer(to: prompt)
        return LanguageModelPrompts.speakerSuggestions(from: object, labels: request.labels) ?? []
    }

    public func enrich(_ request: EnrichmentRequest, model: String) async throws -> MeetingEnrichment {
        guard let prompt = LanguageModelPrompts.enrichment(request) else { return MeetingEnrichment() }
        let object = try await answer(to: prompt)
        return LanguageModelPrompts.enrichment(from: object, for: request)
    }

    public func structuredAnswer(_ prompt: LanguageModelPrompt, model: String) async throws -> Data {
        try JSONSerialization.data(withJSONObject: try await answer(to: prompt))
    }

    /// Guided generation holds the model to the schema while it writes, which a
    /// small model needs to return valid JSON. A schema the framework cannot
    /// read falls back to asking for JSON in words.
    ///
    /// About one meeting in five in the benchmark had a part whose answer ran
    /// past the 8,192-token window. Asked again in a fresh session, which
    /// samples differently, each of those parts came back whole.
    private func answer(to prompt: LanguageModelPrompt) async throws -> [String: Any] {
        do {
            return try await guidedAnswer(to: prompt)
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.failure(Self.failure(of: error))
        }
    }

    private func guidedAnswer(to prompt: LanguageModelPrompt) async throws -> [String: Any] {
        if let schema = try? Self.generationSchema(prompt.schema) {
            for attempt in 1...Self.attempts {
                let session = LanguageModelSession(model: languageModel(), instructions: prompt.instructions)
                do {
                    let response = try await session.respond(to: prompt.userContent, schema: schema)
                    if let object = ModelJSON.object(from: response.content.jsonString) { return object }
                } catch let error as LanguageModelSession.GenerationError where attempt < Self.attempts {
                    Log.processing.info(
                        "apple model answer failed (\(String(describing: type(of: error)), privacy: .public)), asking again"
                    )
                }
            }
        }
        let fallback = LanguageModelSession(
            model: languageModel(),
            instructions: prompt.instructions
                + "\n\nReply with only a JSON object that matches this JSON Schema. "
                + "Add no other text and no code fence.\n\(ChatCompletionsClient.schemaText(prompt.schema))"
        )
        let text = try await fallback.respond(to: prompt.userContent).content
        guard let object = ModelJSON.object(from: text) else { throw Self.failure(.unexpectedResponse) }
        return object
    }

    /// The framework's errors in the terms every provider's failures use, so a
    /// meeting says what went wrong and whether a retry would help.
    static func failure(of error: LanguageModelSession.GenerationError) -> LanguageModelFailure {
        switch error {
        case .assetsUnavailable: .unreachable
        case .rateLimited, .concurrentRequests: .rateLimited(retryAfter: nil)
        case .guardrailViolation, .refusal, .unsupportedLanguageOrLocale: .rejected(status: 0)
        default: .unexpectedResponse
        }
    }

    private static func failure(_ failure: LanguageModelFailure) -> ProcessingError {
        .languageModel(provider: LanguageModelProvider.appleIntelligence.displayName, failure: failure)
    }

    static let attempts = 2

    static func generationSchema(_ schema: [String: Any]) throws -> GenerationSchema {
        let data = try RequestJSON.data(schema)
        return try JSONDecoder().decode(GenerationSchema.self, from: data)
    }
}
