import Foundation
import PipitCore
import PipitIntegrations
import PipitLocalAI
import PipitServices
import PipitSpeakers
import Testing

/// What a model that writes about the meeting may and may not take down with it.
@Suite("LanguageModelPipeline")
struct LanguageModelPipelineTests {
    private func pipeline(
        _ repository: MeetingRepository, backend: FakeAIBackend, settings: AppSettings, root: URL
    ) -> ProcessingPipeline {
        PipelineFixtures.makePipeline(
            repository: repository, backend: backend,
            transcriber: StubLocalTranscriber(segments: [
                RawTranscriptSegment(
                    start: 0, end: 5, text: "we ship friday", speaker: nil,
                    words: [RawTranscriptWord(start: 0, end: 2, text: " we ship friday")]
                )
            ]),
            diarizer: StubLocalDiarizer(
                intervals: [DiarizationInterval(start: 0, end: 5, clusterID: "S1")],
                chunkEmbeddings: []
            ),
            speakers: nil,
            settings: settings, scratchRoot: root.appendingPathComponent("scratch")
        )
    }

    @Test("a model server that is closed does not stop the transcript being written")
    func aModelServerThatIsClosedDoesNotStopTheTranscriptBeingWritten() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try PipelineFixtures.makeRecordedMeeting(root: root, seconds: 6)

        // Speaker names are the only thing asked for, and the server that
        // would answer is not running, which is the usual state of one on
        // this Mac.
        let backend = FakeAIBackend()
        backend.failSuggestions = .languageModel(provider: "Ollama", failure: .unreachable)
        var settings = AppSettings()
        settings.enrichment = EnrichmentSettings(
            generateTitle: false, generateDescription: false, generateNotes: false,
            generateSummary: false, suggestSpeakers: true
        )

        await pipeline(meeting.repository, backend: backend, settings: settings, root: root)
            .process(meetingID: meeting.metadata.id)

        #expect(backend.calls.contains { $0.kind == "resolve" }, "the stage was attempted")
        #expect(try meeting.store.readMetadata().processing.state == .complete)
        #expect(
            FileManager.default.fileExists(atPath: meeting.store.layout.transcriptMarkdown.path),
            "the readable transcript is written"
        )
    }

    @Test(
        "a provider with no model chosen says the stages were passed over",
        arguments: [(LanguageModelProvider.ollama, true), (LanguageModelProvider.openAI, false)]
    )
    func aProviderWithNoModelChosenSaysTheStagesWerePassedOver(
        provider: LanguageModelProvider, flagged: Bool
    ) async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try PipelineFixtures.makeRecordedMeeting(root: root, seconds: 6)

        // For OpenAI an empty identifier is a field half typed in Settings. For
        // the rest it means nothing was ever chosen.
        let backend = FakeAIBackend()
        var settings = AppSettings()
        settings.models.metadataProvider = provider
        settings.models.metadata = ""

        await pipeline(meeting.repository, backend: backend, settings: settings, root: root)
            .process(meetingID: meeting.metadata.id)

        #expect(try meeting.store.readMetadata().processing.skippedForMissingKey == flagged)
        #expect(!backend.calls.contains { $0.kind == "resolve" || $0.kind == "enrich" })
        #expect(try meeting.store.readMetadata().processing.state == .complete)
    }
}
