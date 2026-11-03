import Foundation
import PipitCore
import PipitIntegrations

/// Pairs a model's items with the answer key's, one to one, without a judge.
///
/// Two items match when they say the same thing, measured as the cosine
/// similarity of their embeddings. Apple's on-device sentence embeddings were
/// tried first and could not tell a reworded item from a different one, so the
/// embedding model is named like any other model: OpenAI's small embedding
/// model by default, or one served by Ollama to stay on this Mac.
///
/// Time is a tie-break rather than a gate: a decision is often restated in the
/// recap at the end, and a model citing the recap still found it.
final class SummaryMatcher: @unchecked Sendable {
    /// Similarity at or above which two items count as the same item. Checked
    /// by reading the pairs either side of it, which every run writes to
    /// `near-misses.txt`.
    static let threshold = 0.55
    /// How close, in seconds, a model's time has to be to the key's to count
    /// as pointing at the same moment.
    static let nearSeconds = 60.0

    struct Pair: Codable, Sendable {
        var truth: Int
        var candidate: Int
        var similarity: Double
    }

    private let embedder: SummaryEmbedder
    private var vectors: [String: [Double]] = [:]
    private let cache: URL?

    init(embedder: SummaryEmbedder, cache: URL?) {
        self.embedder = embedder
        self.cache = cache
        if let cache, let data = try? Data(contentsOf: cache),
            let stored = try? JSONDecoder().decode([String: [Double]].self, from: data)
        {
            vectors = stored
        }
    }

    /// Embeds every text not seen before, in one request.
    func prepare(_ texts: [String]) async throws {
        let missing = Array(Set(texts.filter { vectors[$0] == nil }))
        guard !missing.isEmpty else { return }
        for (text, vector) in zip(missing, try await embedder.embed(missing)) { vectors[text] = vector }
        if let cache {
            try? FileManager.default.createDirectory(
                at: cache.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? JSONEncoder().encode(vectors).write(to: cache, options: .atomic)
        }
    }

    /// Cosine similarity of two prepared texts; zero for one never prepared.
    func similarity(_ left: String, _ right: String) -> Double {
        guard let a = vectors[left], let b = vectors[right] else { return 0 }
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for (x, y) in zip(a, b) {
            dot += x * y
            normA += x * x
            normB += y * y
        }
        return normA == 0 || normB == 0 ? 0 : dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// The best one-to-one pairing, strongest first, of the pairs that clear
    /// the threshold.
    func match(
        truth: [(text: String, at: Double?)], candidates: [(text: String, at: Double?)]
    ) -> [Pair] {
        var scored: [(pair: Pair, rank: Double)] = []
        for (truthIndex, key) in truth.enumerated() {
            for (candidateIndex, item) in candidates.enumerated() {
                let value = similarity(key.text, item.text)
                guard value >= Self.threshold else { continue }
                let rank = value + (Self.isNear(key.at, item.at) ? 0.05 : 0)
                scored.append((Pair(truth: truthIndex, candidate: candidateIndex, similarity: value), rank))
            }
        }
        var takenTruth = Set<Int>()
        var takenCandidates = Set<Int>()
        var pairs: [Pair] = []
        for entry in scored.sorted(by: { $0.rank > $1.rank }) {
            guard !takenTruth.contains(entry.pair.truth), !takenCandidates.contains(entry.pair.candidate) else {
                continue
            }
            takenTruth.insert(entry.pair.truth)
            takenCandidates.insert(entry.pair.candidate)
            pairs.append(entry.pair)
        }
        return pairs.sorted { $0.truth < $1.truth }
    }

    /// The closest pairs either side of the threshold that the pairing did not
    /// take, for checking the threshold by reading them.
    func nearMisses(
        truth: [String], candidates: [String], matched: [Pair], limit: Int
    ) -> [(truth: String, candidate: String, similarity: Double)] {
        let usedTruth = Set(matched.map(\.truth))
        let usedCandidates = Set(matched.map(\.candidate))
        var misses: [(String, String, Double)] = []
        for (truthIndex, key) in truth.enumerated() where !usedTruth.contains(truthIndex) {
            for (candidateIndex, item) in candidates.enumerated() where !usedCandidates.contains(candidateIndex) {
                let value = similarity(key, item)
                if value >= Self.threshold - 0.15 { misses.append((key, item, value)) }
            }
        }
        return misses.sorted { $0.2 > $1.2 }.prefix(limit).map { (truth: $0.0, candidate: $0.1, similarity: $0.2) }
    }

    static func isNear(_ left: Double?, _ right: Double?) -> Bool {
        guard let left, let right else { return false }
        return abs(left - right) <= nearSeconds
    }

    /// Whether two owners name the same people, in any order: the key writes
    /// a shared task as "A and B".
    static func sameOwner(_ left: String, _ right: String) -> Bool {
        func people(_ text: String) -> Set<String> {
            Set(
                text.lowercased()
                    .replacingOccurrences(of: " and ", with: ",")
                    .replacingOccurrences(of: "&", with: ",")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && $0 != "the" }
            )
        }
        return people(left) == people(right)
    }
}

/// Turns item text into vectors through a provider's embeddings endpoint.
struct SummaryEmbedder: Sendable {
    let model: SummaryModel

    init?(_ spec: String) {
        guard let model = SummaryModel(spec), model.provider == .openAI || model.provider == .ollama else {
            return nil
        }
        self.model = model
    }

    func embed(_ texts: [String]) async throws -> [[Double]] {
        var request: URLRequest
        let body: [String: Any]
        switch model.provider {
        case .ollama:
            request = URLRequest(url: OllamaServer.defaultBaseURL.appendingPathComponent("api/embed"))
            body = ["model": model.model, "input": texts]
        default:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/embeddings")!)
            let key = try LayeredAPIKeyStore(providers: [
                EnvironmentAPIKeyStore(variableName: "OPENAI_API_KEY"), KeychainAPIKeyStore(provider: .openAI),
            ]).apiKey()
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = ["model": model.model, "input": texts]
        }
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CocoaError(
                .fileReadCorruptFile,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "embedding request failed: \(String(bytes: data.prefix(300), encoding: .utf8) ?? "")"
                ]
            )
        }
        // Ollama answers with `embeddings`, OpenAI with `data[].embedding`, in
        // the order the texts were sent.
        if let vectors = object["embeddings"] as? [[Double]] { return vectors }
        if let rows = object["data"] as? [[String: Any]] {
            return rows.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
                .compactMap { $0["embedding"] as? [Double] }
        }
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "no embeddings in the answer"])
    }
}
