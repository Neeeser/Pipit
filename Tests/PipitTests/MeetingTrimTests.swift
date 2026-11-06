import AVFoundation
import Foundation
import PipitAudio
import PipitCore
import PipitServices
import Testing

@Suite("MeetingTrim")
struct MeetingTrimTests {
    private static let created = Date(timeIntervalSince1970: 1_787_070_000)

    @Test("a range must remove something and keep something")
    func aRangeMustRemoveSomethingAndKeepSomething() {
        #expect(TrimRange(start: 0, end: 60, duration: 60) == nil, "keeping everything is not a trim")
        #expect(TrimRange(start: 30, end: 30.5, duration: 60) == nil, "half a second is too little to keep")
        #expect(TrimRange(start: -5, end: 40, duration: 60)?.start == 0, "a handle before the start sits on it")
        #expect(TrimRange(start: 10, end: 90, duration: 60)?.end == 60, "a handle past the end sits on it")
        #expect(TrimRange(start: 0, end: 60, duration: 60, toEnd: true) == nil, "still nothing removed")
        let toEnd = TrimRange(start: 10, end: 65, duration: 60, toEnd: true)
        #expect(toEnd?.keepsEnd == true)
        #expect(toEnd?.end == 65, "the timeline can run past the longest track")
        #expect(toEnd?.moved(64) == 54, "a time after the recorded length is still kept")
        #expect(TrimRange(start: 10, end: 40, duration: 60)?.keepsEnd == false)
    }

    @Test("words outside the range go and the rest move to the new start")
    func wordsOutsideTheRangeGo() throws {
        // One chunk placed 5 s into the meeting, words at 5-6, 9-10 and 13-14.
        let words = [
            RawTranscriptWord(start: 0, end: 1, text: " one"),
            RawTranscriptWord(start: 4, end: 5, text: " two"),
            RawTranscriptWord(start: 8, end: 9, text: " three"),
        ]
        let chunk = RawTranscriptChunk(
            id: "mic_full", track: .mic, timelineOffset: 5, durationSeconds: 10, model: "test",
            responseFormat: "local_words",
            segments: [RawTranscriptSegment(start: 0, end: 9, text: " one two three", speaker: nil, words: words)]
        )
        let range = try #require(TrimRange(start: 8, end: 12, duration: 20))
        let trimmed = MeetingTrim.trim(RawTranscript(chunks: [chunk]), to: range)

        let kept = try #require(trimmed.chunks.first)
        #expect(kept.timelineOffset == 0)
        #expect(kept.durationSeconds == 4)
        let segment = try #require(kept.segments.first)
        #expect(segment.text == " two")
        let word = try #require(segment.words?.first)
        // 9 s on the old timeline is 1 s after the new start.
        #expect(abs(kept.timelineOffset + word.start - 1) < 0.0001)
        #expect(segment.words?.count == 1)
    }

    @Test("a chunk wholly outside the range is dropped")
    func aChunkWhollyOutsideTheRangeIsDropped() throws {
        let chunk = RawTranscriptChunk(
            id: "late", track: .remote, timelineOffset: 50, durationSeconds: 5, model: "test",
            responseFormat: "local_words", segments: []
        )
        let range = try #require(TrimRange(start: 0, end: 40, duration: 60))
        #expect(MeetingTrim.trim(RawTranscript(chunks: [chunk]), to: range).chunks.isEmpty)
    }

    @Test("speaker turns are clipped at the cut and keep their clusters")
    func speakerTurnsAreClippedAndKeepTheirClusters() throws {
        let run = DiarizationRun(
            id: "remote-001", track: .remote, backend: "test", producedAt: Self.created, timelineOffset: 0.03,
            intervals: [
                DiarizationInterval(start: 1, end: 4, clusterID: "S1"),
                DiarizationInterval(start: 6, end: 12, clusterID: "S2"),
                DiarizationInterval(start: 20, end: 25, clusterID: "S1"),
            ]
        )
        let range = try #require(TrimRange(start: 3, end: 10, duration: 30))
        let trimmed = MeetingTrim.trim(RawDiarization(runs: [run]), to: range)
        let intervals = try #require(trimmed.runs.first?.intervals)
        #expect(intervals.map(\.clusterID) == ["S1", "S2"])
        #expect(intervals.map(\.start) == [0, 3])
        #expect(intervals.map(\.end) == [1, 7])
        #expect(trimmed.runs.first?.timelineOffset == 0)
    }

