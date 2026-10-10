import Foundation
import PipitCore
import PipitServices
import Testing

/// Cleaning the microphone and transcribing it again, on a meeting that was
/// finished under an older cleaning rule.
///
/// The fixture is a call taken on speakers, which the shipped canceller does
/// clean, finished first with the cleaning outcome already recorded as
/// bypassed. That is what a meeting from before the current canceller looks
/// like to the pipeline: an answer on file, so the cleaner never runs again.
@Suite("MicrophoneRedo")
struct MicrophoneRedoTests {
    private static let farEndWords = RawTranscriptSegment(
        start: 0, end: 5, text: "we should look at the plan", speaker: nil,
        words: [
            RawTranscriptWord(start: 0.0, end: 0.4, text: " we"),
            RawTranscriptWord(start: 0.5, end: 0.9, text: " should"),
            RawTranscriptWord(start: 1.0, end: 1.4, text: " look"),
            RawTranscriptWord(start: 1.5, end: 1.9, text: " at"),
            RawTranscriptWord(start: 2.0, end: 2.4, text: " the"),
            RawTranscriptWord(start: 2.5, end: 2.9, text: " plan"),
        ]
    )

    /// What the microphone said before: the far end's own sentence, arriving
    /// through the speakers.
    private static let echoedMicrophone = RawTranscriptSegment(
        start: 1, end: 4, text: "deployment before friday", speaker: nil,
        words: [
            RawTranscriptWord(start: 1.0, end: 1.6, text: " deployment"),
            RawTranscriptWord(start: 1.7, end: 2.2, text: " before"),
            RawTranscriptWord(start: 2.3, end: 3.0, text: " friday"),
        ]
    )

    /// What the cleaned microphone says: only the user.
    private static let cleanedMicrophone = RawTranscriptSegment(
        start: 1, end: 4, text: "budget needs another pass", speaker: nil,
        words: [
            RawTranscriptWord(start: 1.0, end: 1.5, text: " budget"),
            RawTranscriptWord(start: 1.6, end: 2.1, text: " needs"),
            RawTranscriptWord(start: 2.2, end: 2.6, text: " another"),
            RawTranscriptWord(start: 2.7, end: 3.1, text: " pass"),
        ]
    )

    private static var settings: AppSettings {
        var settings = AppSettings()
        settings.enrichment = EnrichmentSettings(
            generateTitle: false, generateDescription: false, generateNotes: false,
            generateSummary: false, suggestSpeakers: false
        )
        return settings
    }

    private static func makePipeline(
        meeting: (metadata: MeetingMetadata, store: MeetingStore, repository: MeetingRepository),
        transcriber: StubLocalTranscriber, root: URL
    ) -> ProcessingPipeline {
        let diarizer = StubLocalDiarizer(
            intervals: [DiarizationInterval(start: 0, end: 5, clusterID: "S1")],
            chunkEmbeddings: [
                DiarizationChunkEmbedding(
                    clusterID: "S1", start: 0, end: 5, vector: SpeakerFixtures.vector(seed: 61)
                )
            ]
        )
        return PipelineFixtures.makePipeline(
            repository: meeting.repository, backend: FakeAIBackend(),
            transcriber: transcriber, diarizer: diarizer, speakers: nil,
            settings: settings, scratchRoot: root.appendingPathComponent("scratch")
        )
    }

    @Test("redoing the microphone cleans it again and transcribes only it")
    func redoingTheMicrophoneCleansItAgainAndTranscribesOnlyIt() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try MicrophoneCleaningFixtures.makeCallOnSpeakers(root: root)
        let store = meeting.store
        // The answer a pre-0.1.7 build left: the pass ran, kept the
        // recording, and is on file, so it never runs again.
        _ = try store.updateMetadata { $0.cleaningOutcome = .bypassedNoEchoPath }

        let transcriber = StubLocalTranscriber(segments: [Self.farEndWords])
        transcriber.micSegments = [Self.echoedMicrophone]
        let pipeline = Self.makePipeline(meeting: meeting, transcriber: transcriber, root: root)
        await pipeline.process(meetingID: meeting.metadata.id)
        #expect(try store.readMetadata().processing.state == .complete)
        #expect(try store.readMetadata().cleanedMic == nil, "the first pass left the recording")

