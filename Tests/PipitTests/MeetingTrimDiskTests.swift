import AVFoundation
import Foundation
import PipitAudio
import PipitCore
import PipitServices
import Testing

/// Trim on meetings written to disk: what each file holds afterwards, and what
/// an interruption leaves.
@Suite("MeetingTrimDisk")
struct MeetingTrimDiskTests {
    private static let at = TrimFixtures.started.addingTimeInterval(60)

    private static func trimmer(stopAtSwap: Int? = nil) -> MeetingTrimmer {
        guard let stopAtSwap else { return MeetingTrimmer() }
        return MeetingTrimmer(beforeSwap: { position in
            if position == stopAtSwap { throw TrimError.filesNotWritten }
        })
    }

    // MARK: two tracks

    @Test("a far end that started late keeps its offset, and the manifest matches the archives")
    func aLateFarEndKeepsItsOffset() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrimFixtures.makeCompacted(root: root, remoteStartOffset: 5)
        _ = try store.updateMetadata {
            $0.descriptionText = "A description of the whole meeting"
            $0.titles.ai = "A title from the whole meeting"
            $0.processing.attempts[ProcessingState.enriching.rawValue] = 3
        }

        let range = try #require(TrimRange(start: 2, end: 12, duration: 20))
        try Self.trimmer().trim(store: store, to: range, at: Self.at)

        let metadata = try store.readMetadata()
        let archive = try #require(metadata.audioArchive)
        #expect(abs(try #require(archive.mic?.seconds) - 10) < 0.1)
        #expect(
            abs(try #require(archive.remote?.seconds) - 7) < 0.1,
            "the far end began at 5 s, so 7 s of it fall in 2 to 12")
        #expect(abs(metadata.durationSeconds - 10) < 0.1)
        #expect(metadata.descriptionText == nil, "the description is written again from what is left")
        #expect(metadata.titles.ai == nil, "a generated title does not outlive the speech it came from")
        #expect(metadata.processing.attempts[ProcessingState.enriching.rawValue] == nil, "enrichment starts afresh")
        #expect(metadata.trimmedAt == Self.at)

