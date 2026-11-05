import Foundation
import PipitCore
import PipitIntegrations
import PipitLocalAI
import PipitServices
import Synchronization
import Testing

/// Writing a conversation's summary again after recordings were linked: when
/// it waits, what it reads, and that a failure leaves the meeting finished.
@Suite("ConversationSummaryRewrite")
struct ConversationSummaryRewriteTests {
    private static let base = Date(timeIntervalSince1970: 1_787_070_000)

    /// Two recordings an hour apart, both with words, the second linked under
    /// the first the way `combine` links it.
    private static func makeLinkedPair(
        root: URL, secondState: ProcessingState = .complete
    ) throws -> (repository: MeetingRepository, ids: [String], stores: [MeetingStore]) {
        let words = ["opening budget question", "closing hiring answer"]
        let made = try words.enumerated().map { index, text in
            try RuntimeFixtures.makeMeeting(
                root: root, clusters: ["remote-001_speaker_00"], words: text, title: "Part \(index)",
                startedAt: base.addingTimeInterval(Double(index) * 3_600))
        }
        _ = try made[0].store.updateMetadata { $0.absorbedMeetingIDs = [made[1].id] }
        _ = try made[1].store.updateMetadata {
            $0.mergedIntoMeetingID = made[0].id
            $0.processing = ProcessingStatus(state: secondState, updatedAt: base)
        }
        return (
            MeetingRepository(root: root.appendingPathComponent("Meetings")), made.map(\.id),
            made.map(\.store)
        )
    }

    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ id: String) { lock.withLock { ids.append(id) } }
        var all: [String] { lock.withLock { ids } }
    }

    private static func makePipeline(
        repository: MeetingRepository, backend: FakeAIBackend, failures: Failures = Failures()
    ) -> ProcessingPipeline {
        ProcessingPipeline(
            repository: repository, backend: backend, clock: ManualClock(),
            settingsProvider: { AppSettings() },
            onFailure: { id, _ in failures.add(id) },
            wait: { _ in })
    }

    @Test("a rewrite asked while a recording is processing is written when that recording ends")
    func owedRewriteIsPaidWhenTheRecordingEnds() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pair = try Self.makeLinkedPair(root: root, secondState: .transcribing)
        let backend = FakeAIBackend()
        let pipeline = Self.makePipeline(repository: pair.repository, backend: backend)

        await pipeline.refreshConversationSummary(meetingID: pair.ids[0])
        #expect(backend.enrichmentRequests.isEmpty, "nothing is asked while a part is still being processed")

        // The part finishes; the job that ran it ends by asking for what is owed.
        _ = try pair.stores[1].updateMetadata {
            $0.processing = ProcessingStatus(state: .complete, updatedAt: Self.base)
        }
        await pipeline.process(meetingID: pair.ids[1])

        let request = try #require(backend.enrichmentRequests.last)
        #expect(request.transcript.contains("opening budget question"))
        #expect(request.transcript.contains("closing hiring answer"))
        #expect(pair.stores[0].readSummaryDocument().summary == "Discussed retrieval.")
    }

    @Test("a change made while a rewrite is in flight is written afterwards, from the conversation as it is then")
    func askDuringARewriteIsPaidAfterIt() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pair = try Self.makeLinkedPair(root: root)
        let backend = FakeAIBackend()
        let open = Mutex(false)
        backend.enrichInterference = {
            while !open.withLock({ $0 }) { try? await Task.sleep(nanoseconds: 2_000_000) }
        }
        let pipeline = Self.makePipeline(repository: pair.repository, backend: backend)
        let first = Task { await pipeline.refreshConversationSummary(meetingID: pair.ids[0]) }
        while backend.enrichmentRequests.isEmpty { try await Task.sleep(nanoseconds: 2_000_000) }

        // The second recording is separated while the model is still reading
        // both, and the person's change asks again.
        _ = try pair.stores[0].updateMetadata { $0.absorbedMeetingIDs = [] }
        _ = try pair.stores[1].updateMetadata { $0.mergedIntoMeetingID = nil }
        await pipeline.refreshConversationSummary(meetingID: pair.ids[0])
        #expect(backend.enrichmentRequests.count == 1, "one rewrite at a time")
        open.withLock { $0 = true }
        await first.value

        #expect(backend.enrichmentRequests.count == 2)
        let last = try #require(backend.enrichmentRequests.last)
        #expect(last.transcript.contains("opening budget question"))
        #expect(!last.transcript.contains("closing hiring answer"), "the part that left is not in it")
    }

    @Test("a part that failed does not stop the summary from being written from the rest")
    func failedPartDoesNotBlockTheRewrite() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pair = try Self.makeLinkedPair(root: root, secondState: .failed)
        let backend = FakeAIBackend()
        let pipeline = Self.makePipeline(repository: pair.repository, backend: backend)

        await pipeline.refreshConversationSummary(meetingID: pair.ids[0])

        let request = try #require(backend.enrichmentRequests.last)
        #expect(request.transcript.contains("opening budget question"))
        #expect(pair.stores[0].readSummaryDocument().summary == "Discussed retrieval.")
        #expect(try pair.stores[1].readMetadata().processing.state == .failed, "the failed part stays failed")
    }

    @Test("a failed rewrite is reported and leaves the finished meeting finished")
    func failedRewriteLeavesTheMeetingComplete() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pair = try Self.makeLinkedPair(root: root)
        _ = try pair.stores[0].updateMetadata { $0.titles.ai = "Earlier title" }
        let backend = FakeAIBackend()
        backend.failEnrichment = .transport(reason: "offline")
        let failures = Failures()
        let pipeline = Self.makePipeline(repository: pair.repository, backend: backend, failures: failures)

        await pipeline.refreshConversationSummary(meetingID: pair.ids[0])

        let metadata = try pair.stores[0].readMetadata()
        #expect(metadata.processing.state == .complete)
        #expect(metadata.titles.ai == "Earlier title")
        #expect(failures.all == [pair.ids[0]], "the person is told")

        // Not blocked afterwards: the next ask writes the summary.
        backend.failEnrichment = nil
        await pipeline.refreshConversationSummary(meetingID: pair.ids[0])
        #expect(pair.stores[0].readSummaryDocument().summary == "Discussed retrieval.")
        #expect(try pair.stores[0].readMetadata().processing.state == .complete)
    }

    @Test("without a key nothing is asked and nothing about the meeting changes")
    func noKeyNoRewrite() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pair = try Self.makeLinkedPair(root: root)
        let before = try pair.stores[0].readMetadata()
        let backend = FakeAIBackend()
        backend.configured = false
        let failures = Failures()
        let pipeline = Self.makePipeline(repository: pair.repository, backend: backend, failures: failures)

        await pipeline.refreshConversationSummary(meetingID: pair.ids[0])

        #expect(backend.enrichmentRequests.isEmpty)
        #expect(failures.all.isEmpty)
        #expect(try pair.stores[0].readMetadata() == before)
    }

    /// The local path with the models replaced, for a recording that is
    /// processed for real.
    private static func makeLocalPipeline(
        repository: MeetingRepository, backend: FakeAIBackend, root: URL
    ) -> ProcessingPipeline {
        var settings = AppSettings()
        settings.enrichment = EnrichmentSettings(
            generateTitle: true, generateDescription: false, generateNotes: false,
            generateSummary: true, suggestSpeakers: false)
        return PipelineFixtures.makePipeline(
            repository: repository, backend: backend,
            transcriber: StubLocalTranscriber(segments: [
                RawTranscriptSegment(
                    start: 0, end: 5, text: "we ship friday", speaker: nil,
                    words: [RawTranscriptWord(start: 0, end: 2, text: " we ship friday")])
            ]),
            diarizer: StubLocalDiarizer(
                intervals: [DiarizationInterval(start: 0, end: 5, clusterID: "S1")],
                chunkEmbeddings: []),
            speakers: nil, settings: settings, scratchRoot: root.appendingPathComponent("scratch"))
    }

    private static func occurrences(of word: String, in text: String) -> Int {
        text.components(separatedBy: word).count - 1
    }

    @Test("a call rejoined before it is processed writes one summary from both recordings")
    func rejoinedRecordingAsksForTheConversationSummary() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let earlier = try PipelineFixtures.makeRecordedMeeting(root: root, seconds: 6)
        let later = try PipelineFixtures.makeRecordedMeeting(root: root, seconds: 6)
        let backend = FakeAIBackend()
        let pipeline = Self.makeLocalPipeline(repository: earlier.repository, backend: backend, root: root)
        await pipeline.process(meetingID: earlier.metadata.id)
        #expect(backend.enrichmentRequests.count == 1)

        // The call dropped and was rejoined: the second recording is linked
        // before it has been processed, so it relies on the job that ends.
        _ = try earlier.store.updateMetadata { $0.absorbedMeetingIDs = [later.metadata.id] }
        _ = try later.store.updateMetadata { $0.mergedIntoMeetingID = earlier.metadata.id }
        backend.enrichment = MeetingEnrichment(title: "Whole call", summary: "Covers both halves.")
        await pipeline.process(meetingID: later.metadata.id)

        #expect(backend.enrichmentRequests.count == 2, "the continuation asks nothing of its own")
        let request = try #require(backend.enrichmentRequests.last)
        #expect(
            Self.occurrences(of: "we ship friday", in: request.transcript) == 4, "two tracks in each of two recordings")
        #expect(earlier.store.readSummaryDocument().summary == "Covers both halves.")
        #expect((later.store.readSummaryDocument().summary ?? "").isEmpty)
        #expect(try earlier.store.readMetadata().processing.state == .complete)
        #expect(try later.store.readMetadata().processing.state == .complete)
    }

    @Test("a recording linked while its own summary is being written does not keep that summary")
    func linkDuringEnrichmentWritesNoSummaryOfItsOwn() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let earlier = try PipelineFixtures.makeRecordedMeeting(root: root, seconds: 6)
        let later = try PipelineFixtures.makeRecordedMeeting(root: root, seconds: 6)
        let backend = FakeAIBackend()
        let pipeline = Self.makeLocalPipeline(repository: earlier.repository, backend: backend, root: root)
        await pipeline.process(meetingID: earlier.metadata.id)

        // The merge lands while the model is answering the second recording's
        // own request.
        let earlierStore = earlier.store
        let laterStore = later.store
        let earlierID = earlier.metadata.id
        let laterID = later.metadata.id
        let linked = Mutex(false)
        backend.enrichInterference = {
            guard
                linked.withLock({
                    let was = $0
                    $0 = true
                    return !was
                })
            else { return }
            _ = try? earlierStore.updateMetadata { $0.absorbedMeetingIDs = [laterID] }
            _ = try? laterStore.updateMetadata { $0.mergedIntoMeetingID = earlierID }
        }
        backend.enrichment = MeetingEnrichment(title: "Whole call", summary: "Covers both halves.")
        await pipeline.process(meetingID: later.metadata.id)

        #expect((later.store.readSummaryDocument().summary ?? "").isEmpty, "no summary of its own")
        let last = try #require(backend.enrichmentRequests.last)
        #expect(Self.occurrences(of: "we ship friday", in: last.transcript) == 4, "both recordings")
        #expect(earlier.store.readSummaryDocument().summary == "Covers both halves.")
    }

    @Test("a conversation too long for one request is cut across every recording")
    func longConversationIsCutEvenly() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let long = String(repeating: "filler ", count: 3_000)
        let made = try (0..<4).map { index in
            try RuntimeFixtures.makeMeeting(
                root: root, clusters: ["remote-001_speaker_00"], words: "marker\(index) " + long,
                title: "Part \(index)", startedAt: Self.base.addingTimeInterval(Double(index) * 3_600))
        }
        _ = try made[0].store.updateMetadata { $0.absorbedMeetingIDs = made.dropFirst().map(\.id) }
        for part in made.dropFirst() {
            _ = try part.store.updateMetadata { $0.mergedIntoMeetingID = made[0].id }
        }
        let repository = MeetingRepository(root: root.appendingPathComponent("Meetings"))
        let conversation = try #require(repository.logicalMeeting(id: made[0].id))

        let request = try #require(
            try ProcessingPipeline.enrichmentRequest(
                conversation: conversation, metadata: conversation.primary.metadata,
                settings: AppSettings(), folders: []))

        #expect(request.transcript.count <= 120_000)
        for index in 0..<4 {
            #expect(request.transcript.contains("marker\(index)"), "recording \(index) is in the request")
        }
    }
}