        // What a person did to the meeting afterwards.
        let before = try #require(try store.readCanonicalTranscript())
        let remoteBefore = before.utterances.filter { $0.track == .remote }
        let micBefore = before.utterances.filter { $0.track == .mic }
        #expect(!remoteBefore.isEmpty)
        #expect(micBefore.map(\.text).joined().contains("deployment"))
        let remoteLine = try #require(remoteBefore.first)
        let micLine = try #require(micBefore.first)
        let farSpeaker = remoteLine.speakerKey
        let when = Date(timeIntervalSince1970: 1_787_080_000)
        var speakers = try store.readSpeakerMap()
        speakers.assign("Ada", to: farSpeaker)
        speakers.overrideUtterance(
            remoteLine,
            with: SpeakerAssignment(displayName: "Grace", origin: .human, provenance: .human()),
            at: when
        )
        speakers.overrideUtterance(
            micLine,
            with: SpeakerAssignment(displayName: "Ada", origin: .human, provenance: .human()),
            at: when
        )
        speakers.cut(
            LineCut(track: .mic, atSeconds: 2, chunkID: micLine.chunkID, createdAt: when))
        speakers.cut(
            LineCut(track: .remote, atSeconds: 1, chunkID: remoteLine.chunkID, createdAt: when))
        try store.writeSpeakerMap(speakers)
        _ = try store.updateMetadata {
            $0.titles.human = "Renamed by hand"
        }
        try Data("notes the user typed".utf8).write(to: store.layout.notes)
        try Data("# a summary".utf8).write(to: store.layout.summary)

        let remoteRawBefore = try store.readRawTranscript().chunks(track: .remote)
        let diarizationBefore = try Data(contentsOf: store.layout.rawDiarization)
        let transcriptBefore = try Data(contentsOf: store.layout.canonicalTranscript)
        let rawBefore = try Data(contentsOf: store.layout.rawTranscript)
        let mixdownBefore = try Data(contentsOf: store.layout.recordingAudio)
        let remoteReadsBefore = transcriber.received.filter { !$0.hasPrefix("mic") }.count
        let micReadsBefore = transcriber.received.filter { $0.hasPrefix("mic") }.count
        #expect(remoteReadsBefore == 1)
        #expect(micReadsBefore == 1)

        transcriber.micSegments = [Self.cleanedMicrophone]
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        try await pipeline.redoMicrophone(meetingID: meeting.metadata.id, backups: backups)

        // The cleaner ran again, on the recording, and its result is what is read.
        let metadata = try store.readMetadata()
        #expect(metadata.cleaningOutcome == CleaningOutcome.cleaned)
        let cleaned = try #require(metadata.cleanedMic)
        #expect(cleaned.track.file == "mic.cleaned.m4a")
        #expect(FileManager.default.fileExists(atPath: store.layout.cleanedMicFile.path))
        #expect(metadata.processing.state == .complete)
        #expect(metadata.microphoneRedoRequestedAt == nil)