        let timeline = try store.readTimeline()
        #expect(abs(timeline.duration(track: .mic) - 10) < 0.1, "got \(timeline.duration(track: .mic))")
        #expect(abs(timeline.duration(track: .remote) - 7) < 0.1, "got \(timeline.duration(track: .remote))")
        #expect(
            abs(timeline.leadIn(track: .remote) - 3) < 0.01,
            "the far end still starts 3 s in, got \(timeline.leadIn(track: .remote))")
        #expect(timeline.leadIn(track: .mic) == 0)
    }

    @Test("keeping to the end keeps each track to its own last second")
    func keepingToTheEndKeepsEachTrackToItsOwnEnd() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // The far end starts 5 s late, so the meeting runs to 25 s on its
        // timeline while its recorded length is 20 s.
        let store = try TrimFixtures.makeCompacted(root: root, remoteStartOffset: 5)

        let range = try #require(TrimRange(start: 2, end: 25, duration: 20, toEnd: true))
        try Self.trimmer().trim(store: store, to: range, at: Self.at)

        let archive = try #require(try store.readMetadata().audioArchive)
        #expect(
            abs(try #require(archive.remote?.seconds) - 20) < 0.1,
            "all of the far end, got \(archive.remote?.seconds ?? 0)")
        #expect(abs(try #require(archive.mic?.seconds) - 18) < 0.1)
    }

    @Test("the listening copy is cut in place at its own sample rate")
    func theListeningCopyIsCutAtItsOwnRate() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrimFixtures.makeCompacted(root: root)
        let before = try AudioFileInspector().inspect(url: store.layout.recordingAudio)
        #expect(before.sampleRate == 48_000)

        let range = try #require(TrimRange(start: 2, end: 12, duration: 20))
        try Self.trimmer().trim(store: store, to: range, at: Self.at)

        let after = try AudioFileInspector().inspect(url: store.layout.recordingAudio)
        #expect(after.sampleRate == 48_000, "the far end is not brought down to the archive's rate")
        #expect(abs(try TrimFixtures.seconds(of: store.layout.recordingAudio) - 10) < 0.2)
    }

    @Test("the cleaned microphone is cut with the rest, or removed when the microphone has nothing in range")
    func theCleanedMicrophone() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = try TrimFixtures.makeCompacted(root: root.appendingPathComponent("inside"))
        try TrimFixtures.addCleanedMicrophone(to: inside)
        try Self.trimmer().trim(
            store: inside, to: try #require(TrimRange(start: 2, end: 12, duration: 20)), at: Self.at)
        let cleaned = try #require(try inside.readMetadata().cleanedMic)
        #expect(abs(cleaned.track.seconds - 10) < 0.1)
        #expect(abs(try TrimFixtures.seconds(of: inside.layout.cleanedMicFile) - 10) < 0.2)

        // A microphone that stopped at 6 s, and a range after it.
        let outside = try TrimFixtures.makeCompacted(
            root: root.appendingPathComponent("outside"), micSeconds: 6, remoteSeconds: 20, remoteStartOffset: 0)
        try TrimFixtures.addCleanedMicrophone(to: outside)
        try Self.trimmer().trim(
            store: outside, to: try #require(TrimRange(start: 8, end: 18, duration: 20)), at: Self.at)
        let metadata = try outside.readMetadata()
        #expect(metadata.cleanedMic == nil, "no record of audio that is gone")
        #expect(!FileManager.default.fileExists(atPath: outside.layout.cleanedMicFile.path))
        #expect(metadata.audioArchive?.mic == nil)
        #expect(!FileManager.default.fileExists(atPath: outside.layout.trackArchiveFile(track: .mic).path))
    }

    // MARK: the capture record

    @Test("a gap in the capture clock and a crash tail leave the manifest matching the archive")
    func aGapAndACrashTail() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrimFixtures.makeWithGapAndCrashTail(root: root)
        let before = try store.readTimeline()
        #expect(abs(before.duration(track: .mic) - 10) < 0.01)

        // Seconds 5 to 9 of the joined audio: three of the second segment and
        // one of the crash tail. The timeline is a track's first frame plus a
        // position in its joined audio, so the kept audio starts at 100 + 5,
        // not at the 111 the capture clock read for it after the gap.
        let range = try #require(TrimRange(start: 5, end: 9, duration: 10))
        try Self.trimmer().trim(store: store, to: range, at: Self.at)

        let archive = try #require(try store.readMetadata().audioArchive?.mic)
        let timeline = try store.readTimeline()
        #expect(abs(archive.seconds - 4) < 0.1)
        #expect(
            abs(timeline.duration(track: .mic) - archive.seconds) < 0.1,
            "the manifest says \(timeline.duration(track: .mic)) s and the archive \(archive.seconds) s")
        let segments = timeline.segments(track: .mic)
        #expect(segments.count == 2)
        #expect(abs((segments.first?.seconds ?? 0) - 3) < 0.01)
        let tail = try #require(segments.last)
        #expect(tail.wasAdoptedFromCrashTail, "still a crash tail, now one second long")
        #expect(abs(tail.seconds - 1) < 0.01, "got \(tail.seconds)")
        #expect(abs((timeline.firstFrameHostTime(track: .mic) ?? 0) - 105) < 0.01)
        #expect(abs((archive.firstFrameHostTime ?? 0) - 105) < 0.01, "the archive starts where the manifest says")
    }

    @Test("after a gap, a start trim leaves the two tracks aligned as they were")
    func afterAGapTheTracksStayAligned() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrimFixtures.makeWithGapAndCrashTail(root: root, withFarEnd: true)
        let before = try store.readTimeline()
        #expect(before.leadIn(track: .mic) == 0 && before.leadIn(track: .remote) == 0)

        try Self.trimmer().trim(
            store: store, to: try #require(TrimRange(start: 5, end: 10, duration: 10)), at: Self.at)

        let timeline = try store.readTimeline()
        #expect(
            abs(timeline.leadIn(track: .mic) - timeline.leadIn(track: .remote)) < 0.01,
            "mic starts \(timeline.leadIn(track: .mic)) s in and the far end \(timeline.leadIn(track: .remote)) s")
        let archive = try #require(try store.readMetadata().audioArchive)
        let micStart = try #require(archive.mic?.firstFrameHostTime)
        let remoteStart = try #require(archive.remote?.firstFrameHostTime)
        #expect(abs(micStart - remoteStart) < 0.01, "the archives agree with each other and with the manifest")
        #expect(abs(timeline.duration(track: .mic) - (archive.mic?.seconds ?? 0)) < 0.1)
    }

    @Test("a crash tail that becomes the first kept segment still gives the track its start")
    func aCrashTailAsTheFirstKeptSegment() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrimFixtures.makeWithGapAndCrashTail(root: root)
        // 8.5 s to the end falls inside the crash tail, which has no start time.
        try Self.trimmer().trim(
            store: store, to: try #require(TrimRange(start: 8.5, end: 10, duration: 10)), at: Self.at)
        let archive = try #require(try store.readMetadata().audioArchive?.mic)
        let timeline = try store.readTimeline()
        let seen = try #require(timeline.firstFrameHostTime(track: .mic), "the track still has a start")
        #expect(abs(seen - (archive.firstFrameHostTime ?? 0)) < 0.01, "the manifest and the archive agree")
        #expect(abs(seen - 108.5) < 0.01, "got \(seen)")
    }

    // MARK: the other files

    @Test("every file measured on the timeline is cut, and no removed word is left on disk")
    func everyFileIsCut() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrimFixtures.makeCompacted(root: root, remoteStartOffset: 0)
        let layout = store.layout

        // Words at 3 s (removed), 10 s (kept) and 17 s (removed), all on the
        // far end.
        let chunk = RawTranscriptChunk(
            id: "remote_full", track: .remote, timelineOffset: 0, durationSeconds: 20, model: "test",
            responseFormat: "local_words",
            segments: [
                RawTranscriptSegment(
                    start: 3, end: 4, text: " removedone", speaker: nil,
                    words: [RawTranscriptWord(start: 3, end: 4, text: " removedone")]),
                RawTranscriptSegment(
                    start: 10, end: 11, text: " kept", speaker: nil,
                    words: [RawTranscriptWord(start: 10, end: 11, text: " kept")]),
                RawTranscriptSegment(
                    start: 17, end: 18, text: " removedtwo", speaker: nil,
                    words: [RawTranscriptWord(start: 17, end: 18, text: " removedtwo")]),
            ])
        try store.writeRawTranscript(RawTranscript(chunks: [chunk]))
        try store.writeCanonicalTranscript(
            CanonicalTranscript(
                generatedAt: TrimFixtures.started,
                utterances: [(3.0, "removedone"), (10.0, "kept"), (17.0, "removedtwo")].map { start, text in
                    Utterance(
                        id: "u\(start)", start: start, end: start + 1, track: .remote, rawSpeakerLabel: "remote-001:S1",
                        speakerKey: "remote-001:S1", text: text, chunkID: "remote_full", model: "test")
                }))
        try store.writeRawDiarization(
            RawDiarization(runs: [
                DiarizationRun(
                    id: "remote-001", track: .remote, backend: "test", producedAt: TrimFixtures.started,
                    timelineOffset: 0,
                    intervals: [
                        DiarizationInterval(start: 0, end: 9, clusterID: "S1"),
                        DiarizationInterval(start: 9, end: 20, clusterID: "S2"),
                    ])
            ]))
        try store.writeSpeechEvidence(
            SpeechEvidence(
                levelWindowSeconds: 1, speechWindowSeconds: 1, micLevels: Array(0..<20), remoteLevels: Array(0..<20)))
        // The folder suggestion quotes what it was made from.
        try Data(#"{"quote": "removedone said so"}"#.utf8).write(to: layout.folderSuggestion)
        let person = SpeakerAssignment(displayName: "Speaker A", origin: .human)
        try store.writeSpeakerMap(
            SpeakerMap(
                entries: ["remote-001:S1": person],
                utteranceOverrides: [
                    UtteranceOverride(
                        track: .remote, anchorSeconds: 10.5, startSeconds: 10, endSeconds: 11, assignment: person,
                        createdAt: TrimFixtures.started)
                ],
                lineCuts: [LineCut(track: .remote, atSeconds: 10.5, createdAt: TrimFixtures.started)]))

        let range = try #require(TrimRange(start: 8, end: 14, duration: 20))
        try Self.trimmer().trim(store: store, to: range, at: Self.at)

        let canonical = try #require(try store.readCanonicalTranscript())
        #expect(canonical.utterances.map(\.text) == ["kept"])
        #expect(abs((canonical.utterances.first?.start ?? 0) - 2) < 0.001)
        let diarization = try store.readRawDiarization()
        #expect(diarization.runs.first?.intervals.map(\.clusterID) == ["S1", "S2"], "clusters keep their identifiers")
        #expect(diarization.runs.first?.intervals.map(\.start) == [0, 1])
        #expect(try store.readSpeechEvidence()?.remoteLevels == Array(8..<14))
        let map = try store.readSpeakerMap()
        #expect(map.entries["remote-001:S1"]?.displayName == "Speaker A", "the name stays")
        #expect(map.utteranceOverrides.first?.anchorSeconds == 2.5)
        #expect(map.lineCuts.first?.atSeconds == 2.5)
        #expect(TrimFixtures.textFiles(in: root, containing: ["removedone", "removedtwo"]).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: layout.trimStaging.path), "the staging marker is gone")
    }

    @Test("a cloud chunk is cut by its alignment, and nothing from the removed words is left")
    func aCloudChunkIsCutByItsAlignment() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrimFixtures.makeCompacted(root: root, remoteStartOffset: 0)
        let layout = store.layout

        // One chunk of text from 4 s to 12 s, and the timings the aligner
        // derived for it.
        let chunk = RawTranscriptChunk(
            id: "mic_0001", track: .mic, timelineOffset: 4, durationSeconds: 8, model: "test",
            responseFormat: "text", segments: [], text: "wordalpha wordbeta wordgamma worddelta",
            rawResponseFile: "api/mic_0001.json")
        try store.writeRawTranscript(RawTranscript(chunks: [chunk]))
        func word(_ text: String, _ start: Double) -> RawTranscriptWord {
            RawTranscriptWord(start: start, end: start + 1, text: " " + text)
        }
        let words = [word("wordalpha", 0), word("wordbeta", 2), word("wordgamma", 4), word("worddelta", 6)]
        try store.writeAlignment(
            ChunkAlignment(
                aligner: "test", alignedAt: TrimFixtures.started,
                segments: [
                    RawTranscriptSegment(
                        start: 0, end: 7, text: " wordalpha wordbeta wordgamma worddelta", speaker: nil, words: words)
                ]),
            chunkID: "mic_0001")
        try FileManager.default.createDirectory(at: layout.apiResponses, withIntermediateDirectories: true)
        try Data("wordalpha wordbeta wordgamma worddelta".utf8).write(
            to: layout.apiResponseFile(named: "mic_0001.json"))

        // Keeps 6 to 10 s: wordbeta (6 s) and wordgamma (8 s).
        let range = try #require(TrimRange(start: 6, end: 10, duration: 20))
        try Self.trimmer().trim(store: store, to: range, at: Self.at)

        let assembled = try store.readRawTranscriptForAssembly()
        let kept = try #require(assembled.chunks.first)
        #expect(kept.timelineOffset == 0)
        #expect(kept.durationSeconds == 4)
        #expect(kept.rawResponseFile == nil)
        let segment = try #require(kept.segments.first, "the words keep their timings, not one line over the chunk")
        #expect(segment.text.trimmingCharacters(in: .whitespaces) == "wordbeta wordgamma")
        #expect(segment.words?.map(\.start) == [0, 2])
        #expect(!FileManager.default.fileExists(atPath: layout.apiResponses.path))
        #expect(TrimFixtures.textFiles(in: root, containing: ["wordalpha", "worddelta"]).isEmpty)
    }

    // MARK: refusals and edits

    @Test("a meeting imported from a file is not trimmed")
    func anImportedMeetingIsNotTrimmed() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrimFixtures.makeCompacted(root: root)
        _ = try store.updateMetadata { $0.source = .imported }
        let range = try #require(TrimRange(start: 2, end: 12, duration: 20))
        #expect(throws: TrimError.imported) { try Self.trimmer().trim(store: store, to: range, at: Self.at) }
        #expect(abs(try store.readMetadata().durationSeconds - 20) < 0.1, "nothing was cut")
    }

    @Test("an edit made while the files are being cut is kept")
    func anEditDuringTheTrimIsKept() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrimFixtures.makeCompacted(root: root)
        let trimmer = MeetingTrimmer(beforeSwap: { position in
            if position == 1 { _ = try store.updateMetadata { $0.titles.human = "Renamed meanwhile" } }
        })
        let range = try #require(TrimRange(start: 2, end: 12, duration: 20))
        try trimmer.trim(store: store, to: range, at: Self.at)
        let metadata = try store.readMetadata()
        #expect(metadata.titles.human == "Renamed meanwhile")
        #expect(abs(metadata.durationSeconds - 10) < 0.1)
    }

    // MARK: interruption

    @Test("a trim stopped between two swaps is finished from its journal, not cut twice")
    func anInterruptedTrimIsFinished() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrimFixtures.makeCompacted(root: root)
        let range = try #require(TrimRange(start: 2, end: 12, duration: 20))

        #expect(throws: TrimError.filesNotWritten) {
            try Self.trimmer(stopAtSwap: 2).trim(store: store, to: range, at: Self.at)
        }
        // Some files are swapped and the record still describes the old ones.
        #expect(FileManager.default.fileExists(atPath: store.layout.trimJournal.path))
        #expect(abs(try store.readMetadata().durationSeconds - 20) < 0.1)

        // A second trim does not start over it.
        #expect(throws: TrimError.interrupted) {
            try MeetingTrimmer().trim(store: store, to: range, at: Self.at)
        }

        let finished = try #require(try MeetingTrimmer().finishInterrupted(store: store))
        #expect(finished.swapped)
        let metadata = try store.readMetadata()
        #expect(abs(metadata.durationSeconds - 10) < 0.1)
        let archive = try #require(metadata.audioArchive)
        for (name, record) in [("mic", archive.mic), ("remote", archive.remote)] {
            let track = try #require(record)
            let file = store.layout.trackArchiveDirectory.appendingPathComponent(track.file)
            #expect(
                abs(try TrimFixtures.seconds(of: file) - track.seconds) < 0.2,
                "\(name): the file holds what the record says, so no track was cut a second time")
        }
        #expect(abs(try store.readTimeline().duration(track: .mic) - 10) < 0.1)

        // Finishing again changes nothing.
        let again = try #require(try MeetingTrimmer().finishInterrupted(store: store))
        #expect(again.swapped && again.swaps == finished.swaps)
        #expect(abs(try store.readMetadata().durationSeconds - 10) < 0.1)
    }

    @Test("a trim stopped at any swap is finished, whichever one it was")
    func aTrimStoppedAtAnySwapIsFinished() throws {
        // The manifest, two tracks and the listening copy.
        for position in 0..<4 {
            let root = try TestPaths.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try TrimFixtures.makeCompacted(root: root)
            let range = try #require(TrimRange(start: 2, end: 12, duration: 20))
            #expect(throws: TrimError.filesNotWritten) {
                try Self.trimmer(stopAtSwap: position).trim(store: store, to: range, at: Self.at)
            }
            let finished = try #require(try MeetingTrimmer().finishInterrupted(store: store))
            #expect(finished.swapped)
            let archive = try #require(try store.readMetadata().audioArchive)
            for record in [archive.mic, archive.remote] {
                let track = try #require(record)
                let file = store.layout.trackArchiveDirectory.appendingPathComponent(track.file)
                #expect(abs(try TrimFixtures.seconds(of: file) - track.seconds) < 0.2, "stopped at swap \(position)")
            }
            #expect(abs(try store.readTimeline().duration(track: .mic) - 10) < 0.1, "stopped at swap \(position)")
            #expect(abs(try TrimFixtures.seconds(of: store.layout.recordingAudio) - 10) < 0.2)
        }
    }

    @Test("a replacement that is not the one that was checked is an error, not a step to skip")
    func aMissingOrChangedReplacementIsAnError() throws {
        for damage in ["changed"] {
            let root = try TestPaths.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try TrimFixtures.makeCompacted(root: root)
            let range = try #require(TrimRange(start: 2, end: 12, duration: 20))
            #expect(throws: TrimError.filesNotWritten) {
                try Self.trimmer(stopAtSwap: 1).trim(store: store, to: range, at: Self.at)
            }
            // The last replacement has not been swapped in yet.
            let journal = try #require(try store.readTrimJournal())
            let staged = store.layout.root.appendingPathComponent(try #require(journal.swaps.last).staged)
            if damage == "missing" {
                try FileManager.default.removeItem(at: staged)
            } else {
                try Data("not the replacement".utf8).write(to: staged)
            }
            #expect(throws: TrimError.filesNotWritten, "\(damage)") {
                try MeetingTrimmer().finishInterrupted(store: store)
            }
            #expect(
                abs(try store.readMetadata().durationSeconds - 20) < 0.1, "the record is not written over a bad swap")
        }
    }

    @Test("files a trim left before its journal was written are removed, and a journal's are not")
    func leftoversAreRemoved() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrimFixtures.makeCompacted(root: root)
        let layout = store.layout
        let leftovers = [
            layout.trackArchiveDirectory.appendingPathComponent("mic.trimming.m4a"),
            layout.rawTranscript.appendingPathExtension("trimming"),
            layout.root.appendingPathComponent("recording.trimming.m4a"),
        ]
        for url in leftovers { try Data("old content".utf8).write(to: url) }

        MeetingTrimmer.removeLeftovers(layout: layout)

        for url in leftovers { #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)") }
        #expect(FileManager.default.fileExists(atPath: layout.trackArchiveFile(track: .mic).path), "real files stay")

        // With a journal they are what finishes the trim.
        #expect(throws: TrimError.filesNotWritten) {
            try Self.trimmer(stopAtSwap: 1).trim(
                store: store, to: try #require(TrimRange(start: 2, end: 12, duration: 20)), at: Self.at)
        }
        MeetingTrimmer.removeLeftovers(layout: layout)
        #expect(try MeetingTrimmer().finishInterrupted(store: store)?.swapped == true)
    }

    @Test("the old file left at a staged path after its swap is removed, not put back")
    func theOldFileAtAStagedPathIsRemoved() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrimFixtures.makeCompacted(root: root)
        let range = try #require(TrimRange(start: 2, end: 12, duration: 20))
        #expect(throws: TrimError.filesNotWritten) {
            try Self.trimmer(stopAtSwap: 2).trim(store: store, to: range, at: Self.at)
        }
        // What an exchange that stopped before deleting would have left: the
        // swap is done and the old file, with the removed stretch in it, sits
        // where the replacement was.
        let journal = try #require(try store.readTrimJournal())
        let staged = store.layout.root.appendingPathComponent(journal.swaps[1].staged)
        try Data("the old file".utf8).write(to: staged)

        let finished = try #require(try MeetingTrimmer().finishInterrupted(store: store))

        #expect(finished.swapped)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(abs(try store.readMetadata().durationSeconds - 10) < 0.1)
        let track = try #require(try store.readMetadata().audioArchive?.mic)
        let file = store.layout.trackArchiveDirectory.appendingPathComponent(track.file)
        #expect(abs(try TrimFixtures.seconds(of: file) - track.seconds) < 0.2, "the new file stayed in place")
    }

    private static func stagedFiles(in root: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { ($0 as? URL)?.lastPathComponent }.filter { $0.contains(".trimming") }
    }

    @Test("a journal that failed to write after it was renamed into place leaves no trim behind")
    func aJournalWriteFailingAfterTheRenameLeavesNoTrimBehind() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrimFixtures.makeCompacted(root: root)
        let trimmer = MeetingTrimmer(afterJournalWritten: { throw TrimError.filesNotWritten })
        let range = try #require(TrimRange(start: 2, end: 12, duration: 20))

        #expect(throws: TrimError.filesNotWritten) { try trimmer.trim(store: store, to: range, at: Self.at) }

        #expect(
            !FileManager.default.fileExists(atPath: store.layout.trimJournal.path), "no journal naming deleted files")
        #expect(Self.stagedFiles(in: root).isEmpty)
        #expect(abs(try store.readMetadata().durationSeconds - 20) < 0.1, "nothing was cut")
        // And the meeting can be trimmed afterwards.
        try Self.trimmer().trim(store: store, to: range, at: Self.at)
        #expect(abs(try store.readMetadata().durationSeconds - 10) < 0.1)
    }

    @Test("a stop between the metadata and the journal's update is finished once")
    func aStopBetweenTheMetadataAndTheJournalIsFinishedOnce() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrimFixtures.makeCompacted(root: root)
        let trimmer = MeetingTrimmer(beforeJournalUpdate: { throw TrimError.filesNotWritten })
        #expect(throws: TrimError.filesNotWritten) {
            try trimmer.trim(store: store, to: try #require(TrimRange(start: 2, end: 12, duration: 20)), at: Self.at)
        }
        #expect(try store.readTrimJournal()?.swapped == false)
        #expect(abs(try store.readMetadata().durationSeconds - 10) < 0.1, "the record was written")

        let finished = try #require(try MeetingTrimmer().finishInterrupted(store: store))

        #expect(finished.swapped)
        let metadata = try store.readMetadata()
        #expect(abs(metadata.durationSeconds - 10) < 0.1)
        #expect(metadata.startedAt == TrimFixtures.started.addingTimeInterval(2), "moved once, not twice")
    }

    @Test("a late far end and a gap together keep the tracks as far apart as they were")
    func aLateFarEndAndAGap() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrimFixtures.makeWithGapAndCrashTail(root: root, withFarEnd: true, farEndOffset: 3)
        #expect(abs(try store.readTimeline().leadIn(track: .remote) - 3) < 0.01)

        try Self.trimmer().trim(
            store: store, to: try #require(TrimRange(start: 1, end: 10, duration: 10)), at: Self.at)

        let timeline = try store.readTimeline()
        #expect(
            abs(timeline.leadIn(track: .remote) - 2) < 0.01,
            "3 s late, less the 1 s cut, got \(timeline.leadIn(track: .remote))")
        #expect(timeline.leadIn(track: .mic) == 0)
        let archive = try #require(try store.readMetadata().audioArchive)
        let lead = (archive.remote?.firstFrameHostTime ?? 0) - (archive.mic?.firstFrameHostTime ?? 0)
        #expect(abs(lead - 2) < 0.01, "the archives say the same, got \(lead)")
    }

    @Test("when the earliest track is cut away whole, everything moves to where the kept audio begins")
    func whenTheEarliestTrackIsCutAway() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // The microphone is 6 s from the start and the far end runs from 10 s
        // to 30 s.
        let store = try TrimFixtures.makeCompacted(root: root, micSeconds: 6, remoteSeconds: 20, remoteStartOffset: 10)
        let chunk = RawTranscriptChunk(
            id: "remote_full", track: .remote, timelineOffset: 10, durationSeconds: 20, model: "test",
            responseFormat: "local_words",
            segments: [
                RawTranscriptSegment(
                    start: 2, end: 3, text: " kept", speaker: nil,
                    words: [RawTranscriptWord(start: 2, end: 3, text: " kept")])
            ])
        try store.writeRawTranscript(RawTranscript(chunks: [chunk]))

        // Asks for 8 s on, which is before anything that is left.
        try Self.trimmer().trim(
            store: store, to: try #require(TrimRange(start: 8, end: 25, duration: 30)), at: Self.at)

        let metadata = try store.readMetadata()
        #expect(metadata.audioArchive?.mic == nil)
        #expect(metadata.startedAt == TrimFixtures.started.addingTimeInterval(10), "the meeting now starts at 10 s")
        let kept = try #require(try store.readRawTranscript().chunks.first)
        #expect(
            kept.timelineOffset == 0,
            "the chunk was at 10 s and the meeting now starts there, got \(kept.timelineOffset)")
        let timeline = try store.readTimeline()
        #expect(timeline.leadIn(track: .remote) == 0)
    }

    @Test("a recording with a mixdown from before the raw folder existed is not trimmed")
    func aLegacyMixdownIsNotTrimmed() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrimFixtures.makeCompacted(root: root)
        try Data("audio".utf8).write(to: store.layout.legacyMixedAudio)
        let range = try #require(TrimRange(start: 2, end: 12, duration: 20))
        #expect(throws: TrimError.notArchived) { try Self.trimmer().trim(store: store, to: range, at: Self.at) }
    }

    @Test("a speaker edit made after a failed finish does not block the trim")
    func anEditAfterAFailedFinishDoesNotBlockTheTrim() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrimFixtures.makeCompacted(root: root, remoteStartOffset: 0)
        let person = SpeakerAssignment(displayName: "Speaker A", origin: .human)
        try store.writeSpeakerMap(SpeakerMap(entries: ["remote-001:S1": person]))
        try store.writeCanonicalTranscript(CanonicalTranscript(generatedAt: TrimFixtures.started, utterances: []))
        // Stops at the last swap, after the speaker map's.
        let trimmer = MeetingTrimmer(beforeSwap: { position in
            if position == (try store.readTrimJournal()?.swaps.count ?? 1) - 1 { throw TrimError.filesNotWritten }
        })
        #expect(throws: TrimError.filesNotWritten) {
            try trimmer.trim(store: store, to: try #require(TrimRange(start: 2, end: 12, duration: 20)), at: Self.at)
        }
        var map = try store.readSpeakerMap()
        map.entries["remote-001:S2"] = SpeakerAssignment(displayName: "Speaker B", origin: .human)
        try store.writeSpeakerMap(map)

        let finished = try #require(try MeetingTrimmer().finishInterrupted(store: store))

        #expect(finished.swapped)
        #expect(try store.readSpeakerMap().entries.count == 2, "the edit stays")
        #expect(abs(try store.readMetadata().durationSeconds - 10) < 0.1)
    }
}
