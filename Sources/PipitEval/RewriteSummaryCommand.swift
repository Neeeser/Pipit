import Foundation
import PipitCore
import PipitIntegrations
import PipitServices

/// Writes one meeting's summary and notes again with the current prompt.
///
/// For seeing what a prompt change does to real meetings without waiting for
/// new ones. The request is built the way the app builds it, and only
/// `summary.md` and `raw/summary.json` are written, after a copy of both goes
/// to the backups folder. Titles, descriptions, folders and every other file
/// are left as they are.
enum RewriteSummaryCommand {
    static func run(meeting folder: URL, model spec: String, backups: URL) async -> Int32 {
        guard let model = SummaryModel(spec) else {
            note("rewrite-summary: --model is provider:model, such as openai:gpt-6-luna")
            return 2
        }
        let store = MeetingStore(layout: MeetingLayout(root: folder))
        let metadata: MeetingMetadata
        do {
            metadata = try store.readMetadata()
        } catch {
            note("rewrite-summary: cannot read \(folder.path): \(error)")
            return 1
        }
        var settings = AppSettings()
        settings.enrichment.generateTitle = false
        settings.enrichment.generateDescription = false
        settings.enrichment.generateSummary = true
        settings.enrichment.generateNotes = true

        do {
            guard
                let request = try ProcessingPipeline.enrichmentRequest(
                    store: store, metadata: metadata, settings: settings, folders: []
                )
            else {
                note("rewrite-summary: \(metadata.id) has no transcript yet")
                return 1
            }
            let backup = Reprocessing.backupDirectory(under: backups, meetingID: metadata.id, at: Date())
            try Reprocessing.backUp(
                store: store, files: [store.layout.summary, store.layout.structuredSummary], to: backup
            )

            let started = Date()
            let result = try await model.summarizer(contextTokens: ContextWindow.defaultTokens)
                .enrich(request, model: model.model)
            guard let structure = result.generatedSummary else {
                note("rewrite-summary: the model's answer held no summary; nothing was written")
                return 1
            }
            let document = SummaryDocument(summary: result.summary, generatedNotes: result.notes)
            try store.writeSummary(document.markdown, structure: structure)
            print(
                String(
                    format: "%@  %.0fs  %d topics, %d action items, %d of them questions",
                    metadata.id, Date().timeIntervalSince(started), structure.topics.count,
                    structure.actionItems.count, structure.actionItems.filter(\.isQuestion).count))
            print("  previous files in \(backup.path)")
            return 0
        } catch {
            note("rewrite-summary: \(metadata.id) failed: \(error)")
            return 1
        }
    }
}
