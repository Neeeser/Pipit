import Foundation
import PipitCore
import Testing

/// Reports whatever a test says a CAF file contains, so crash recovery can be
/// exercised without writing real audio.
struct StubAudioFileInspector: AudioFileInspecting {
    var infoByName: [String: AudioFileInfo]

    func inspect(url: URL) throws -> AudioFileInfo {
        guard let info = infoByName[url.lastPathComponent] else {
            throw StorageError.fileReadFailed(path: url.path, underlying: "no stub")
        }
        return info
    }
}

@Suite("Storage")
struct StorageTests {
    @Test("a folder written after a meeting was trashed goes, and the meeting stays")
    func aFolderWrittenAfterAMeetingWasTrashedGoesAndTheMeetingStays() async throws {
        // Every write goes through AtomicFile, which creates the
        // directories it needs, so a job still running when the user
        // trashes a meeting puts a folder back at that path. The date
        // is what tells that scrap apart from the meeting itself, put
        // back from the Trash.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let movedAt = Date()

        func folder(_ name: String, created: Date) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.creationDate: created], ofItemAtPath: url.path
            )
            return url
        }

        let scrap = try folder("scrap", created: movedAt.addingTimeInterval(30))
        #expect(RecreatedFolder.discard(at: scrap, writtenAfter: movedAt) == .removed)
        #expect(!FileManager.default.fileExists(atPath: scrap.path))

        let putBack = try folder("put-back", created: movedAt.addingTimeInterval(-3_600))
        #expect(RecreatedFolder.discard(at: putBack, writtenAfter: movedAt) == .predatesTheMove)
        #expect(
            FileManager.default.fileExists(atPath: putBack.path),
            "the meeting somebody put back is left where it is"
        )
        #expect(FileManager.default.fileExists(
                atPath: putBack.appendingPathComponent("kept").path
            ) == false, "and nothing was written into it")

        // HFS+ stores whole seconds, so a folder written just after the
        // move reports a moment before it. Inside the grain it is still
        // scrap.
        let truncated = try folder("truncated", created: movedAt.addingTimeInterval(-0.9))
        #expect(
            RecreatedFolder.discard(at: truncated, writtenAfter: movedAt) == .removed,
            "a coarse clock does not turn scrap into a meeting"
        )

        #expect(RecreatedFolder.discard(
                at: root.appendingPathComponent("nothing"), writtenAfter: movedAt
            ) == .absent)
    }

    @Test("meeting identifiers are readable, unique and date-partitioned")
    func meetingIdentifiersAreReadableUniqueAndDatePartitioned() async throws {
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let id = MeetingArchiveLayout.meetingID(
            startedAt: started, source: .slackHuddle, title: "Engineering Huddle / Q3"
        )
        #expect(id.hasSuffix("slack-huddle-engineering-huddle-q3"), "got \(id)")
        #expect(!id.contains("/"))
        #expect(!id.contains(" "))

        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = MeetingArchiveLayout(root: root)
        let directory = archive.directory(named: id, startedAt: started)
        let parts = directory.pathComponents.suffix(3)
        #expect(parts.count == 3)
        #expect(Array(parts)[2] == id)
    }

    @Test("metadata, notes and speaker map survive a round trip")
    func metadataNotesAndSpeakerMapSurviveARoundTrip() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root)
        let now = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .googleMeet, provider: .googleMeet, startedAt: now,
            titles: TitleCandidates(provider: "Weekly sync", timestampFallback: "fallback"),
            now: now
        )

        try created.store.writeNotes("Company X call with me, Chris and Tim.\n")
        var map = SpeakerMap.withLocalUser(named: "Andrew")
        map.assign("Chris", to: "chunk_001_speaker_00")
        try created.store.writeSpeakerMap(map)

        let reread = try created.store.readMetadata()
        #expect(reread.id == created.metadata.id)
        #expect(reread.source == .googleMeet)
        #expect(reread.processing.state == .recording)
        #expect(created.store.readNotes() == "Company X call with me, Chris and Tim.\n")
        let rereadMap = try created.store.readSpeakerMap()
        #expect(rereadMap.resolvedName(for: "chunk_001_speaker_00") == "Chris")
        #expect(rereadMap.resolvedName(for: "local") == "Andrew")
        #expect(rereadMap.resolvedName(for: "chunk_001_speaker_01") == "Speaker 2")
    }

    @Test("listing finds meetings and skips ones folded into another")
    func listingFindsMeetingsAndSkipsOnesFoldedIntoAnother() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root)
        let first = Date(timeIntervalSince1970: 1_787_070_000)
        let second = first.addingTimeInterval(3_600)

        _ = try repository.createMeeting(
            source: .slackHuddle, provider: .slack, startedAt: first,
            titles: TitleCandidates(provider: "One", timestampFallback: "f1"), now: first
        )
        let absorbed = try repository.createMeeting(
            source: .slackHuddle, provider: .slack, startedAt: second,
            titles: TitleCandidates(provider: "Two", timestampFallback: "f2"), now: second
        )
        try absorbed.store.updateMetadata { $0.mergedIntoMeetingID = "somewhere-else" }

        let listed = repository.listMeetings()
        #expect(listed.count == 1)
        #expect(listed[0].title.contains("One"))
    }

    @Test("an atomic write leaves the previous file intact on failure")
    func anAtomicWriteLeavesThePreviousFileIntactOnFailure() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("metadata.json")
        try AtomicFile.writeText("first", to: target)
        try AtomicFile.writeText("second", to: target)
        #expect(try String(contentsOf: target, encoding: .utf8) == "second")
        // No temporary files are left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".tmp") }
        #expect(leftovers == [])
    }

    @Test("a killed recording recovers into a usable interrupted meeting")
    func aKilledRecordingRecoversIntoAUsableInterruptedMeeting() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root)
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .slackHuddle, provider: .slack, startedAt: started,
            titles: TitleCandidates(provider: "Huddle", timestampFallback: "f"), now: started
        )
        var metadata = created.metadata
        metadata.runs = [RecordingRun(id: "run-001", startedAt: started)]
        try created.store.writeMetadata(metadata)

        // One closed segment, one that was still open when the process died.
        let writer = try ManifestWriter(url: created.store.layout.manifest)
        writer.append(.sessionStart(.init(
            meetingID: metadata.id, source: .slackHuddle, segmentSeconds: 30,
            appVersion: "1.0.0", processID: 42
        )))
        writer.append(.segmentOpen(.init(
            track: .mic, index: 1, file: "mic.0001.caf", firstFrameHostTime: 1,
            startFrame: 0, sampleRate: 48_000, channelCount: 1, reason: "start"
        )))
        writer.append(.segmentClose(.init(
            track: .mic, index: 1, frameCount: 1_440_000, byteCount: 5_760_000,
            seconds: 30, firstFrameHostTime: 1, reason: "rotate"
        )))
        writer.append(.segmentOpen(.init(
            track: .mic, index: 2, file: "mic.0002.caf", firstFrameHostTime: 31,
            startFrame: 1_440_000, sampleRate: 48_000, channelCount: 1, reason: "rotate"
        )))
        writer.close()

        // The surviving CAF tail on disk, plus a system segment the manifest
        // never got to record at all.
        for name in ["mic.0001.caf", "mic.0002.caf", "system.0001.caf"] {
            FileManager.default.createFile(
                atPath: created.store.layout.segments.appendingPathComponent(name).path,
                contents: Data([0x00])
            )
        }
        let inspector = StubAudioFileInspector(infoByName: [
            "mic.0001.caf": AudioFileInfo(
                frameCount: 1_440_000, sampleRate: 48_000, channelCount: 1, byteCount: 5_760_000
            ),
            "mic.0002.caf": AudioFileInfo(
                frameCount: 4_320, sampleRate: 48_000, channelCount: 1, byteCount: 17_280
            ),
            "system.0001.caf": AudioFileInfo(
                frameCount: 960_000, sampleRate: 48_000, channelCount: 2, byteCount: 7_680_000
            ),
        ])

        let scanner = RecoveryScanner(
            repository: repository, inspector: inspector,
            clock: ManualClock(now: started.addingTimeInterval(600))
        )
        let report = scanner.scan()

        #expect(report.recovered.count == 1)
        let recovered = try #require(report.recovered.first)
        #expect(recovered.adoptedSegments == 1, "the open mic segment is the crash tail")
        #expect(recovered.reconstructedSegments == 1, "the unrecorded system segment is adopted too")

        let timeline = try created.store.readTimeline()
        #expect(timeline.openSegments.count == 0)
        #expect(
            abs(timeline.duration(track: .mic) - 30.09) <= 0.001,
            "expected \(30.09) ± \(0.001), got \(timeline.duration(track: .mic))"
        )
        #expect(
            abs(timeline.duration(track: .remote) - 20.0) <= 0.001,
            "expected \(20.0) ± \(0.001), got \(timeline.duration(track: .remote))"
        )
        #expect(timeline.isComplete, "recovery closes the session")

        let recoveredMetadata = try created.store.readMetadata()
        #expect(recoveredMetadata.processing.state == .audioSafe)
        #expect(recoveredMetadata.runs[0].wasInterrupted)
        #expect(
            abs(recoveredMetadata.durationSeconds - 30.09) <= 0.001,
            "expected \(30.09) ± \(0.001), got \(recoveredMetadata.durationSeconds)"
        )
        #expect(recoveredMetadata.endedAt != nil)
    }

    @Test("a recording with no readable audio fails instead of pretending")
    func aRecordingWithNoReadableAudioFailsInsteadOfPretending() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root)
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .manual, provider: .unknown, startedAt: started, now: started
        )
        let writer = try ManifestWriter(url: created.store.layout.manifest)
        writer.append(.sessionStart(.init(
            meetingID: created.metadata.id, source: .manual, segmentSeconds: 30,
            appVersion: "1.0.0", processID: 7
        )))
        writer.close()

        let scanner = RecoveryScanner(
            repository: repository, inspector: StubAudioFileInspector(infoByName: [:]),
            clock: ManualClock(now: started)
        )
        _ = scanner.scan()
        let metadata = try created.store.readMetadata()
        #expect(metadata.processing.state == .failed)
        #expect(metadata.processing.lastFailure?.isRetryable == false)
    }

    @Test("processing status resumes at the stage that failed")
    func processingStatusResumesAtTheStageThatFailed() async throws {
        var status = ProcessingStatus(state: .audioSafe, updatedAt: Date())
        status.advance(to: .transcribing, at: Date())
        status.recordAttempt(for: .transcribing)
        #expect(status.attemptCount(for: .transcribing) == 1)

        status.advance(to: .diarizing, at: Date())
        #expect(status.hasCompleted(.transcribing))

        status.recordFailure(
            ProcessingFailure(
                stage: .diarizing, message: "rate limited", isRetryable: true, occurredAt: Date()
            ),
            at: Date()
        )
        #expect(status.state == .failed)
        #expect(status.resumeStage == .diarizing)
        #expect(status.hasCompleted(.transcribing), "earlier work is not thrown away")

        status.advance(to: .diarizing, at: Date())
        #expect(status.lastFailure == nil)
    }

    @Test("processing state knows what is safe after audio_safe")
    func processingStateKnowsWhatIsSafeAfterAudioSafe() async throws {
        #expect(!ProcessingState.recording.isAudioSafe)
        #expect(!ProcessingState.finalizing.isAudioSafe)
        for state in [ProcessingState.audioSafe, .transcribing, .diarizing,
                      .resolvingSpeakers, .enriching, .complete, .failed] {
            #expect(state.isAudioSafe, "\(state) should be past the audio-safe boundary")
        }
    }
}
