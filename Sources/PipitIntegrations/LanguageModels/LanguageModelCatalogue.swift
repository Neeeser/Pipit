import Foundation
import PipitCore

/// One model a server offers.
public struct LanguageModelOption: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// The most the model reads at once, when the server says.
    public var contextTokens: Int?
    /// US dollars per million tokens, when the server says.
    public var promptPrice: Double?
    public var completionPrice: Double?

    public init(
        id: String, name: String, contextTokens: Int? = nil, promptPrice: Double? = nil,
        completionPrice: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.contextTokens = contextTokens
        self.promptPrice = promptPrice
        self.completionPrice = completionPrice
    }

    public var isFree: Bool {
        if id.hasSuffix(":free") { return true }
        guard let promptPrice, let completionPrice else { return false }
        return promptPrice == 0 && completionPrice == 0
    }
}

/// The models a server lists at `{base}/models`.
///
/// Every server that speaks chat completions lists its models there with an
/// `id`. OpenRouter adds a name, the context length, the price and what the
/// model reads and writes, and the extras are used when they are present.
public struct LanguageModelCatalogue: Sendable {
    private let baseURL: URL
    private let keyProvider: (any APIKeyProviding)?
    private let transport: LanguageModelTransport

    public init(
        provider: LanguageModelProvider, baseURL: URL, keyProvider: (any APIKeyProviding)?,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.keyProvider = keyProvider
        self.transport = LanguageModelTransport(provider: provider, session: session)
    }

    public func fetch() async throws -> [LanguageModelOption] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        if let key = try? keyProvider?.apiKey(), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let data = try await transport.send(request)
        return Self.parse(data)
    }

    /// Models that write text, by name. Ones that only produce images or audio
    /// are left out when the server says what a model produces.
    public static func parse(_ data: Data) -> [LanguageModelOption] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = object["data"] as? [[String: Any]]
        else { return [] }

        var seen = Set<String>()
        var options: [LanguageModelOption] = []
        for entry in entries {
            guard let id = entry["id"] as? String, !id.isEmpty, seen.insert(id).inserted else { continue }
            if let outputs = (entry["architecture"] as? [String: Any])?["output_modalities"] as? [String],
                !outputs.contains("text")
            {
                continue
            }
            let pricing = entry["pricing"] as? [String: Any]
            let topProvider = entry["top_provider"] as? [String: Any]
            options.append(
                LanguageModelOption(
                    id: id,
                    name: (entry["name"] as? String) ?? id,
                    contextTokens: OllamaServer.integer(entry["context_length"])
                        ?? OllamaServer.integer(topProvider?["context_length"]),
                    promptPrice: perMillion(pricing?["prompt"]),
                    completionPrice: perMillion(pricing?["completion"])
                ))
        }
        return options.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Prices are listed per token, as text.
    private static func perMillion(_ value: Any?) -> Double? {
        let perToken: Double?
        if let text = value as? String {
            perToken = Double(text)
        } else {
            perToken = value as? Double
        }
        return perToken.map { $0 * 1_000_000 }
    }
}
