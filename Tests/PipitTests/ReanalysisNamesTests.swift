import Foundation
import PipitCore
import PipitServices
import Testing

/// What happens to the names a person gave speakers when the meeting is
/// re-analysed.
@Suite("ReanalysisNames", .tags(.slow))
struct ReanalysisNamesTests {
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

    private static func output(_ intervals: [DiarizationInterval]) -> DiarizationOutput {
        var speech: [String: Double] = [:]
        for interval in intervals { speech[interval.clusterID, default: 0] += interval.duration }
        return DiarizationOutput(
            intervals: intervals,
            clusters: speech.keys.sorted().map { DiarizationCluster(id: $0, speechSeconds: speech[$0] ?? 0) },
            chunkEmbeddings: [], configuration: [:])
    }

    /// A 30 s call with two remote voices, the first named by a person, then
    /// re-analysed into `reclustered`. Returns the name each remote line reads
    /// under afterwards.
    private static func reanalyse(
        into reclustered: [DiarizationInterval], cloudLabelled: Bool = false
    ) async throws -> [String: String] {
        try await reanalyseWithMap(into: reclustered, cloudLabelled: cloudLabelled).names
    }

    /// As `reanalyse`, also returning the speaker map left behind, and taking
    /// entries to add to the map just before the re-analysis.
    private static func reanalyseWithMap(
        into reclustered: [DiarizationInterval], cloudLabelled: Bool = false,
        extraEntries: [String: SpeakerAssignment] = [:]
    ) async throws -> (names: [String: String], map: SpeakerMap) {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try PipelineFixtures.makeRecordedMeeting(
            root: root.appendingPathComponent("Meetings"), source: .googleMeet, seconds: 30)
        let transcriber = StubLocalTranscriber(segments: [
            line("alphaword", at: 2), line("bravoword", at: 12), line("charlieword", at: 24),
        ])
        transcriber.reportedSeconds = 30
        let first = [
            DiarizationInterval(start: 0, end: 15, clusterID: "S1"),
            DiarizationInterval(start: 15, end: 30, clusterID: "S2"),
        ]
        let diarizer = StubLocalDiarizer(intervals: first, chunkEmbeddings: [])
        let second = output(reclustered)
        let pipeline = PipelineFixtures.makePipeline(
            repository: meeting.repository, backend: FakeAIBackend(), transcriber: transcriber,
            diarizer: diarizer, speakers: nil,
            reanalyzeDiarization: { _, _, _ in second },
            settings: settings, scratchRoot: root.appendingPathComponent("scratch"))
        let id = meeting.metadata.id
        await pipeline.process(meetingID: id)
        let store = try #require(meeting.repository.findMeeting(id: id)?.store)
        var named = "remote-001_speaker_00"
        if cloudLabelled {
            // A cloud transcriber labels speakers inside its own response and
            // leaves no diarization record, so the lines carry its labels.
            try FileManager.default.removeItem(at: store.layout.rawDiarization)
            var transcript = try #require(try store.readCanonicalTranscript())
            for index in transcript.utterances.indices {
                transcript.utterances[index].speakerKey = transcript.utterances[index].speakerKey
                    .replacingOccurrences(of: "remote-001_", with: "remote_chunk_001_")
            }
            try store.writeCanonicalTranscript(transcript)
            named = "remote_chunk_001_speaker_00"
        }
        var map = try store.readSpeakerMap()
        map.assign("Synthetic Person", to: named)
        for (key, assignment) in extraEntries { map.entries[key] = assignment }
        try store.writeSpeakerMap(map)

        try await pipeline.reanalyzeSpeakers(meetingID: id, speakerCount: nil)

        let after = try #require(meeting.repository.findMeeting(id: id)?.store)
        let transcript = try #require(try after.readCanonicalTranscript())
        let names = try after.readSpeakerMap()
        var out: [String: String] = [:]
        for utterance in transcript.utterances where utterance.track == .remote {
            out[utterance.text.trimmingCharacters(in: .whitespaces)] = names.resolvedName(for: utterance)
        }
        return (out, names)
    }

