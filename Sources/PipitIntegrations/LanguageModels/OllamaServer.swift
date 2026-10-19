import Foundation
import PipitCore

/// One model Ollama has downloaded.
public struct OllamaModel: Sendable, Equatable, Identifiable {
    public var name: String
    public var sizeBytes: Int64
    /// "8.0B", as Ollama reports it.
    public var parameterSize: String?
    /// "Q4_K_M".
    public var quantization: String?

    public var id: String { name }

    public init(name: String, sizeBytes: Int64, parameterSize: String? = nil, quantization: String? = nil) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.parameterSize = parameterSize
        self.quantization = quantization
    }
}

/// Ollama on this Mac: whether it is there, whether it is running, and what it
/// holds.
public struct OllamaServer: Sendable {
    public enum Status: Sendable, Equatable {
        /// Answering, with the models it has.
        case running(models: [OllamaModel])
        /// On disk but not answering.
        case installedNotRunning
        case notInstalled
    }

    public static let defaultBaseURL = URL(string: LanguageModelProvider.ollama.defaultBaseURL)!

    /// Where Ollama puts itself: the app, and the command line tool that the
    /// app or Homebrew installs.
    public static var installLocations: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications/Ollama.app"),
            home.appendingPathComponent("Applications/Ollama.app"),
            URL(fileURLWithPath: "/usr/local/bin/ollama"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ollama"),
        ]
    }

    private let baseURL: URL
    private let session: URLSession
    private let installLocations: [URL]

    public init(
        baseURL: URL = OllamaServer.defaultBaseURL, session: URLSession = .shared,
        installLocations: [URL] = OllamaServer.installLocations
    ) {
        self.baseURL = baseURL
        self.session = session
        self.installLocations = installLocations
    }

    /// The app, when it is installed as one, so Settings can open it.
    public var applicationURL: URL? {
        installLocations.first { $0.pathExtension == "app" && FileManager.default.fileExists(atPath: $0.path) }
    }

    public func status() async -> Status {
        if let models = try? await models() { return .running(models: models) }
        let installed = installLocations.contains { FileManager.default.fileExists(atPath: $0.path) }
        return installed ? .installedNotRunning : .notInstalled
    }

    /// The downloaded models, by name.
    public func models() async throws -> [OllamaModel] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        // A server on this Mac answers at once or not at all.
        request.timeoutInterval = 3
        let transport = LanguageModelTransport(provider: .ollama, session: session)
        let data = try await transport.send(request)
        return Self.parseModels(data)
    }

    /// The most context the model itself supports, read from its description.
    /// Nil when Ollama does not say.
    public func maximumContext(of model: String) async -> Int? {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/show"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        let transport = LanguageModelTransport(provider: .ollama, session: session)
        guard let data = try? await transport.send(request) else { return nil }
        return Self.parseMaximumContext(data)
    }

    static func parseModels(_ data: Data) -> [OllamaModel] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = object["models"] as? [[String: Any]]
        else { return [] }
        return models.compactMap { entry -> OllamaModel? in
            guard let name = (entry["name"] as? String) ?? (entry["model"] as? String), !name.isEmpty
            else { return nil }
            let details = entry["details"] as? [String: Any]
            return OllamaModel(
                name: name,
                sizeBytes: Int64(Self.integer(entry["size"]) ?? 0),
                parameterSize: details?["parameter_size"] as? String,
                quantization: details?["quantization_level"] as? String
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The architecture names its own key ("llama.context_length",
    /// "qwen3.context_length"), so the one that ends that way is the one.
    static func parseMaximumContext(_ data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let info = object["model_info"] as? [String: Any]
        else { return nil }
        for (key, value) in info where key.hasSuffix(".context_length") {
            if let tokens = integer(value), tokens > 0 { return tokens }
        }
        return nil
    }

    /// A JSON number as the integer it is, whichever type the decoder gave it.
    static func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Int64 { return Int(number) }
        if let number = value as? Double { return Int(number) }
        return (value as? NSNumber)?.intValue
    }

    /// Whether `name` is among `models`. A name typed without a tag means the
    /// latest, which is how Ollama reads it too.
    public static func hasModel(_ name: String, in models: [OllamaModel]) -> Bool {
        let wanted = name.contains(":") ? name : "\(name):latest"
        return models.contains { $0.name == wanted || $0.name == name }
    }
}
