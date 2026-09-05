import Foundation
import PipitCore
import PipitServices
import Testing

@Suite("Reprocessing")
struct ReprocessingTests {
    @Test("a reset removes what was derived and keeps the recording and the names")
    func aResetRemovesWhatWasDerivedAndKeepsTheRecordingAndTheNames() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let made = try PipelineFixtures.makeRecordedMeeting(root: root, seconds: 4)
        let store = made.store
        let layout = store.layout
        try Data("{}".utf8).write(to: layout.rawTranscript)
        try Data("{}".utf8).write(to: layout.canonicalTranscript)
        try Data("{}".utf8).write(to: layout.speechEvidence)
        try Data("# notes".utf8).write(to: layout.transcriptMarkdown)
        var speakers = SpeakerMap()
        speakers.assign("Ada", to: "remote-001_speaker_00")
        try store.writeSpeakerMap(speakers)
        _ = try store.updateMetadata {
            $0.processing = ProcessingStatus(state: .complete, updatedAt: $0.startedAt)
            $0.cleaningOutcome = .bypassedNoEchoPath
        }
        let manifestBefore = try Data(contentsOf: layout.manifest)
        let segmentsBefore = try FileManager.default.contentsOfDirectory(atPath: layout.segments.path)

        let backup = root.appendingPathComponent("backup", isDirectory: true)
        try Reprocessing.backUp(store: store, to: backup)
        let metadata = try Reprocessing.reset(store: store)

        #expect(metadata.processing.state == ProcessingState.audioSafe)
        #expect(metadata.cleaningOutcome == nil, "the cleaner runs again")
        #expect(!FileManager.default.fileExists(atPath: layout.rawTranscript.path))
        #expect(!FileManager.default.fileExists(atPath: layout.canonicalTranscript.path))
        #expect(!FileManager.default.fileExists(atPath: layout.speechEvidence.path))
        #expect(!FileManager.default.fileExists(atPath: layout.transcriptMarkdown.path))
        #expect(FileManager.default.fileExists(atPath: layout.speakerMap.path), "typed names stay")
        let speakerMap = try store.readSpeakerMap()
        #expect(speakerMap.entries["remote-001_speaker_00"]?.displayName == "Ada")
        let manifestAfter = try Data(contentsOf: layout.manifest)
        #expect(manifestAfter == manifestBefore, "the manifest is untouched")
        let segmentsAfter = try FileManager.default.contentsOfDirectory(atPath: layout.segments.path)
            .sorted()
        #expect(segmentsAfter == segmentsBefore.sorted(), "the recording is untouched")
        let backedUp = backup.appendingPathComponent("raw/transcript.raw.json")
        #expect(
            FileManager.default.fileExists(atPath: backedUp.path),
            "the backup holds the transcript"
        )
        #expect(
            FileManager.default.fileExists(atPath: backup.appendingPathComponent("raw/metadata.json").path),
            "the backup holds the metadata"
        )
    }
}