    @Test("a name a person gave a voice stays on that voice after re-analysis renumbers it")
    func aConfirmedNameFollowsTheSameSpeech() async throws {
        // The same two voices, numbered the other way round.
        let names = try await Self.reanalyse(into: [
            DiarizationInterval(start: 0, end: 15, clusterID: "S2"),
            DiarizationInterval(start: 15, end: 30, clusterID: "S1"),
        ])
        #expect(names["alphaword"] == "Synthetic Person", "got \(names)")
        #expect(names["charlieword"] != "Synthetic Person", "got \(names)")
    }

    @Test("a name given to a speaker the cloud transcriber labelled follows the same speech")
    func aCloudLabelledNameFollowsTheSameSpeech() async throws {
        let names = try await Self.reanalyse(
            into: [
                DiarizationInterval(start: 0, end: 15, clusterID: "S2"),
                DiarizationInterval(start: 15, end: 30, clusterID: "S1"),
            ], cloudLabelled: true)
        #expect(names["alphaword"] == "Synthetic Person", "got \(names)")
        #expect(names["charlieword"] != "Synthetic Person", "got \(names)")
    }

    @Test("a voice that re-analysis merged with another does not take either one's name")
    func aMergedVoiceTakesNoName() async throws {
        let names = try await Self.reanalyse(into: [DiarizationInterval(start: 0, end: 30, clusterID: "S1")])
        #expect(!names.values.contains("Synthetic Person"), "half of this voice is somebody else, got \(names)")
    }

    @Test("re-analysis leaves no name behind for a cluster the new run does not have")
    func staleNamesAreRemovedByReanalysis() async throws {
        let result = try await Self.reanalyseWithMap(
            into: [
                DiarizationInterval(start: 0, end: 15, clusterID: "S2"),
                DiarizationInterval(start: 15, end: 30, clusterID: "S1"),
            ],
            extraEntries: [
                "remote-001_speaker_01": SpeakerAssignment(displayName: "Old Guess", origin: .voiceProfile)
            ])
        #expect(result.map.entries["remote-001_speaker_01"] == nil, "got \(result.map.entries)")
        #expect(
            result.map.entries.values.filter { $0.displayName == "Synthetic Person" }.count == 1,
            "the carried name is on one key only, got \(result.map.entries)")
        #expect(result.names["alphaword"] == "Synthetic Person")
    }
}

/// The matching rule on its own, without a pipeline around it.
@Suite("CarryHumanNames")
struct CarryHumanNamesTests {
    private static func run(_ id: String, _ intervals: [(Double, Double, String)]) -> DiarizationRun {
        let spans = intervals.map { DiarizationInterval(start: $0.0, end: $0.1, clusterID: $0.2) }
        let ids = Array(Set(spans.map(\.clusterID))).sorted()
        return DiarizationRun(
            id: id, track: .remote, backend: "test", producedAt: Date(timeIntervalSince1970: 0),
            timelineOffset: 0,
            clusters: ids.map { id in
                DiarizationCluster(
                    id: id,
                    speechSeconds: spans.filter { $0.clusterID == id }.reduce(0) { $0 + $1.duration })
            },
            intervals: spans)
    }

    private static let before = run("remote-001", [(0, 10, "S1"), (10, 20, "S2"), (20, 30, "S1")])
    /// The same speech, numbered the other way round, with edges a little off.
    private static let after = run("remote-002", [(0, 10.4, "S2"), (10.4, 19.8, "S1"), (19.8, 30, "S2")])

    @Test("the name moves to the renumbered voice even when the edges moved")
    func theNameMovesWithJitteredEdges() {
        var map = SpeakerMap()
        map.assign("Synthetic Person", to: "remote-001_speaker_00")
        #expect(map.carryHumanNames(from: Self.before, to: Self.after) == 1)
        #expect(map.entries["remote-002_speaker_01"]?.displayName == "Synthetic Person")
        #expect(map.entries["remote-002_speaker_00"] == nil)
    }

    @Test("a voice that is a quarter somebody else's does not take the name")
    func aMostlyMatchingVoiceTakesNoName() {
        var map = SpeakerMap()
        map.assign("Synthetic Person", to: "remote-001_speaker_00")
        // S1 holds all 20 s of the named voice and 6 s of the other one.
        let mixed = Self.run("remote-002", [(0, 16, "S1"), (16, 20, "S2"), (20, 30, "S1")])
        #expect(map.carryHumanNames(from: Self.before, to: mixed) == 0)
        #expect(map.entries["remote-002_speaker_00"] == nil)
    }

