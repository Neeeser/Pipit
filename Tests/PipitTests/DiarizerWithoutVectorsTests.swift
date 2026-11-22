import Foundation
import PipitCore
import PipitServices
import PipitSpeakers
import Testing

/// A local diarizer that returns intervals and no speaker vectors, the shape
/// Nemotron 3 has. Voice memory has to extract the vectors itself and match
/// them to saved profiles exactly as it does for the offline clusterer's.

/// Returns a fixed voice for every interval of one cluster and a stranger's
/// voice for the rest, standing in for the embedding model.
private struct FixedVoiceExtractor: SpeakerEmbeddingExtractor {
    var voices: [String: Int]
    var model: EmbeddingModelIdentifier { .fluidAudioOffline }

    func embed(
        audio: URL, intervals: [DiarizationInterval]
    ) async throws -> [DiarizationChunkEmbedding] {
        intervals.map {
            DiarizationChunkEmbedding(
                clusterID: $0.clusterID, start: $0.start, end: $0.end,
                vector: SpeakerFixtures.vector(seed: voices[$0.clusterID] ?? 7)
            )
        }
    }
}

@Suite("DiarizerWithoutVectors")
struct DiarizerWithoutVectorsTests {
    private static let personVoice = 92
    private static let localVoice = 41

    private struct Result {
        var farEndNames: Set<String>
        var farEndKeys: [String]
        var map: SpeakerMap
    }

    /// Processes a one-minute call whose far end the diarizer splits into two
    /// slots, the first a saved person and the second nobody known.
    private static func process(priorMap: ((Identity) -> SpeakerMap)? = nil) async throws -> Result {
        let root = try TestPaths.makeTemporaryDirectory()
        let (store, storeRoot) = try SpeakerFixtures.makeStore()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: storeRoot)
        }
        let me = try await store.createPerson(name: "Marlow", isLocalUser: true)
        let person = try await store.createPerson(name: "Dara K")
        for (identity, seed) in [(me, localVoice), (person, personVoice)] {
            _ = try await store.enrol(
                VoiceEnrollmentCandidate(
                    identityID: identity.id,
                    vector: SpeakerFixtures.vector(seed: seed),
                    model: .fluidAudioOffline, speechSeconds: 60, qualityScore: 1,
                    source: .humanConfirmedUtterances,
                    evidence: VoiceEvidenceFixture.evidence(
                        meeting: "m0", seconds: 60, source: .humanConfirmedUtterances,
                        start: Double(seed) * 100
                    )
                ))
        }

        let meeting = try PipelineFixtures.makeRecordedMeeting(
            root: root, source: .genericCall, seconds: 60
        )
        _ = try meeting.store.updateMetadata { $0.cleaningOutcome = .bypassedNoEchoPath }
        try meeting.store.writeSpeechEvidence(
            SpeechEvidence(
                levelWindowSeconds: 0.25, speechWindowSeconds: 0.25,
                micLevels: [Int8](repeating: -60, count: 240),
                remoteLevels: [Int8](repeating: -18, count: 240),
                micSpeech: [Int8](repeating: 0, count: 240),
                detector: "silero"
            ))
        let words = (0..<50).map {
            RawTranscriptWord(start: Double($0), end: Double($0) + 0.5, text: " word")
        }
        if let priorMap { try meeting.store.writeSpeakerMap(priorMap(person)) }
        var settings = AppSettings()
        settings.enrichment = EnrichmentSettings(
            generateTitle: false, generateDescription: false, generateNotes: false,
            generateSummary: false, suggestSpeakers: false
        )
        settings.localUserName = "Marlow"
        settings.processing.localUserIdentityID = me.id

        var diarizer = StubLocalDiarizer(
            intervals: [
                DiarizationInterval(start: 0, end: 47, clusterID: "nemotron3_0"),
                DiarizationInterval(start: 47, end: 59, clusterID: "nemotron3_1"),
            ],
            chunkEmbeddings: []
        )
        diarizer.producesEmbeddings = false
        let pipeline = PipelineFixtures.makePipeline(
            repository: meeting.repository, backend: FakeAIBackend(),
            transcriber: StubLocalTranscriber(segments: [
                RawTranscriptSegment(
                    start: 0, end: 50, text: words.map(\.text).joined(), speaker: nil,
                    words: words
                )
            ]),
            diarizer: diarizer,
            speakers: SpeakerRecognitionService(store: store),
            embeddings: FixedVoiceExtractor(voices: ["nemotron3_0": personVoice]),
            settings: settings, scratchRoot: root.appendingPathComponent("scratch")
        )
        await pipeline.process(meetingID: meeting.metadata.id)

        let map = try meeting.store.readSpeakerMap()
        let keys = try meeting.store.readTranscriptSpeakers()
            .map(\.key).filter { $0 != SpeakerLabel.localUser }
        return Result(
            farEndNames: Set(keys.compactMap { map.entries[$0]?.displayName }),
            farEndKeys: keys, map: map
        )
    }

    @Test("a diarizer with no vectors still names a speaker from a saved profile")
    func aDiarizerWithNoVectorsStillNamesASpeaker() async throws {
        let result = try await Self.process()
        #expect(result.farEndKeys.contains { $0.hasSuffix("nemotron3_0") })
        #expect(result.farEndNames == ["Dara K"])
    }

    @Test("names of clusters a different diarizer no longer has are removed, a person's are kept")
    func namesOfVanishedClustersAreRemoved() async throws {
        let result = try await Self.process { person in
            SpeakerMap(entries: [
                "remote-001_speaker_00": SpeakerAssignment(
                    displayName: "Old Voice", origin: .voiceProfile),
                // The same person a human named under the old numbering.
                "remote-001_speaker_01": SpeakerAssignment(
                    displayName: "Dara K", origin: .human, identityID: person.id),
                "remote-001_speaker_02": SpeakerAssignment(
                    displayName: "Typed Name", origin: .human),
            ])
        }
        #expect(result.farEndNames == ["Dara K"])
        #expect(result.map.entries["remote-001_speaker_00"] == nil)
        #expect(result.map.entries["remote-001_speaker_01"] == nil, "carried by the new key")
        #expect(result.map.entries["remote-001_speaker_02"]?.displayName == "Typed Name")
    }
}
