import Foundation
import PipitCore
import PipitIntegrations

/// Proposes which of a model's items say the same thing as an answer key's.
///
/// Similarity of sentence embeddings finds items about the same subject. It
/// cannot tell "the remote is for the TV only" from "one universal remote",
/// so when the run has a judge, every proposed pair goes to it to confirm, and
/// only confirmed pairs count. Without a judge the proposals count as they are.
///
/// Time is a tie-break rather than a gate: a decision is often restated in the
/// recap at the end, and a model citing the recap still found it.
final class SummaryMatcher: @unchecked Sendable {
    /// Similarity at or above which two items are proposed as the same item.
    /// Set low enough that a reworded match is proposed, since the judge
    /// removes the pairs that only share a subject.
    static let threshold = 0.55
    /// How close, in seconds, a model's time has to be to the key's to count
    /// as pointing at the same moment.
    static let nearSeconds = 60.0

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
        let embedded = try await embedder.embed(missing)
        guard embedded.count == missing.count else {
            throw SummaryEmbedder.Failure(
                message: "the embedder returned \(embedded.count) vectors for \(missing.count) texts")
        }
        for (text, vector) in zip(missing, embedded) { vectors[text] = vector }
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

    /// Every pair that clears the threshold, strongest first, with the time
    /// tie-break folded into the order.
    func proposals(
        truth: [(text: String, at: Double?)], candidates: [(text: String, at: Double?)]
    ) -> [SummaryEvalCommand.Pair] {
        var pairs: [(pair: SummaryEvalCommand.Pair, rank: Double)] = []
        for (truthIndex, key) in truth.enumerated() {
            for (candidateIndex, item) in candidates.enumerated() {
                let value = similarity(key.text, item.text)
                guard value >= Self.threshold else { continue }
                let rank = value + (Self.isNear(key.at, item.at) ? 0.05 : 0)
                pairs.append((.init(truth: truthIndex, candidate: candidateIndex, similarity: value), rank))
            }
        }
        return pairs.sorted { $0.rank > $1.rank }.map(\.pair)
    }

    /// One to one, taking the strongest pairs first.
    static func assign(_ proposals: [SummaryEvalCommand.Pair]) -> [SummaryEvalCommand.Pair] {
        var takenTruth = Set<Int>()
        var takenCandidates = Set<Int>()
        var pairs: [SummaryEvalCommand.Pair] = []
        for pair in proposals where !takenTruth.contains(pair.truth) && !takenCandidates.contains(pair.candidate) {
            takenTruth.insert(pair.truth)
            takenCandidates.insert(pair.candidate)
            pairs.append(pair)
        }
        return pairs
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

/// Turns item text into vectors on this Mac: a Hugging Face model's ONNX
/// export run by `scripts/embed-texts.py`, or a model served by Ollama.
struct SummaryEmbedder: Sendable {
    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    enum Source: Sendable {
        /// A Hugging Face model id, run by the repository's script.
        case local(String)
        case ollama(String)
    }

    let source: Source

    /// `local:<hugging face id>` or `ollama:<model>`.
    init?(_ spec: String) {
        guard let colon = spec.firstIndex(of: ":") else { return nil }
        let model = String(spec[spec.index(after: colon)...])
        guard !model.isEmpty else { return nil }
        switch spec[..<colon] {
        case "local": source = .local(model)
        case "ollama": source = .ollama(model)
        default: return nil
        }
    }

    var label: String {
        switch source {
        case .local(let model): "local:\(model)"
        case .ollama(let model): "ollama:\(model)"
        }
    }

    var slug: String {
        label.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }.map(String.init).joined()
    }

    func embed(_ texts: [String]) async throws -> [[Double]] {
        switch source {
        case .local(let model): return try await runScript(model: model, texts: texts)
        case .ollama(let model): return try await askOllama(model: model, texts: texts)
        }
    }

    /// Runs the script through uv, which installs its few dependencies on
    /// first use. Run from the repository root, as `scripts/eval.sh` does.
    private func runScript(model: String, texts: [String]) async throws -> [[Double]] {
        let script = URL(fileURLWithPath: "scripts/embed-texts.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw Failure(message: "run from the repository root: scripts/embed-texts.py is not here")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["uv", "run", "--quiet", script.path]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let request = try JSONSerialization.data(withJSONObject: ["model": model, "texts": texts])
        // Written from another task, so a large request cannot fill the pipe
        // while this one waits on the output.
        let writer = Task.detached {
            input.fileHandleForWriting.write(request)
            try? input.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let failure = errors.fileHandleForReading.readDataToEndOfFile()
        await writer.value
        process.waitUntilExit()
        guard process.terminationStatus == 0,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let vectors = object["embeddings"] as? [[Double]]
        else {
            let detail = String(bytes: failure.suffix(400), encoding: .utf8) ?? ""
            throw Failure(message: "embed-texts.py failed: \(detail)")
        }
        return vectors
    }

    private func askOllama(model: String, texts: [String]) async throws -> [[Double]] {
        var request = URLRequest(url: OllamaServer.defaultBaseURL.appendingPathComponent("api/embed"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "input": texts])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let vectors = object["embeddings"] as? [[Double]]
        else {
            throw Failure(message: "Ollama embedding failed: \(String(bytes: data.prefix(300), encoding: .utf8) ?? "")")
        }
        return vectors
    }
}