    @Test("names stay, and line corrections move with their words")
    func namesStayAndCorrectionsMove() throws {
        let assignment = SpeakerAssignment(displayName: "Speaker A", origin: .human)
        let map = SpeakerMap(
            entries: ["remote-001:S1": assignment],
            utteranceOverrides: [
                // Wholly before the range.
                UtteranceOverride(
                    track: .remote, anchorSeconds: 2, startSeconds: 1, endSeconds: 3, assignment: assignment,
                    createdAt: Self.created),
                // A line the cut only shortens: its middle is cut, its end is not.
                UtteranceOverride(
                    track: .remote, anchorSeconds: 9, startSeconds: 8, endSeconds: 12, assignment: assignment,
                    createdAt: Self.created),
                UtteranceOverride(
                    track: .remote, anchorSeconds: 15, startSeconds: 14, endSeconds: 18, assignment: assignment,
                    createdAt: Self.created),
                // From before spans were recorded: the anchor decides.
                UtteranceOverride(track: .remote, anchorSeconds: 4, assignment: assignment, createdAt: Self.created),
            ],
            lineCuts: [
                LineCut(track: .mic, atSeconds: 1, createdAt: Self.created),
                LineCut(track: .mic, atSeconds: 12, createdAt: Self.created),
            ]
        )
        let range = try #require(TrimRange(start: 10, end: 20, duration: 30))
        let trimmed = MeetingTrim.trim(map, to: range)
        #expect(trimmed.entries == map.entries)
        #expect(trimmed.utteranceOverrides.map(\.anchorSeconds) == [1, 5])
        #expect(trimmed.utteranceOverrides.map(\.startSeconds) == [0, 4])
        #expect(trimmed.utteranceOverrides.map(\.endSeconds) == [2, 8])
        #expect(trimmed.lineCuts.map(\.atSeconds) == [2])
    }

    @Test("a cloud chunk keeps the words in range, with their timings, and loses its stored response")
    func aCloudChunkKeepsTheWordsInRange() throws {
        // Text from 5 s to 15 s, timed by a separate alignment.
        let chunk = RawTranscriptChunk(
            id: "cloud", track: .remote, timelineOffset: 5, durationSeconds: 10, model: "test", responseFormat: "text",
            segments: [], text: "one two three four", rawResponseFile: "api/cloud.json")
        let words = [
            RawTranscriptWord(start: 0, end: 1, text: " one"), RawTranscriptWord(start: 3, end: 4, text: " two"),
            RawTranscriptWord(start: 6, end: 7, text: " three"), RawTranscriptWord(start: 9, end: 10, text: " four"),
        ]
        let alignment = ChunkAlignment(
            aligner: "test", alignedAt: Self.created,
            segments: [RawTranscriptSegment(start: 0, end: 10, text: " one two three four", speaker: nil, words: words)]
        )
        let range = try #require(TrimRange(start: 8, end: 12, duration: 20))

        let trimmed = MeetingTrim.trim(
            RawTranscript(chunks: [chunk]), alignments: ["cloud": alignment], to: range)

        let kept = try #require(trimmed.transcript.chunks.first)
        #expect(kept.text == "two three", "the deleted words are not left in the text, got \(kept.text ?? "")")
        #expect(kept.timelineOffset == 0)
        #expect(kept.durationSeconds == 4)
        #expect(kept.rawResponseFile == nil)
        let moved = try #require(trimmed.alignments["cloud"]?.segments.first)
        #expect(moved.words?.map(\.start) == [0, 3], "8 s was 3 s into the chunk and is now its start")
        #expect(moved.words?.map(\.text) == [" two", " three"])
    }