    @Test("a name given to one chunk's label follows the voice that spans every chunk")
    func aChunkLabelledNameFollowsAcrossChunks() {
        // A cloud transcriber numbers speakers per chunk, so the named person
        // is `speaker_00` in both chunks under two different keys.
        let lines = Self.run(
            "remote-lines",
            [
                (0, 10, "remote_chunk_001_speaker_00"), (10, 12, "remote_chunk_001_speaker_01"),
                (20, 30, "remote_chunk_002_speaker_00"), (30, 40, "remote_chunk_002_speaker_01"),
            ])
        let after = Self.run("remote-001", [(0, 10, "S1"), (10, 12, "S2"), (20, 30, "S1"), (30, 40, "S2")])
        var map = SpeakerMap()
        map.assign("Synthetic Person", to: "remote_chunk_001_speaker_00")
        #expect(map.carryHumanNames(from: lines, to: after) == 1)
        #expect(map.entries["remote-001_speaker_00"]?.displayName == "Synthetic Person")
    }

    @Test("a chunk label heard briefly does not name a voice that is mostly another speaker in that chunk")
    func aBriefChunkLabelDoesNotNameAMergedVoice() {
        let lines = Self.run(
            "remote-lines",
            [(0, 10, "remote_chunk_001_speaker_00"), (10, 60, "remote_chunk_001_speaker_01")])
        let merged = Self.run("remote-001", [(0, 60, "S1")])
        var map = SpeakerMap()
        map.assign("Synthetic Person", to: "remote_chunk_001_speaker_00")
        #expect(map.carryHumanNames(from: lines, to: merged) == 0)
    }

    @Test("two people named in different chunks and merged into one voice give it neither name")
    func twoNamedPeopleMergedGiveNoName() {
        let lines = Self.run(
            "remote-lines",
            [(0, 10, "remote_chunk_001_speaker_00"), (20, 30, "remote_chunk_002_speaker_00")])
        let merged = Self.run("remote-001", [(0, 10, "S1"), (20, 30, "S1")])
        var map = SpeakerMap()
        map.assign("Synthetic Person", to: "remote_chunk_001_speaker_00")
        map.assign("Another Person", to: "remote_chunk_002_speaker_00")
        #expect(map.carryHumanNames(from: lines, to: merged) == 0)
        #expect(map.entries["remote-001_speaker_00"] == nil)
    }

    @Test("one person named in two chunks gives the merged voice that name")
    func onePersonNamedTwiceGivesTheName() {
        let lines = Self.run(
            "remote-lines",
            [(0, 10, "remote_chunk_001_speaker_00"), (20, 30, "remote_chunk_002_speaker_00")])
        let merged = Self.run("remote-001", [(0, 10, "S1"), (20, 30, "S1")])
        var map = SpeakerMap()
        map.assign("Synthetic Person", to: "remote_chunk_001_speaker_00")
        map.assign("Synthetic Person", to: "remote_chunk_002_speaker_00")
        map.carryHumanNames(from: lines, to: merged)
        #expect(map.entries["remote-001_speaker_00"]?.displayName == "Synthetic Person")
    }

    @Test("a carried name leaves the person link behind, so it teaches no voice profile")
    func aCarriedNameHasNoPersonLink() {
        var map = SpeakerMap()
        map.assign("Synthetic Person", to: "remote-001_speaker_00", identityID: IdentityID(7))
        map.carryHumanNames(from: Self.before, to: Self.after)
        let carried = map.entries["remote-002_speaker_01"]
        #expect(carried?.origin == .human)
        #expect(carried?.identityID == nil, "the new voice group may be partly someone else's audio")
    }

    @Test("a voice a person left unnamed stays unnamed after re-analysis")
    func aClearedVoiceStaysCleared() {
        var map = SpeakerMap()
        map.assign("", to: "remote-001_speaker_01")
        map.carryHumanNames(from: Self.before, to: Self.after)
        #expect(map.clearedKeys.contains("remote-002_speaker_00"))
        map.applySuggestion(
            SpeakerAssignment(displayName: "Roster Name", origin: .sensor), for: "remote-002_speaker_00")
        #expect(map.entries["remote-002_speaker_00"] == nil)
    }
}
