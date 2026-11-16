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

    /// A 30 s call with two far-end voices, the first named by a person, then
    /// re-analysed into `reclustered`. Returns the name each far-end line reads
    /// under afterwards.
    private static func reanalyse(into reclustered: [DiarizationInterval]) async throws -> [String: String] {
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
        var map = try store.readSpeakerMap()
        map.assign("Synthetic Person", to: "remote-001_speaker_00")
        try store.writeSpeakerMap(map)

        try await pipeline.reanalyzeSpeakers(meetingID: id, speakerCount: nil)

        let after = try #require(meeting.repository.findMeeting(id: id)?.store)
        let transcript = try #require(try after.readCanonicalTranscript())
        let names = try after.readSpeakerMap()
        var out: [String: String] = [:]
        for utterance in transcript.utterances where utterance.track == .remote {
            out[utterance.text.trimmingCharacters(in: .whitespaces)] = names.resolvedName(for: utterance)
        }
        return out
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

    @Test("a voice that re-analysis merged with another does not take either one's name")
    func aMergedVoiceTakesNoName() async throws {
        let names = try await Self.reanalyse(into: [DiarizationInterval(start: 0, end: 30, clusterID: "S1")])
        #expect(!names.values.contains("Synthetic Person"), "half of this voice is somebody else, got \(names)")
    }
}