    @Test("a straddling chunk with no timings keeps only the words that surely fall inside")
    func aStraddlingChunkWithNoTimings() throws {
        let chunk = RawTranscriptChunk(
            id: "cloud", track: .remote, timelineOffset: 0, durationSeconds: 8, model: "test", responseFormat: "text",
            segments: [], text: "a b c d e f g h")
        // Eight words over eight seconds, one a second. 2 to 6 holds c to f.
        let trimmed = MeetingTrim.trim(
            RawTranscript(chunks: [chunk]), to: try #require(TrimRange(start: 2, end: 6, duration: 20)))
        #expect(trimmed.chunks.first?.text == "c d e f")

        // A chunk wholly in range is untouched; one wholly outside is gone, and
        // a chunk whose kept stretch holds no whole word is gone too.
        let whole = MeetingTrim.trim(
            RawTranscript(chunks: [chunk]), to: try #require(TrimRange(start: 0, end: 10, duration: 20)))
        #expect(whole.chunks.first?.text == "a b c d e f g h")
        let none = MeetingTrim.trim(
            RawTranscript(chunks: [chunk]), to: try #require(TrimRange(start: 7.5, end: 9, duration: 20)))
        #expect(none.chunks.isEmpty)
    }

    @Test("keeping to the end keeps words after the recorded length")
    func keepingToTheEndKeepsWordsAfterTheRecordedLength() throws {
        let chunk = RawTranscriptChunk(
            id: "late", track: .remote, timelineOffset: 58, durationSeconds: 5, model: "test",
            responseFormat: "local_words",
            segments: [
                RawTranscriptSegment(
                    start: 3, end: 4, text: " last", speaker: nil,
                    words: [RawTranscriptWord(start: 3, end: 4, text: " last")])
            ])
        let range = try #require(TrimRange(start: 10, end: 63, duration: 60, toEnd: true))
        let kept = try #require(MeetingTrim.trim(RawTranscript(chunks: [chunk]), to: range).chunks.first)
        #expect(kept.segments.first?.text == " last", "61 s is past the longest track's 60 s and is still kept")
        let evidence = SpeechEvidence(levelWindowSeconds: 1, speechWindowSeconds: 1, micLevels: Array(0..<70))
        #expect(MeetingTrim.trim(evidence, to: range).micLevels.count == 60, "windows after 60 s are kept too")
    }

    @Test("speech windows covering the cut are kept")
    func speechWindowsCoveringTheCutAreKept() throws {
        let evidence = SpeechEvidence(
            levelWindowSeconds: 1, speechWindowSeconds: 1,
            micLevels: Array(0..<10), remoteLevels: Array(10..<20), micSpeech: Array(20..<30)
        )
        let range = try #require(TrimRange(start: 2.5, end: 6, duration: 10))
        let trimmed = MeetingTrim.trim(evidence, to: range)
        #expect(trimmed.micLevels == [2, 3, 4, 5])
        #expect(trimmed.remoteLevels == [12, 13, 14, 15])
    }

    // MARK: on disk

    /// A compacted meeting whose microphone holds 2 s of silence, 2 s of tone
    /// and 2 s of silence, so where the tone lands after a cut is measurable.
    private static func makeArchivedMeeting(root: URL) throws -> MeetingStore {
        let repository = MeetingRepository(root: root)
        let made = try repository.createMeeting(
            source: .manual, provider: .unknown, startedAt: created,
            titles: TitleCandidates(timestampFallback: "trim"), now: created
        )
        let store = made.store
        let manifest = try ManifestWriter(url: store.layout.manifest)
        manifest.append(
            .sessionStart(
                .init(
                    meetingID: made.metadata.id, source: .manual, segmentSeconds: 30, appVersion: "test", processID: 1)
            ))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let writer = SegmentWriter(
            track: .mic, layout: store.layout, manifest: manifest, format: format, segmentSeconds: 30
        )
        let parts: [(seconds: Double, amplitude: Float)] = [(2, 0), (2, 0.5), (2, 0)]
        var host = 100.0
        for part in parts {
            writer.enqueueSynchronously(
                AudioBufferPacket(
                    buffer: AudioFixtures.makeTone(
                        seconds: part.seconds, sampleRate: 48_000, amplitude: part.amplitude),
                    hostTime: host
                ))
            host += part.seconds
        }
        writer.finish(reason: "test")
        manifest.append(.sessionEnd(.init(reason: "test", micSeconds: 6, remoteSeconds: 0)))
        manifest.close()
        _ = try store.updateMetadata {
            $0.durationSeconds = 6
            $0.endedAt = created.addingTimeInterval(6)
            $0.runs = [RecordingRun(id: "run-001", startedAt: created, endedAt: $0.endedAt, durationSeconds: 6)]
            $0.processing = ProcessingStatus(state: .complete, updatedAt: created)
        }
        _ = try AudioCompactor().compact(store: store)
        return store
    }

    /// Seconds from the start of the microphone audio to the first loud frame.
    private static func toneOnset(_ store: MeetingStore) throws -> Double? {
        let metadata = try store.readMetadata()
        let location = store.trackAudioLocation(track: .mic, metadata: metadata, timeline: try store.readTimeline())
        let stream = TrackAudioStream(
            segments: location.segments, segmentsDirectory: location.directory,
            format: AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1)
        )
        var onset: Int64?
        var position: Int64 = 0
        try stream.forEachBuffer(from: 0, to: 10) { buffer, _ in
            if let data = buffer.floatChannelData {
                for frame in 0..<Int(buffer.frameLength) where abs(data[0][frame]) > 0.05 {
                    onset = position + Int64(frame)
                    return false
                }
            }
            position += Int64(buffer.frameLength)
            return true
        }
        return onset.map { Double($0) / 16_000 }
    }

    @Test("trimming rewrites the audio, the record and the manifest to the kept range")
    func trimmingRewritesTheAudioRecordAndManifest() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Self.makeArchivedMeeting(root: root)
        let before = try #require(try Self.toneOnset(store))
        #expect(abs(before - 2) < 0.1, "the tone starts 2 s in before the trim, got \(before)")

        let range = try #require(TrimRange(start: 1.5, end: 4.5, duration: 6))
        try MeetingTrimmer().trim(store: store, to: range, at: Self.created.addingTimeInterval(60))

        let metadata = try store.readMetadata()
        #expect(abs(metadata.durationSeconds - 3) < 0.001)
        #expect(abs((metadata.audioArchive?.mic?.seconds ?? 0) - 3) < 0.1)
        #expect(metadata.startedAt == Self.created.addingTimeInterval(1.5))
        #expect(metadata.processing.state == .enriching, "the summary is written again from what is left")
        let after = try #require(try Self.toneOnset(store))
        #expect(abs(after - 0.5) < 0.1, "the tone moves to 0.5 s after the new start, got \(after)")
        let timeline = try store.readTimeline()
        #expect(abs(timeline.duration - 3) < 0.1, "processing reads the length from here, got \(timeline.duration)")
        #expect(
            abs(try TrimFixtures.seconds(of: store.layout.recordingAudio) - 3) < 0.2,
            "the listening copy is cut to the same range and kept")
    }

    @Test("a meeting still processing is not trimmed")
    func aMeetingStillProcessingIsNotTrimmed() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Self.makeArchivedMeeting(root: root)
        _ = try store.updateMetadata { $0.processing = ProcessingStatus(state: .enriching, updatedAt: Self.created) }
        let range = try #require(TrimRange(start: 1, end: 4, duration: 6))
        #expect(throws: TrimError.notFinished) {
            try MeetingTrimmer().trim(store: store, to: range, at: Self.created)
        }
        #expect(try store.readMetadata().durationSeconds == 6, "nothing was cut")
    }
}