        // Only the microphone was transcribed again.
        #expect(transcriber.received.filter { $0.hasPrefix("mic") }.count == micReadsBefore + 1)
        #expect(transcriber.received.filter { !$0.hasPrefix("mic") }.count == remoteReadsBefore)
        let raw = try store.readRawTranscript()
        #expect(raw.chunks(track: .remote) == remoteRawBefore, "the far end's words are untouched")
        let micText = raw.chunks(track: .mic).flatMap(\.segments).map(\.text).joined(separator: " ")
        #expect(micText == Self.cleanedMicrophone.text)
        #expect(
            try Data(contentsOf: store.layout.rawDiarization) == diarizationBefore,
            "the diarization runs are untouched"
        )

        // The transcript says the new words on the microphone and the old ones
        // on the far end.
        let after = try #require(try store.readCanonicalTranscript())
        #expect(after.utterances.filter { $0.track == .remote } == remoteBefore)
        let micAfter = after.utterances.filter { $0.track == .mic }
        #expect(!micAfter.isEmpty)
        #expect(micAfter.map(\.text).joined(separator: " ").contains("budget"))
        #expect(!micAfter.map(\.text).joined(separator: " ").contains("deployment"))
        let markdown = try #require(store.readTranscriptMarkdown())
        #expect(markdown.contains("budget"))
        #expect(!markdown.contains("deployment"))
        #expect(
            try Data(contentsOf: store.layout.recordingAudio) != mixdownBefore,
            "the mixdown holds the cleaned microphone"
        )

        // Names and corrections on the far end stay. Edits to the user's own
        // lines cannot outlive the lines.
        let kept = try store.readSpeakerMap()
        #expect(kept.entries[farSpeaker]?.displayName == "Ada")
        #expect(kept.entries[SpeakerLabel.localUser]?.origin == .deterministic)
        #expect(kept.utteranceOverrides.map(\.track) == [.remote])
        #expect(kept.utteranceOverrides.first?.assignment.displayName == "Grace")
        #expect(kept.lineCuts.map(\.track) == [.remote])
        #expect(metadata.titles.human == "Renamed by hand")
        #expect(try String(contentsOf: store.layout.notes, encoding: .utf8) == "notes the user typed")
        #expect(try String(contentsOf: store.layout.summary, encoding: .utf8) == "# a summary")

        // What was replaced is kept.
        let kept1 = try FileManager.default.contentsOfDirectory(
            at: backups.appendingPathComponent(metadata.id), includingPropertiesForKeys: nil
        )
        let backup = try #require(kept1.first)
        let backedUpRaw = backup.appendingPathComponent("raw/transcript.raw.json")
        #expect(try Data(contentsOf: backedUpRaw) == rawBefore)
        #expect(
            try Data(contentsOf: backup.appendingPathComponent("raw/transcript.json"))
                == transcriptBefore
        )
        let backedUpMap = try ArchiveCoding.decode(
            SpeakerMap.self,
            from: Data(contentsOf: backup.appendingPathComponent("raw/speakers.map.json")),
            path: "backup"
        )
        #expect(backedUpMap.microphoneLineEditCount == 2, "the user's own line edits are in the backup")
        #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("recording.m4a").path))
    }

    @Test("an interrupted redo is finished by the next run and the far end is not read again")
    func anInterruptedRedoIsFinishedByTheNextRun() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try MicrophoneCleaningFixtures.makeCallOnSpeakers(root: root)
        let store = meeting.store
        _ = try store.updateMetadata { $0.cleaningOutcome = .bypassedNoEchoPath }
        let transcriber = StubLocalTranscriber(segments: [Self.farEndWords])
        transcriber.micSegments = [Self.echoedMicrophone]
        let pipeline = Self.makePipeline(meeting: meeting, transcriber: transcriber, root: root)
        await pipeline.process(meetingID: meeting.metadata.id)

        // The state a crash leaves after the request was recorded and nothing
        // else happened: the marker is set and the stage is waiting.
        _ = try store.updateMetadata {
            $0.microphoneRedoRequestedAt = Date(timeIntervalSince1970: 1_787_090_000)
            $0.cleaningOutcome = nil
            $0.processing.advance(to: .transcribing, at: Date(timeIntervalSince1970: 1_787_090_000))
        }
        let before = try #require(try store.readCanonicalTranscript())
        #expect(
            before.utterances.contains { $0.track == .mic },
            "until the new words land the old transcript still reads"
        )

        transcriber.micSegments = [Self.cleanedMicrophone]
        await pipeline.resumeInterrupted()

        let metadata = try store.readMetadata()
        #expect(metadata.processing.state == .complete)
        #expect(metadata.microphoneRedoRequestedAt == nil)
        #expect(metadata.cleaningOutcome == CleaningOutcome.cleaned)
        #expect(transcriber.received.filter { !$0.hasPrefix("mic") }.count == 1)
        let after = try #require(try store.readCanonicalTranscript())
        #expect(
            after.utterances.filter { $0.track == .mic }.map(\.text).joined().contains("budget")
        )
    }

    @Test("a redo reads the recording, so a second one cleans it again")
    func aRedoReadsTheRecordingSoASecondOneCleansItAgain() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try MicrophoneCleaningFixtures.makeCallOnSpeakers(root: root)
        let transcriber = StubLocalTranscriber(segments: [Self.farEndWords])
        transcriber.micSegments = [Self.cleanedMicrophone]
        let pipeline = Self.makePipeline(meeting: meeting, transcriber: transcriber, root: root)
        await pipeline.process(meetingID: meeting.metadata.id)
        let first = try meeting.store.readMetadata()
        #expect(first.cleaningOutcome == CleaningOutcome.cleaned)

        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        try await pipeline.redoMicrophone(meetingID: meeting.metadata.id, backups: backups)

        // Cleaning the cleaned track finds no echo path and throws the result
        // away, so staying cleaned means the recording was the input.
        let second = try meeting.store.readMetadata()
        #expect(second.cleaningOutcome == CleaningOutcome.cleaned)
        let after = try #require(second.cleanedMic)
        #expect(after.echoRemovedMedianDB > 6, "and it took the far end down by a real margin")
    }

    @Test("a recording with one track refuses and is left as it was")
    func aRecordingWithOneTrackRefusesAndIsLeftAsItWas() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try PipelineFixtures.makeRecordedMeeting(root: root, source: .inPerson)
        let transcriber = StubLocalTranscriber(segments: [Self.farEndWords])
        let pipeline = Self.makePipeline(meeting: meeting, transcriber: transcriber, root: root)
        await pipeline.process(meetingID: meeting.metadata.id)
        let before = try Data(contentsOf: meeting.store.layout.metadata)
        let rawBefore = try Data(contentsOf: meeting.store.layout.rawTranscript)
        #expect(!meeting.metadata.canRedoMicrophone)

        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        await #expect(throws: MicrophoneRedoError.oneTrack) {
            try await pipeline.redoMicrophone(meetingID: meeting.metadata.id, backups: backups)
        }
        #expect(try Data(contentsOf: meeting.store.layout.metadata) == before)
        #expect(try Data(contentsOf: meeting.store.layout.rawTranscript) == rawBefore)
        #expect(!FileManager.default.fileExists(atPath: backups.path), "nothing was backed up")
    }

    @Test("an unfinished meeting refuses")
    func anUnfinishedMeetingRefuses() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try PipelineFixtures.makeRecordedMeeting(root: root)
        let transcriber = StubLocalTranscriber(segments: [Self.farEndWords])
        let pipeline = Self.makePipeline(meeting: meeting, transcriber: transcriber, root: root)
        #expect(meeting.metadata.processing.state == .audioSafe)

        await #expect(throws: MicrophoneRedoError.notFinished) {
            try await pipeline.redoMicrophone(
                meetingID: meeting.metadata.id,
                backups: root.appendingPathComponent("Backups", isDirectory: true)
            )
        }
    }

    @Test("removing microphone line edits keeps the far end's")
    func removingMicrophoneLineEditsKeepsTheFarEnds() {
        let when = Date(timeIntervalSince1970: 1_787_080_000)
        let assignment = SpeakerAssignment(displayName: "Ada", origin: .human)
        var map = SpeakerMap()
        map.utteranceOverrides = [
            UtteranceOverride(track: .mic, anchorSeconds: 1, assignment: assignment, createdAt: when),
            UtteranceOverride(track: .remote, anchorSeconds: 1, assignment: assignment, createdAt: when),
        ]
        map.lineCuts = [
            LineCut(track: .mic, atSeconds: 3, createdAt: when),
            LineCut(track: .remote, atSeconds: 3, createdAt: when),
        ]
        map.assign("Ada", to: "remote-001_speaker_00")

        #expect(map.microphoneLineEditCount == 2)
        #expect(map.removeMicrophoneLineEdits() == 2)
        #expect(map.utteranceOverrides.map(\.track) == [.remote])
        #expect(map.lineCuts.map(\.track) == [.remote])
        #expect(map.entries["remote-001_speaker_00"]?.displayName == "Ada")
        #expect(map.removeMicrophoneLineEdits() == 0)
    }
}
