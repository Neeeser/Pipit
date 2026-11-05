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
    private static func makeProcessed(
        root: URL, speakers: SpeakerRecognitionService? = nil, backend: FakeAIBackend = FakeAIBackend(),
        settings: AppSettings = MeetingTrimPipelineTests.settings,
        intervals: [DiarizationInterval] = [DiarizationInterval(start: 0, end: 30, clusterID: "S1")]
    ) async throws -> Processed {
        let meeting = try PipelineFixtures.makeRecordedMeeting(
            root: root.appendingPathComponent("Meetings"), source: .googleMeet, seconds: 30)
        let transcriber = StubLocalTranscriber(segments: [
            line("alphaword", at: 2), line("bravoword", at: 12), line("charlieword", at: 24),
        ])
        transcriber.reportedSeconds = 30
        transcriber.micSegments = [line("deltaword", at: 6)]
        let diarizer = StubLocalDiarizer(
            intervals: intervals,
            chunkEmbeddings: intervals.map {
                DiarizationChunkEmbedding(
                    clusterID: $0.clusterID, start: $0.start, end: $0.end,
                    vector: SpeakerFixtures.vector(seed: 61 + ($0.clusterID == "S1" ? 0 : 1)))
            })
        let pipeline = PipelineFixtures.makePipeline(
            repository: meeting.repository, backend: backend, transcriber: transcriber, diarizer: diarizer,
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

    @Test("a trim leaves a transcript of what is kept, and renames the folder once")
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

        let range = try #require(TrimRange(start: 10, end: 20, duration: 30))
        let outcome = await made.pipeline.trim(meetingID: made.id, to: range)

        #expect(outcome == ProcessingPipeline.TrimOutcome())
        let found = try #require(made.repository.findMeeting(id: made.id))
        #expect(
            found.store.layout.root.lastPathComponent != name,
            "the folder is named for the meeting as it now is, once, as part of the trim")
        let settled = found.store.layout.root.path
        made.repository.settleFolderNames()
        #expect(
            made.repository.findMeeting(id: made.id)?.store.layout.root.path == settled,
            "nothing is left to rename at the next launch")
        // Processing it again later does not file it by rules written since.
        _ = try found.store.updateMetadata {
            $0.titles.human = "Another title entirely"
            $0.processing = ProcessingStatus(state: .enriching, updatedAt: TrimFixtures.started)
        }
        await made.pipeline.process(meetingID: made.id)
        #expect(made.repository.findMeeting(id: made.id)?.store.layout.root.path == settled)
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

    @Test("what redoing the microphone copied aside goes with the trim")
    func theBackupsGoWithTheTrim() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let made = try await Self.makeProcessed(root: root)
        let backups = root.appendingPathComponent("Application Support/Backups")
        let copy = Reprocessing.backupDirectory(under: backups, meetingID: made.id, at: TrimFixtures.started)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try Data("alphaword charlieword".utf8).write(to: copy.appendingPathComponent("transcript.md"))
        let other = backups.appendingPathComponent("another-meeting")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        _ = await made.pipeline.trim(
            meetingID: made.id, to: try #require(TrimRange(start: 10, end: 20, duration: 30)), backups: backups)

        #expect(!FileManager.default.fileExists(atPath: backups.appendingPathComponent(made.id).path))
        #expect(FileManager.default.fileExists(atPath: other.path), "another meeting's backups stay")
    }

    @Test("nothing else changes a meeting's files while a trim is unfinished")
    func nothingElseChangesTheFilesWhileATrimIsUnfinished() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let made = try await Self.makeProcessed(root: root)
        try Self.interrupt(made)

        await #expect(throws: MicrophoneRedoError.busy) {
            try await made.pipeline.redoMicrophone(meetingID: made.id, backups: root.appendingPathComponent("Backups"))
        }
        await #expect(throws: TrimError.inProgress) { try await made.pipeline.rebuildTranscript(meetingID: made.id) }
        await #expect(throws: TrimError.inProgress) {
            try await made.pipeline.applySpeakerName("Speaker A", to: "remote-001:S1", meetingID: made.id)
        }
        await #expect(throws: TrimError.inProgress) {
            try await made.pipeline.reanalyzeSpeakers(meetingID: made.id, speakerCount: nil)
        }
    }

    @Test("an earlier trim is reported as finished only when it was")
    func anEarlierTrimIsReportedAsFinishedOnlyWhenItWas() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let made = try await Self.makeProcessed(root: root)
        try Self.interrupt(made)
        let audio = made.store.layout.trackArchiveDirectory
        // Nothing can be swapped into the audio folder.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: audio.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: audio.path) }
        let range = try #require(TrimRange(start: 1, end: 5, duration: 30))

        let stuck = await made.pipeline.trim(meetingID: made.id, to: range)
        #expect(stuck.failure == .filesNotWritten, "finishing failed, so it is not reported as finished")
        #expect(FileManager.default.fileExists(atPath: made.store.layout.trimJournal.path))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: audio.path)
        let finished = await made.pipeline.trim(meetingID: made.id, to: range)
        #expect(finished.failure == .interrupted)
        try Self.expectTrimmedAndFinished(made)
    }

    /// Holds a trim at a stage until `release` is called.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            await withCheckedContinuation { (next: CheckedContinuation<Void, Never>) in
                lock.lock()
                if released {
                    lock.unlock()
                    next.resume()
                } else {
                    continuation = next
                    lock.unlock()
                }
            }
        }
        func release() {
            lock.lock()
            released = true
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume()
        }
    }

    @Test("a job queued behind the trim does not run on the half-finished meeting")
    func aJobQueuedBehindTheTrimDoesNotRunOnIt() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let made = try await Self.makeProcessed(root: root)
        let gate = Gate()
        let atSwapped = Gate()
        await made.pipeline.setTrimCheckpoint { stage in
            if stage == "swapped" {
                atSwapped.release()
                await gate.wait()
            }
        }
        let range = try #require(TrimRange(start: 10, end: 20, duration: 30))
        let trimming = Task { await made.pipeline.trim(meetingID: made.id, to: range) }
        await atSwapped.wait()
        // The trim holds the slot. Regenerating the summary queues behind it.
        let queued = Task { () -> (any Error)? in
            do {
                try await made.pipeline.generateEnrichment(meetingID: made.id)
                return nil
            } catch { return error }
        }
        try await Task.sleep(for: .milliseconds(300))
        gate.release()

        let outcome = await trimming.value
        #expect(outcome.failure == nil)
        let refused = await queued.value
        #expect(
            refused as? TrimError == .inProgress,
            "it was refused, not run on trimmed audio: \(String(describing: refused))")
        try Self.expectTrimmedAndFinished(made)
    }

    @Test("the folder is not renamed under a job that is in it")
    func theFolderIsNotRenamedUnderAJobInIt() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = FakeAIBackend()
        var enriching = Self.settings
        enriching.enrichment.generateSummary = true
        let made = try await Self.makeProcessed(root: root, backend: backend, settings: enriching)
        let name = made.store.layout.root.lastPathComponent
        _ = try made.store.updateMetadata {
            $0.directoryName = name
            $0.titles.human = "A title that gives the folder a new name"
        }
        // Regenerating the summary holds the folder while its request is out.
        let finishRequest = Gate()
        await made.pipeline.setTrimCheckpoint { [pipeline = made.pipeline, id = made.id] stage in
            guard stage == "settling" else { return }
            backend.enrichInterference = { await finishRequest.wait() }
            Task { try? await pipeline.generateEnrichment(meetingID: id) }
            try? await Task.sleep(for: .milliseconds(300))
        }

        _ = await made.pipeline.trim(
            meetingID: made.id, to: try #require(TrimRange(start: 10, end: 20, duration: 30)))

        let during = try #require(made.repository.findMeeting(id: made.id))
        #expect(during.store.layout.root.lastPathComponent == name, "not renamed with a job in the folder")
        finishRequest.release()
        try await Task.sleep(for: .milliseconds(300))
        made.repository.settleFolderNames()
        let after = try #require(made.repository.findMeeting(id: made.id))
        #expect(after.store.layout.root.lastPathComponent != name, "the launch sweep does it")
        #expect(
            made.repository.meetingDirectories().filter { $0.path.contains(made.id) }.count <= 1,
            "one folder for the meeting")
    }

    @Test("a trim made while the voice memory is out of reach is parked, and made at the next launch")
    func aTrimIsParkedWhileTheVoiceMemoryIsOutOfReach() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let made = try await Self.makeProcessed(root: root)
        let (voices, voiceRoot) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: voiceRoot) }
        let person = try await voices.createPerson(name: "Speaker A")
        _ = try await voices.enrol(
            VoiceEnrollmentCandidate(
                identityID: person.id, vector: SpeakerFixtures.vector(seed: 92), model: .fluidAudioOffline,
                speechSeconds: 300, qualityScore: 1, source: .humanConfirmedCluster,
                evidence: [
                    VoiceEvidence(
                        meetingID: made.id, track: .remote, spans: [AudioSpan(start: 5, end: 300)],
                        confirmation: .humanConfirmedCluster)
                ]))

        // No voice memory behind this pipeline.
        _ = await made.pipeline.trim(
            meetingID: made.id, to: try #require(TrimRange(start: 2, end: 30, duration: 30)))

        let store = try #require(made.repository.findMeeting(id: made.id)).store
        #expect(!FileManager.default.fileExists(atPath: store.layout.trimJournal.path), "the meeting is not locked")
        #expect(store.readPendingVoiceAdjustments().count == 1, "the adjustment waits in the folder")
        #expect(
            try await voices.storedEmbeddings(of: person.id).first?.evidence.first?.spans
                == [AudioSpan(start: 5, end: 300)])

        // The next launch, with the memory open.
        let later = PipelineFixtures.makePipeline(
            repository: made.repository, backend: FakeAIBackend(),
            transcriber: StubLocalTranscriber(segments: []),
            diarizer: StubLocalDiarizer(intervals: [], chunkEmbeddings: []),
            speakers: SpeakerRecognitionService(store: voices), settings: Self.settings,
            scratchRoot: root.appendingPathComponent("scratch2"))
        await later.finishInterruptedTrims()

        #expect(store.readPendingVoiceAdjustments().isEmpty)
        #expect(
            try await voices.storedEmbeddings(of: person.id).first?.evidence.first?.spans
                == [AudioSpan(start: 3, end: 298)])
    }

    @Test("speaker occurrence rows follow a real trim")
    func occurrenceRowsFollowARealTrim() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (voices, voiceRoot) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: voiceRoot) }
        // One speaker for the first 18 s, another from 18 s to the end.
        let made = try await Self.makeProcessed(
            root: root, speakers: SpeakerRecognitionService(store: voices),
            intervals: [
                DiarizationInterval(start: 0, end: 18, clusterID: "S1"),
                DiarizationInterval(start: 18, end: 30, clusterID: "S2"),
            ])
        let before = try await voices.occurrences(meetingID: made.id).filter { $0.clusterID != SpeakerLabel.localUser }
        #expect(before.count == 2, "the fixture records both speakers, got \(before.map(\.clusterID))")

        // Keeps 20 s on: the first speaker is not in what is left, the second
        // has 10 s.
        _ = await made.pipeline.trim(
            meetingID: made.id, to: try #require(TrimRange(start: 20, end: 30, duration: 30)))

        let after = try await voices.occurrences(meetingID: made.id).filter { $0.clusterID != SpeakerLabel.localUser }
        #expect(after.count == 1, "the first speaker's row is gone, got \(after.map(\.clusterID))")
        #expect(
            after.first.map { abs($0.speechSeconds - 10) < 0.01 } == true,
            "got \(String(describing: after.first?.speechSeconds))")
    }

    @Test("a second trim made while one is parked waits behind it, and speaker edits wait")
    func aSecondTrimWaitsBehindAParkedOne() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let made = try await Self.makeProcessed(root: root)
        let (voices, voiceRoot) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: voiceRoot) }
        let person = try await voices.createPerson(name: "Speaker A")
        _ = try await voices.enrol(
            VoiceEnrollmentCandidate(
                identityID: person.id, vector: SpeakerFixtures.vector(seed: 93), model: .fluidAudioOffline,
                speechSeconds: 300, qualityScore: 1, source: .humanConfirmedCluster,
                evidence: [
                    VoiceEvidence(
                        meetingID: made.id, track: .remote, spans: [AudioSpan(start: 5, end: 300)],
                        confirmation: .humanConfirmedCluster)
                ]))

        // No voice memory behind this pipeline: both trims park.
        let first = await made.pipeline.trim(
            meetingID: made.id, to: try #require(TrimRange(start: 2, end: 30, duration: 30)))
        let second = await made.pipeline.trim(
            meetingID: made.id, to: try #require(TrimRange(start: 3, end: 28, duration: 28)))
        #expect(first.failure == nil && second.failure == nil, "\(first) \(second)")
        let store = try #require(made.repository.findMeeting(id: made.id)).store
        let parked = store.readPendingVoiceAdjustments()
        #expect(parked.count == 2)
        #expect(parked.map(\.start) == [2, 3], "in the order the trims were made")

        // Who said what cannot be corrected until the memory has caught up.
        await #expect(throws: TrimError.voicePending) {
            try await made.pipeline.applySpeakerName("Speaker A", to: "remote-001:S1", meetingID: made.id)
        }

        let later = PipelineFixtures.makePipeline(
            repository: made.repository, backend: FakeAIBackend(),
            transcriber: StubLocalTranscriber(segments: []),
            diarizer: StubLocalDiarizer(intervals: [], chunkEmbeddings: []),
            speakers: SpeakerRecognitionService(store: voices), settings: Self.settings,
            scratchRoot: root.appendingPathComponent("scratch2"))
        await later.finishInterruptedTrims()

        #expect(store.readPendingVoiceAdjustments().isEmpty)
        #expect(
            try await voices.storedEmbeddings(of: person.id).first?.evidence.first?.spans
                == [AudioSpan(start: 0, end: 295)], "moved by 2 s and then by 3 s")
    }
}
