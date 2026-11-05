import Foundation
import PipitCore
import PipitServices
import PipitSpeakers
import Testing

/// Trim through the processing pipeline: what a person reads afterwards, and
/// what is finished when something stops part way.
@Suite("MeetingTrimPipeline")
struct MeetingTrimPipelineTests {
    private static var settings: AppSettings {
        var settings = AppSettings()
        settings.enrichment = EnrichmentSettings(
            generateTitle: false, generateDescription: false, generateNotes: false,
            generateSummary: false, suggestSpeakers: false
        )
        return settings
    }

    private static func line(_ text: String, at start: Double) -> RawTranscriptSegment {
        RawTranscriptSegment(
            start: start, end: start + 1.5, text: " \(text)", speaker: nil,
            words: [RawTranscriptWord(start: start, end: start + 1.5, text: " \(text)")])
    }

    private struct Processed {
        var store: MeetingStore
        var repository: MeetingRepository
        var pipeline: ProcessingPipeline
        var id: String
        var root: URL
    }

    /// A 30 s call, processed and compacted, with one word at 2 s, 12 s and
    /// 24 s on the far end.
    private static func makeProcessed(root: URL, speakers: SpeakerRecognitionService? = nil) async throws -> Processed {
        let meeting = try PipelineFixtures.makeRecordedMeeting(
            root: root.appendingPathComponent("Meetings"), source: .googleMeet, seconds: 30)
        let transcriber = StubLocalTranscriber(segments: [
            line("alphaword", at: 2), line("bravoword", at: 12), line("charlieword", at: 24),
        ])
        transcriber.reportedSeconds = 30
        transcriber.micSegments = [line("deltaword", at: 6)]
        let diarizer = StubLocalDiarizer(
            intervals: [DiarizationInterval(start: 0, end: 30, clusterID: "S1")],
            chunkEmbeddings: [
                DiarizationChunkEmbedding(clusterID: "S1", start: 0, end: 30, vector: SpeakerFixtures.vector(seed: 61))
            ])
        let pipeline = PipelineFixtures.makePipeline(
            repository: meeting.repository, backend: FakeAIBackend(), transcriber: transcriber, diarizer: diarizer,
            speakers: speakers, settings: settings, scratchRoot: root.appendingPathComponent("scratch"))
        await pipeline.process(meetingID: meeting.metadata.id)
        let status = try meeting.store.readMetadata().processing
        try #require(
            status.state == .complete,
            "the fixture finishes processing, got \(status.state) \(String(describing: status.lastFailure))")
        return Processed(
            store: meeting.store, repository: meeting.repository, pipeline: pipeline, id: meeting.metadata.id,
            root: root)
    }

    @Test("a trim leaves a transcript of what is kept, and the folder keeps its place")
    func aTrimLeavesATranscriptOfWhatIsKept() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let made = try await Self.makeProcessed(root: root)
        let before = try #require(try made.store.readCanonicalTranscript())
        #expect(before.utterances.count >= 3, "the fixture has a line before, in and after the range")
        // A title that, applied now, would give the folder a new name.
        let name = made.store.layout.root.lastPathComponent
        _ = try made.store.updateMetadata {
            $0.directoryName = name
            $0.titles.human = "A title set after filing"
        }
        let folder = made.store.layout.root.path

        let range = try #require(TrimRange(start: 10, end: 20, duration: 30))
        let outcome = await made.pipeline.trim(meetingID: made.id, to: range)

        #expect(outcome == ProcessingPipeline.TrimOutcome())
        let found = try #require(made.repository.findMeeting(id: made.id))
        #expect(found.store.layout.root.path == folder, "processing does not refile or rename a trimmed meeting")
        #expect(found.metadata.processing.state == .complete)
        #expect(abs(found.metadata.durationSeconds - 10) < 0.2)
        let after = try #require(try found.store.readCanonicalTranscript())
        #expect(after.utterances.map(\.text).joined().contains("bravoword"))
        #expect(!after.utterances.map(\.text).joined().contains("alphaword"))
        #expect(
            TrimFixtures.textFiles(in: found.store.layout.root, containing: ["alphaword", "charlieword"]).isEmpty,
            "no file in the folder still holds a removed word")
        #expect(!FileManager.default.fileExists(atPath: found.store.layout.trimJournal.path))
    }

    @Test("a transcript that cannot be rebuilt does not make the trim fail")
    func aTranscriptThatCannotBeRebuiltDoesNotFailTheTrim() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let made = try await Self.makeProcessed(root: root)
        let layout = made.store.layout
        // Nothing for the trim to write in the meeting's own folder, and the
        // transcript's markdown is the only thing the rebuild writes there.
        for url in [layout.recordingAudio, layout.transcriptMarkdown, layout.summary] {
            try? FileManager.default.removeItem(at: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: layout.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.root.path) }

        let range = try #require(TrimRange(start: 10, end: 20, duration: 30))
        let outcome = await made.pipeline.trim(meetingID: made.id, to: range)

        #expect(outcome.failure == nil, "the files are cut, so the trim happened")
        #expect(outcome.transcriptNotRebuilt)
        #expect(abs(try made.store.readMetadata().durationSeconds - 10) < 0.2)
    }

    /// Stops a trim of 10 s to 20 s after two files were swapped in.
    private static func interrupt(_ made: Processed) throws {
        let range = try #require(TrimRange(start: 10, end: 20, duration: 30))
        let interrupted = MeetingTrimmer(beforeSwap: { position in
            if position == 2 { throw TrimError.filesNotWritten }
        })
        #expect(throws: TrimError.filesNotWritten) {
            try interrupted.trim(store: made.store, to: range, at: TrimFixtures.started)
        }
        #expect(abs(try made.store.readMetadata().durationSeconds - 30) < 0.2, "the record is still the old one")
    }

    private static func expectTrimmedAndFinished(_ made: Processed) throws {
        let metadata = try made.store.readMetadata()
        #expect(abs(metadata.durationSeconds - 10) < 0.2)
        #expect(metadata.processing.state == .complete)
        #expect(!FileManager.default.fileExists(atPath: made.store.layout.trimJournal.path))
        let text = try #require(try made.store.readCanonicalTranscript()).utterances.map(\.text).joined()
        #expect(text.contains("bravoword") && !text.contains("alphaword"))
    }

    @Test("a trim that stopped between two swaps is finished at launch")
    func anInterruptedTrimIsFinishedAtLaunch() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let made = try await Self.makeProcessed(root: root)
        try Self.interrupt(made)

        await made.pipeline.finishInterruptedTrims()

        try Self.expectTrimmedAndFinished(made)
    }

    @Test("a new trim is refused while one is unfinished, and finishes the old one")
    func aNewTrimIsRefusedWhileOneIsUnfinished() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let made = try await Self.makeProcessed(root: root)
        try Self.interrupt(made)

        // A range chosen on the meeting as it was is not applied to the one
        // it has become.
        let outcome = await made.pipeline.trim(
            meetingID: made.id, to: try #require(TrimRange(start: 1, end: 5, duration: 30)))

        #expect(outcome.failure == .interrupted)
        try Self.expectTrimmedAndFinished(made)
    }

    @Test("the voice memory moves with the trim")
    func theVoiceMemoryMovesWithTheTrim() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (voices, voiceRoot) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: voiceRoot) }
        let made = try await Self.makeProcessed(root: root, speakers: SpeakerRecognitionService(store: voices))
        let person = try await voices.createPerson(name: "Speaker A")
        _ = try await voices.enrol(
            VoiceEnrollmentCandidate(
                identityID: person.id, vector: SpeakerFixtures.vector(seed: 91), model: .fluidAudioOffline,
                speechSeconds: 300, qualityScore: 1, source: .humanConfirmedCluster,
                evidence: [
                    VoiceEvidence(
                        meetingID: made.id, track: .remote,
                        spans: [AudioSpan(start: 0, end: 1.5), AudioSpan(start: 5, end: 300)],
                        confirmation: .humanConfirmedCluster)
                ]))

        // Cuts the first 2 s and keeps the rest.
        let range = try #require(TrimRange(start: 2, end: 30, duration: 30))
        _ = await made.pipeline.trim(meetingID: made.id, to: range)

        let evidence = try #require(try await voices.storedEmbeddings(of: person.id).first?.evidence.first)
        #expect(evidence.spans == [AudioSpan(start: 3, end: 298)], "5 to 300 is now 3 to 298, got \(evidence.spans)")
    }
}
