import AVFoundation
import Foundation
import PipitAudio
import PipitCore
import PipitServices
import PipitTestSupport
import Testing

/// Storage compaction: PCM segments become verified archive files, and the
/// layout migration that moves old folders under `raw/`.
@Suite("Compaction")
struct CompactionTests {
    /// A finished two-track meeting marked `complete`, ready to compact.
    private static func makeCompleteMeeting(
        root: URL, seconds: Double = 6, remoteStartOffset: Double = 0
    ) throws -> (metadata: MeetingMetadata, store: MeetingStore) {
        let made = try PipelineFixtures.makeRecordedMeeting(
            root: root, seconds: seconds, remoteStartOffset: remoteStartOffset
        )
        let metadata = try made.store.updateMetadata {
            $0.processing = ProcessingStatus(state: .complete, updatedAt: $0.startedAt)
        }
        return (metadata, made.store)
    }

    @Test("compaction archives both tracks, records them and deletes the segments")
    func compactionArchivesBothTracksRecordsThemAndDeletesTheSegments() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try Self.makeCompleteMeeting(root: root)
        let store = meeting.store

        let outcome = try AudioCompactor().compact(store: store)
        #expect(outcome == AudioCompactor.Outcome.compacted)

        let metadata = try store.readMetadata()
        let archive = metadata.audioArchive
        #expect(archive != nil, "the archive is recorded in the metadata")
        for track in CaptureTrack.allCases {
            let record = archive?.track(track)
            #expect(record != nil, "\(track.rawValue) has an archive record")
            #expect(
                abs((record?.seconds ?? 0) - (6)) <= 0.5,
                "expected 6 ± 0.5, got \(record?.seconds ?? 0)"
            )
            let file = store.layout.trackArchiveFile(track: track)
            #expect(
                FileManager.default.fileExists(atPath: file.path),
                "\(track.rawValue) archive file exists"
            )
            let info = try AudioFileInspector().inspect(url: file)
            #expect(abs((info.seconds) - (6)) <= 0.5, "expected 6 ± 0.5, got \(info.seconds)")
        }
        #expect(
            !(FileManager.default.fileExists(atPath: store.layout.segments.path)),
            "the segments directory is gone"
        )
        #expect(
            FileManager.default.fileExists(atPath: store.layout.recordingAudio.path),
            "the mixdown exists before the segments are deleted"
        )
    }

    @Test("a compacted track reads back through its location at the recorded duration")
    func aCompactedTrackReadsBackThroughItsLocationAtTheRecordedDurat() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try Self.makeCompleteMeeting(root: root)
        let store = meeting.store
        _ = try AudioCompactor().compact(store: store)

        let metadata = try store.readMetadata()
        let timeline = try store.readTimeline()
        let location = store.trackAudioLocation(
            track: .mic, metadata: metadata, timeline: timeline
        )
        #expect(location.directory.lastPathComponent == "audio")
        #expect(
            abs((location.seconds) - (6)) <= 0.5,
            "expected 6 ± 0.5, got \(location.seconds)"
        )

        // The archive decodes as a continuous signal, not just a header.
        let stream = TrackAudioStream(
            segments: location.segments,
            segmentsDirectory: location.directory,
            format: AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1)
        )
        var frames: Int64 = 0
        var peak: Float = 0
        try stream.forEachBuffer(from: 0, to: 10) { buffer, _ in
            frames += Int64(buffer.frameLength)
            if let data = buffer.floatChannelData {
                for frame in 0..<Int(buffer.frameLength) {
                    peak = max(peak, abs(data[0][frame]))
                }
            }
            return true
        }
        #expect(
            abs((Double(frames) / 16_000) - (6)) <= 0.5,
            "expected 6 ± 0.5, got \(Double(frames) / 16_000)"
        )
        #expect(peak > 0.1, "the decoded audio holds the tone, not silence")
    }

    @Test("a failed export keeps the segments and records no archive")
    func aFailedExportKeepsTheSegmentsAndRecordsNoArchive() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try Self.makeCompleteMeeting(root: root)
        let store = meeting.store

        // The manifest still names the mic segment; the file is gone, which
        // is what a damaged archive folder looks like. The transcode comes
        // up short and verification must refuse it.
        for file in try FileManager.default.contentsOfDirectory(
            at: store.layout.segments, includingPropertiesForKeys: nil
        ) where file.lastPathComponent.hasPrefix("mic.") {
            try FileManager.default.removeItem(at: file)
        }

        var thrown: (any Error)?
        do { _ = try AudioCompactor().compact(store: store) } catch { thrown = error }
        #expect(thrown != nil, "verification refuses the short archive")

        let metadata = try store.readMetadata()
        #expect(metadata.audioArchive == nil, "no archive is recorded")
        #expect(
            FileManager.default.fileExists(atPath: store.layout.segments.path),
            "the segments stay the source"
        )
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: store.layout.trackArchiveDirectory, includingPropertiesForKeys: nil
        )) ?? []
        #expect(
            leftovers.filter { $0.lastPathComponent.contains("partial") } == [],
            "no partial file is left behind"
        )
    }

    @Test("compaction archives the recording, not the cleaned microphone")
    func compactionArchivesTheRecordingNotTheCleanedMicrophone() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // The one line in the branch that stands between a user and losing
        // their own recording. `writeArchives` transcodes what it is given
        // and `deleteReplacedAudio` then removes the segments for good, so
        // reading through `trackAudioLocation` here would put cleaned audio
        // in `mic.m4a` and delete the only copy of the raw microphone.
        let meeting = try MicrophoneCleaningFixtures.makeCallOnSpeakers(root: root)
        let store = meeting.store
        var metadata = meeting.metadata
        #expect(try MicrophoneCleaner().clean(
                store: store, metadata: &metadata, timeline: try store.readTimeline()
            ) == CleaningOutcome.cleaned)

        let timeline = try store.readTimeline()
        let far = MicrophoneCleaningFixtures.farToneA
        func farEndEnergy(_ location: TrackAudioLocation) throws -> Double {
            let samples = try MicrophoneCleaningFixtures.samples(location)
            return MicrophoneCleaningFixtures.toneEnergy(
                MicrophoneCleaningFixtures.seconds(20, 30, of: samples), frequency: far
            )
        }
        let recorded = try farEndEnergy(
            store.rawTrackAudioLocation(track: .mic, metadata: metadata, timeline: timeline)
        )
        let cleanedAway = try farEndEnergy(
            store.trackAudioLocation(track: .mic, metadata: metadata, timeline: timeline)
        )

        metadata = try store.updateMetadata {
            $0.processing = ProcessingStatus(state: .complete, updatedAt: $0.startedAt)
        }
        #expect(try AudioCompactor().compact(store: store) == AudioCompactor.Outcome.compacted)
        #expect(
            !(FileManager.default.fileExists(atPath: store.layout.segments.path)),
            "the segments are gone, so the archive is the only copy of the recording"
        )

        // What is in `mic.m4a` now decides whether the recording survived.
        let archived = try store.readMetadata()
        #expect(archived.audioArchive?.mic != nil, "the microphone was archived")
        let inArchive = try farEndEnergy(
            store.rawTrackAudioLocation(track: .mic, metadata: archived, timeline: timeline)
        )
        let keptDB = 10 * log10((inArchive + 1e-12) / (cleanedAway + 1e-12))
        #expect(
            keptDB > 20,
            """
            mic.m4a holds the far end only \(keptDB) dB above the cleaned track, so it was \
            written from the cleaned microphone
            """
        )
        let lostDB = 10 * log10((recorded + 1e-12) / (inArchive + 1e-12))
        #expect(abs(lostDB) < 3, "the archived far end is \(lostDB) dB off the recording")

        // And the cleaned track outlives the segments it was made from.
        #expect(
            FileManager.default.fileExists(atPath: store.layout.cleanedMicFile.path),
            "compaction left the cleaned track alone"
        )
        #expect(store.trackAudioLocation(track: .mic, metadata: archived, timeline: timeline)
                .segments.first?.file == "mic.cleaned.m4a")
        #expect(store.rawTrackAudioLocation(track: .mic, metadata: archived, timeline: timeline)
                .segments.first?.file == "mic.m4a")
    }

    @Test("an interrupted deletion resumes once the archive is recorded")
    func anInterruptedDeletionResumesOnceTheArchiveIsRecorded() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try Self.makeCompleteMeeting(root: root)
        let store = meeting.store
        _ = try AudioCompactor().compact(store: store)

        // A crash between the metadata write and the deletion leaves both
        // representations on disk. Recreate that state.
        try FileManager.default.createDirectory(
            at: store.layout.segments, withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(to: store.layout.segments.appendingPathComponent("mic.0001.caf"))
        try Data("stale".utf8).write(to: store.layout.legacyMixedAudio)

        let metadata = try store.readMetadata()
        #expect(AudioCompactor.hasWork(store: store, metadata: metadata))
        let outcome = try AudioCompactor().compact(store: store)
        #expect(outcome == AudioCompactor.Outcome.compacted)
        #expect(!(FileManager.default.fileExists(atPath: store.layout.segments.path)))
        #expect(!(FileManager.default.fileExists(atPath: store.layout.legacyMixedAudio.path)))
        let after = try store.readMetadata()
        #expect(!(AudioCompactor.hasWork(store: store, metadata: after)))
    }

    @Test("the mixdown regenerates from the archives after the segments are gone")
    func theMixdownRegeneratesFromTheArchivesAfterTheSegmentsAreGone() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // The remote source starts a second late, as it does when the tap
        // comes up before the microphone. Alignment must survive the
        // segments' deletion because the host times move into the archive.
        let meeting = try Self.makeCompleteMeeting(root: root, remoteStartOffset: 1)
        let store = meeting.store
        _ = try AudioCompactor().compact(store: store)
        try FileManager.default.removeItem(at: store.layout.recordingAudio)

        let metadata = try store.readMetadata()
        let timeline = try store.readTimeline()
        try AudioMixer().mix(
            mic: store.trackAudioLocation(track: .mic, metadata: metadata, timeline: timeline),
            remote: store.trackAudioLocation(track: .remote, metadata: metadata, timeline: timeline),
            to: store.layout.recordingAudio
        )
        let info = try AudioFileInspector().inspect(url: store.layout.recordingAudio)
        // Mic runs 0-6, remote 1-7: the aligned mix is 7 seconds.
        #expect(abs((info.seconds) - (7)) <= 0.5, "expected 7 ± 0.5, got \(info.seconds)")
    }

    @Test("a complete meeting with no audio compacts to nothing and leaves the sweep")
    func aCompleteMeetingWithNoAudioCompactsToNothingAndLeavesTheSwee() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root)
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .manual, provider: .unknown, startedAt: started,
            titles: TitleCandidates(timestampFallback: "empty"), now: started
        )
        let metadata = try created.store.updateMetadata {
            $0.processing = ProcessingStatus(state: .complete, updatedAt: started)
        }
        #expect(AudioCompactor.hasWork(store: created.store, metadata: metadata))

        let outcome = try AudioCompactor().compact(store: created.store)
        #expect(outcome == AudioCompactor.Outcome.nothingToDo)
        let after = try created.store.readMetadata()
        #expect(
            !(AudioCompactor.hasWork(store: created.store, metadata: after)),
            "the empty segments directory is cleaned up so the sweep does not retry forever"
        )
    }

    @Test("the archive is recorded before anything is deleted")
    func theArchiveIsRecordedBeforeAnythingIsDeleted() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try Self.makeCompleteMeeting(root: root)
        let store = meeting.store

        // One segment file refuses deletion. The transcode and the metadata
        // write must both have happened by the time the delete throws, or
        // the ordering the whole design rests on is broken.
        let fileManager = FileManager.default
        let locked = try #require(
            try fileManager.contentsOfDirectory(
                at: store.layout.segments, includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix("mic.") },
            "fixture wrote no mic segment"
        )
        try fileManager.setAttributes([.immutable: true], ofItemAtPath: locked.path)

        var thrown: (any Error)?
        do { _ = try AudioCompactor().compact(store: store) } catch { thrown = error }
        try fileManager.setAttributes([.immutable: false], ofItemAtPath: locked.path)

        #expect(thrown != nil, "the refused delete surfaces")
        let metadata = try store.readMetadata()
        #expect(
            metadata.audioArchive != nil,
            "the archive was recorded before deletion was attempted"
        )
        #expect(
            fileManager.fileExists(atPath: locked.path),
            "the undeletable segment is still there"
        )

        // With the lock lifted the next sweep finishes the job.
        let outcome = try AudioCompactor().compact(store: store)
        #expect(outcome == AudioCompactor.Outcome.compacted)
        #expect(!(fileManager.fileExists(atPath: store.layout.segments.path)))
    }

    @Test("a failure on the second track records no archive and keeps every segment")
    func aFailureOnTheSecondTrackRecordsNoArchiveAndKeepsEverySegment() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try Self.makeCompleteMeeting(root: root)
        let store = meeting.store

        // The mic track (first in CaptureTrack.allCases) exports and is
        // promoted; the system track then comes up empty. Nothing may be
        // recorded and nothing deleted, or the mic segments would be
        // removed on the next sweep while the system audio has no archive.
        for file in try FileManager.default.contentsOfDirectory(
            at: store.layout.segments, includingPropertiesForKeys: nil
        ) where file.lastPathComponent.hasPrefix("system.") {
            try FileManager.default.removeItem(at: file)
        }

        var thrown: (any Error)?
        do { _ = try AudioCompactor().compact(store: store) } catch { thrown = error }
        #expect(thrown != nil)
        #expect(try store.readMetadata().audioArchive == nil)
        let micSegments = try FileManager.default.contentsOfDirectory(
            at: store.layout.segments, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("mic.") }
        #expect(!micSegments.isEmpty, "the mic segments survive the failed run")
    }

    @Test("a file the manifest does not account for survives compaction")
    func aFileTheManifestDoesNotAccountForSurvivesCompaction() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try Self.makeCompleteMeeting(root: root)
        let store = meeting.store
        _ = try AudioCompactor().compact(store: store)

        // A leftover state holding one file the archive covered and one it
        // never saw: only the covered one goes.
        try FileManager.default.createDirectory(
            at: store.layout.segments, withIntermediateDirectories: true
        )
        let covered = store.layout.segments.appendingPathComponent("mic.0001.caf")
        let unknown = store.layout.segments.appendingPathComponent("mic.9999.caf")
        try Data("covered".utf8).write(to: covered)
        try Data("unknown".utf8).write(to: unknown)

        _ = try AudioCompactor().compact(store: store)
        #expect(
            !(FileManager.default.fileExists(atPath: covered.path)),
            "the manifest-known file the archive replaced is removed"
        )
        #expect(
            FileManager.default.fileExists(atPath: unknown.path),
            "audio the manifest does not account for is never deleted"
        )
    }

    @Test("a missing archive file stops deletion cold")
    func aMissingArchiveFileStopsDeletionCold() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try Self.makeCompleteMeeting(root: root)
        let store = meeting.store
        _ = try AudioCompactor().compact(store: store)

        // The archive record survives a restore; the archive file did not.
        // The recreated segments are now the only audio, and the resume
        // path must refuse to touch them.
        try FileManager.default.removeItem(at: store.layout.trackArchiveFile(track: .mic))
        try FileManager.default.createDirectory(
            at: store.layout.segments, withIntermediateDirectories: true
        )
        let survivor = store.layout.segments.appendingPathComponent("mic.0001.caf")
        try Data("the only copy".utf8).write(to: survivor)

        var thrown: (any Error)?
        do { _ = try AudioCompactor().compact(store: store) } catch { thrown = error }
        #expect(thrown != nil, "verification refuses the missing archive")
        #expect(FileManager.default.fileExists(atPath: survivor.path), "nothing was deleted")
    }

    @Test("the archive starts where the PCM started")
    func theArchiveStartsWhereThePCMStarted() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root)
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .manual, provider: .unknown, startedAt: started,
            titles: TitleCandidates(timestampFallback: "offset"), now: started
        )
        let manifest = try ManifestWriter(url: created.store.layout.manifest)
        manifest.append(.sessionStart(.init(
            meetingID: created.metadata.id, source: .manual, segmentSeconds: 30,
            appVersion: "test", processID: 1
        )))
        let writer = SegmentWriter(
            track: .mic, layout: created.store.layout, manifest: manifest,
            format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!,
            segmentSeconds: 30
        )
        // One second of silence, then two of tone. AAC encoder priming that
        // leaked into the timeline would shift the onset by ~0.13 s, which
        // every word timing and diarization boundary would inherit.
        writer.enqueueSynchronously(AudioBufferPacket(
            buffer: AudioFixtures.makeTone(seconds: 1, sampleRate: 48_000, amplitude: 0), hostTime: 100
        ))
        writer.enqueueSynchronously(AudioBufferPacket(
            buffer: AudioFixtures.makeTone(seconds: 2, sampleRate: 48_000), hostTime: 101
        ))
        writer.finish(reason: "test")
        manifest.append(.sessionEnd(.init(reason: "test", micSeconds: 3, remoteSeconds: 0)))
        manifest.close()
        _ = try created.store.updateMetadata {
            $0.processing = ProcessingStatus(state: .complete, updatedAt: started)
        }

        _ = try AudioCompactor().compact(store: created.store)

        let metadata = try created.store.readMetadata()
        let timeline = try created.store.readTimeline()
        let location = created.store.trackAudioLocation(
            track: .mic, metadata: metadata, timeline: timeline
        )
        let stream = TrackAudioStream(
            segments: location.segments,
            segmentsDirectory: location.directory,
            format: AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1)
        )
        var firstLoudFrame: Int64 = -1
        var position: Int64 = 0
        try stream.forEachBuffer(from: 0, to: 3) { buffer, _ in
            if firstLoudFrame < 0, let data = buffer.floatChannelData {
                for frame in 0..<Int(buffer.frameLength) where abs(data[0][frame]) > 0.05 {
                    firstLoudFrame = position + Int64(frame)
                    break
                }
            }
            position += Int64(buffer.frameLength)
            return firstLoudFrame < 0
        }
        #expect(firstLoudFrame >= 0, "the tone is in the archive")
        #expect(
            abs((Double(firstLoudFrame) / 16_000) - (1.0)) <= 0.1,
            "expected 1.0 ± 0.1, got \(Double(firstLoudFrame) / 16_000)"
        )
    }

    @Test("the startup sweep compacts a folded continuation")
    func theStartupSweepCompactsAFoldedContinuation() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = try Self.makeCompleteMeeting(root: root)
        let folded = try Self.makeCompleteMeeting(root: root)
        _ = try folded.store.updateMetadata { $0.mergedIntoMeetingID = primary.metadata.id }
        _ = try primary.store.updateMetadata { $0.absorbedMeetingIDs = [folded.metadata.id] }

        let pipeline = PipelineFixtures.makePipeline(
            repository: MeetingRepository(root: root), backend: FakeAIBackend()
        )
        await pipeline.compactPending()

        for store in [primary.store, folded.store] {
            #expect(
                try store.readMetadata().audioArchive != nil,
                "the hidden continuation compacts like the meeting it folded into"
            )
            #expect(!(FileManager.default.fileExists(atPath: store.layout.segments.path)))
        }
    }

    @Test("compaction after complete waits for the recording gate")
    func compactionAfterCompleteWaitsForTheRecordingGate() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try Self.makeCompleteMeeting(root: root)
        let store = meeting.store

        let capture = LockedBox(RecordingAwareGate.CaptureState.recording)
        let gate = RecordingAwareGate(pollSeconds: 0.05) { capture.withLock { $0 } }
        let pipeline = ProcessingPipeline(
            repository: MeetingRepository(root: root),
            backend: FakeAIBackend(),
            gate: gate,
            clock: ManualClock(),
            settingsProvider: { AppSettings() },
            wait: { _ in }
        )

        let job = Task { await pipeline.process(meetingID: meeting.metadata.id) }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(
            FileManager.default.fileExists(atPath: store.layout.segments.path),
            "nothing is transcoded or deleted while a recording is live"
        )
        #expect(try store.readMetadata().audioArchive == nil)

        capture.withLock { $0 = .idle }
        await job.value
        #expect(try store.readMetadata().audioArchive != nil)
        #expect(!(FileManager.default.fileExists(atPath: store.layout.segments.path)))
    }

    @Test("recovery waits for a folder whose migration has not run")
    func recoveryWaitsForAFolderWhoseMigrationHasNotRun() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let made = try PipelineFixtures.makeRecordedMeeting(root: root)
        let store = made.store
        let layout = store.layout
        _ = try store.updateMetadata {
            $0.processing = ProcessingStatus(state: .recording, updatedAt: $0.startedAt)
        }

        // The folder as an old build left it after a crash: everything at
        // the root, and this launch's migration failed to move it.
        let fileManager = FileManager.default
        try fileManager.moveItem(at: layout.metadata, to: layout.legacyMetadata)
        try fileManager.moveItem(at: layout.segments, to: layout.legacySegments)
        try fileManager.moveItem(at: layout.manifest, to: layout.legacyManifest)
        try fileManager.removeItem(at: layout.raw)

        let scanner = RecoveryScanner(
            repository: MeetingRepository(root: root), inspector: AudioFileInspector()
        )
        let report = scanner.scan()
        #expect(report.recovered.count == 0)

        // The failure mode this pins: recovery must not open a fresh empty
        // manifest at the new path, which would shadow the real one and
        // block the manifest's migration forever.
        #expect(
            !(fileManager.fileExists(atPath: layout.manifest.path)),
            "no empty manifest was created at the new path"
        )
        let metadata = try store.readMetadata()
        #expect(metadata.processing.state == ProcessingState.recording)

        // Once the migration succeeds, recovery proceeds normally.
        try MeetingLayoutMigration.migrate(layout: layout)
        let second = scanner.scan()
        #expect(second.recovered.count == 1)
        #expect(try store.readMetadata().processing.state == ProcessingState.audioSafe)
    }

    @Test("an old-layout folder migrates to raw/ and reads the same")
    func anOldLayoutFolderMigratesToRawAndReadsTheSame() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let made = try PipelineFixtures.makeRecordedMeeting(root: root)
        let store = made.store
        let layout = store.layout
        let originalID = made.metadata.id
        let originalTimeline = try store.readTimeline()

        // Rebuild the folder exactly as the previous build laid it out:
        // everything at the root, the manifest inside segments/.
        let fileManager = FileManager.default
        try fileManager.moveItem(at: layout.metadata, to: layout.legacyMetadata)
        try fileManager.moveItem(at: layout.segments, to: layout.legacySegments)
        try fileManager.moveItem(at: layout.manifest, to: layout.legacyManifest)
        try fileManager.removeItem(at: layout.raw)

        // Before migration the metadata still reads, through the fallback.
        #expect(try store.readMetadata().id == originalID)
        #expect(MeetingLayoutMigration.needsMigration(layout: layout))

        // Compaction refuses the folder while it is unmigrated: a metadata
        // write here would create raw/metadata.json and permanently block
        // that file's move.
        #expect(try AudioCompactor().compact(store: store) == AudioCompactor.Outcome.nothingToDo)
        #expect(
            !(fileManager.fileExists(atPath: layout.metadata.path)),
            "no raw/metadata.json shadow was created"
        )

        let repository = MeetingRepository(root: root)
        let result = repository.migrateLayouts()
        #expect(result.migrated == 1)
        #expect(result.failed == 0)

        #expect(!(MeetingLayoutMigration.needsMigration(layout: layout)))
        #expect(try store.readMetadata().id == originalID)
        #expect(try store.readTimeline() == originalTimeline)
        #expect(fileManager.fileExists(atPath: layout.manifest.path))
        #expect(!(fileManager.fileExists(atPath: layout.legacyMetadata.path)))
        #expect(!(fileManager.fileExists(atPath: layout.legacySegments.path)))

        // Running it again moves nothing.
        let second = repository.migrateLayouts()
        #expect(second.migrated == 0)
    }

}
