import Foundation
import PipitCore

/// Fits a long meeting into a model's context window by asking about it in
/// parts.
///
/// A meeting that fits goes through untouched. One that does not is cut between
/// lines, each part is summarised on its own, and the notes from every part are
/// combined in one last request that writes the title and the summary for the
/// whole meeting. The alternative is to send it all and let the model read the
/// end of it, or the start, or neither.
public struct ChunkedLanguageModel: LanguageModelBackend {
    private let base: any LanguageModelBackend
    private let contextTokens: Int

    /// More levels than this would mean a window too small to be useful.
    private static let maximumCombineDepth = 3

    public init(_ base: any LanguageModelBackend, contextTokens: Int) {
        self.base = base
        self.contextTokens = contextTokens
    }

    public func isConfigured() async -> Bool { await base.isConfigured() }

    public func verifyCredentials(model: String) async throws {
        try await base.verifyCredentials(model: model)
    }

    // MARK: - speakers

    public func resolveSpeakers(
        _ request: SpeakerResolutionRequest, model: String
    ) async throws -> [SpeakerSuggestion] {
        let overhead =
            (request.humanContext?.count ?? 0) + request.nameHints.joined(separator: ", ").count
            + request.labels.joined(separator: ", ").count
        let limit = ContextWindow.transcriptCharacters(
            context: contextTokens, overheadCharacters: overhead
        )
        let parts = TranscriptChunker.split(request.transcript, limit: limit)
        guard parts.count > 1 else { return try await base.resolveSpeakers(request, model: model) }
        Log.processing.info("speaker suggestions read in \(parts.count, privacy: .public) parts")

        // A name is said in one place, so each label keeps the most confident
        // answer any part gave it. The suggestion still carries the line it came
        // from, which is checked against the transcript afterwards.
        var best: [String: SpeakerSuggestion] = [:]
        for part in parts {
            var partRequest = request
            partRequest.transcript = part
            for suggestion in try await base.resolveSpeakers(partRequest, model: model) {
                if let held = best[suggestion.label], held.confidence >= suggestion.confidence { continue }
                best[suggestion.label] = suggestion
            }
        }
        return request.labels.compactMap { best[$0] }
    }

    // MARK: - enrichment

    public func enrich(_ request: EnrichmentRequest, model: String) async throws -> MeetingEnrichment {
        let folderCharacters = request.folders.reduce(0) { total, folder in
            total + folder.name.count + folder.about.count + (folder.rule?.count ?? 0)
                + folder.recentTitles.joined(separator: "; ").count
        }
        let overhead =
            (request.humanNotes?.count ?? 0) + request.participants.joined(separator: ", ").count
            + folderCharacters
        let limit = ContextWindow.transcriptCharacters(
            context: contextTokens, overheadCharacters: overhead
        )
        let parts = TranscriptChunker.split(request.transcript, limit: limit)
        guard parts.count > 1 else { return try await base.enrich(request, model: model) }
        Log.processing.info("enrichment read in \(parts.count, privacy: .public) parts")

        var notes: [String] = []
        var candidates: [ModelFolderCandidate] = []
        for (offset, part) in parts.enumerated() {
            var partRequest = request
            partRequest.transcript = part
            partRequest.source = .part(index: offset + 1, of: parts.count)
            // Each part is asked for what the combining request will read: its
            // summary, and its notes when notes were asked for. The title and the
            // description belong to the whole meeting.
            partRequest.wantsTitle = false
            partRequest.wantsDescription = false
            partRequest.wantsSummary = true
            let result = try await base.enrich(partRequest, model: model)
            notes.append(Self.digest(of: result, part: offset + 1))
            candidates.append(contentsOf: result.folderCandidates)
        }

        // The folder answers quote the transcript, so they come from the parts
        // that had it. The combining request never sees a transcript.
        var combined = try await combine(
            notes, like: request, model: model, limit: limit, depth: 0
        )
        combined.folderCandidates = Self.bestCandidates(candidates)
        return combined
    }

    /// Writes the result for the whole meeting from the notes on each part.
    private func combine(
        _ notes: [String], like request: EnrichmentRequest, model: String, limit: Int, depth: Int
    ) async throws -> MeetingEnrichment {
        let joined = notes.joined(separator: "\n\n")
        if joined.count <= limit || notes.count < 2 || depth >= Self.maximumCombineDepth {
            var final = request
            final.transcript = joined
            final.source = .partNotes(parts: notes.count)
            final.folders = []
            return try await base.enrich(final, model: model)
        }

        // Too long to read at once, so the notes are summarised in groups first.
        let groups = TranscriptChunker.split(joined, limit: limit)
        var condensed: [String] = []
        for (offset, group) in groups.enumerated() {
            var step = request
            step.transcript = group
            step.source = .partNotes(parts: groups.count)
            step.folders = []
            step.wantsTitle = false
            step.wantsDescription = false
            step.wantsSummary = true
            let result = try await base.enrich(step, model: model)
            condensed.append(Self.digest(of: result, part: offset + 1))
        }
        return try await combine(condensed, like: request, model: model, limit: limit, depth: depth + 1)
    }

    private static func digest(of result: MeetingEnrichment, part: Int) -> String {
        var lines = ["Part \(part)"]
        if let summary = result.summary, !summary.isEmpty { lines.append(summary) }
        if let notes = result.notes, !notes.isEmpty { lines.append(notes) }
        return lines.joined(separator: "\n")
    }

    /// The two most confident folders across the parts, one entry per folder.
    static func bestCandidates(_ candidates: [ModelFolderCandidate]) -> [ModelFolderCandidate] {
        var byFolder: [String: ModelFolderCandidate] = [:]
        for candidate in candidates {
            if let held = byFolder[candidate.folderName], held.confidence >= candidate.confidence { continue }
            byFolder[candidate.folderName] = candidate
        }
        return byFolder.values.sorted { $0.confidence > $1.confidence }.prefix(2).map { $0 }
    }
}
