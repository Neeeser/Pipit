import Foundation
import PipitCore
import PipitServices
import PipitSpeakers
import Testing

/// Scoring unnamed voices against the gallery long after their meetings were
/// processed.
///
/// The case this exists for: a voice seeded from an import processed a week
/// before the local user had any voice profile at all. It scored nothing at the
/// time because there was nothing to score against, and nothing ever asked
/// again. An unnamed voice heard once is deleted after 90 days, so the question
/// has a deadline.
@Suite("SpeakerRematch")
struct SpeakerRematchTests {

    // MARK: helpers

    private static func vector(seed: Int) -> [Float] { SpeakerFixtures.vector(seed: seed) }

    private static func makeStore() throws -> (SpeakerStore, URL) {
        try SpeakerFixtures.makeStore()
    }

    /// An unnamed voice remembered from one meeting, the way `resolve` seeds
    /// one: provisional material, never human verified.
    @discardableResult
    private static func seedVoice(
        _ store: SpeakerStore, meeting: String, cluster: String, vector: [Float],
        seconds: Double = 120, now: Date = Date()
    ) async throws -> Identity {
        let identity = try await store.createAnonymous(state: .ephemeral, now: now)
        _ = try await store.enrol(
            VoiceEnrollmentCandidate(
                identityID: identity.id,
                vector: vector,
                model: .fluidAudioOffline,
                speechSeconds: seconds,
                qualityScore: 1,
                source: .anonymousSeed,
                evidence: VoiceEvidenceFixture.evidence(
                    meeting: meeting, cluster: cluster, seconds: seconds,
                    source: .anonymousSeed
                )
            ),
            now: now
        )
        return identity
    }

    /// A named person with a profile a human stood behind.
    @discardableResult
    private static func enrolPerson(
        _ store: SpeakerStore, name: String, meeting: String, vector: [Float],
        seconds: Double = 120, now: Date = Date()
    ) async throws -> Identity {
        let identity = try await store.createPerson(name: name, now: now)
        _ = try await store.enrol(
            VoiceEnrollmentCandidate(
                identityID: identity.id,
                vector: vector,
                model: .fluidAudioOffline,
                speechSeconds: seconds,
                qualityScore: 1,
                source: .humanConfirmedCluster,
                evidence: VoiceEvidenceFixture.evidence(
                    meeting: meeting, cluster: "\(meeting)-confirmed", seconds: seconds
                )
            ),
            now: now
        )
        return identity
    }

    // MARK: suite

    @Test("a voice heard before its person had a profile is matched once one exists")
    func aVoiceHeardBeforeItsPersonHadAProfileIsMatchedOnceOneExists() async throws {
        // The measured case on this Mac: 0.837 against the local user
        // and 0.333 against the next best, from an import processed a
        // week before the first embedding of that user was stored.
        let (store, root) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)

        let marlow = Self.vector(seed: 401)
        let voice = try await Self.seedVoice(
            store, meeting: "import-1", cluster: "run-1_speaker_00", vector: marlow,
            seconds: 421
        )
        // Enrolled after the import, which is the whole point.
        let person = try await Self.enrolPerson(
            store, name: "Marlow", meeting: "later-1", vector: marlow
        )
        // A second person, so there is a runner-up and the margin means
        // something.
        _ = try await Self.enrolPerson(
            store, name: "Dara", meeting: "later-2", vector: Self.vector(seed: 402)
        )

        let matches = try await service.rematchUnnamedVoices()
        #expect(matches.count == 1)
        let match = try #require(matches.first)
        #expect(match.voice.id == voice.id)
        #expect(match.match.id == person.id)
        #expect(match.resolution.band == .high)
        #expect(match.resolution.outcome == .assign(person.id))
    }

    @Test("the re-score writes nothing")
    func theReScoreWritesNothing() async throws {
        // Recognition reads and human confirmation writes. A second look
        // that promoted or enrolled on its own would be the automatic
        // naming this whole path exists to avoid, one step further on.
        let (store, root) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)

        let marlow = Self.vector(seed: 411)
        let voice = try await Self.seedVoice(
            store, meeting: "import-1", cluster: "run-1_speaker_00", vector: marlow
        )
        _ = try await Self.enrolPerson(store, name: "Marlow", meeting: "later-1", vector: marlow)
        _ = try await Self.enrolPerson(
            store, name: "Dara", meeting: "later-2", vector: Self.vector(seed: 412)
        )
        let before = try await store.statistics()

        let matchCount = try await service.rematchUnnamedVoices().count
        #expect(matchCount == 1)

        let after = try await store.statistics()
        #expect(after.embeddings == before.embeddings, "no vector was stored")
        #expect(after.namedPeople == before.namedPeople)
        #expect(after.recurringVoices == before.recurringVoices, "nothing was promoted")
        #expect(after.candidateVoices == before.candidateVoices)
        let current = try await store.current(voice.id)
        let unchanged = try #require(current)
        #expect(unchanged.state == .ephemeral, "and it was not promoted")
        #expect(unchanged.mergedInto == nil, "nor merged into the person it matched")
    }

    @Test("a voice does not match itself")
    func aVoiceDoesNotMatchItself() async throws {
        // Its own centroid scores 1.0. The gallery excludes it for the
        // same reason `excludingSeededIn` does during processing.
        let (store, root) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        _ = try await Self.seedVoice(
            store, meeting: "m1", cluster: "run-1_speaker_00", vector: Self.vector(seed: 421)
        )
        let matches = try await service.rematchUnnamedVoices()
        #expect(matches.isEmpty)
    }

    @Test("two voices seeded from one meeting are not offered as each other")
    func twoVoicesSeededFromOneMeetingAreNotOfferedAsEachOther() async throws {
        // Same meeting, near-identical centroids. The pass that made
        // them had the timing to say whether they talked over each
        // other and decided they were two people; this one has
        // centroids alone, so it leaves that decision alone.
        let (store, root) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        let base = Self.vector(seed: 431)
        _ = try await Self.seedVoice(
            store, meeting: "m1", cluster: "run-1_speaker_00", vector: base
        )
        _ = try await Self.seedVoice(
            store, meeting: "m1", cluster: "run-1_speaker_01",
            vector: SpeakerFixtures.blended(base, with: Self.vector(seed: 432), towards: 0.05)
        )
        let matches = try await service.rematchUnnamedVoices()
        #expect(matches.isEmpty)
    }

    @Test("the same voice under two numbers from two meetings is offered")
    func theSameVoiceUnderTwoNumbersFromTwoMeetingsIsOffered() async throws {
        // Different meetings, so nothing about the timing of one says
        // anything about the other. This is the join the first pass
        // could not make because neither profile existed when the other
        // meeting ran.
        let (store, root) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        let shared = Self.vector(seed: 441)
        let first = try await Self.seedVoice(
            store, meeting: "m1", cluster: "run-1_speaker_00", vector: shared
        )
        let second = try await Self.seedVoice(
            store, meeting: "m2", cluster: "run-2_speaker_00", vector: shared
        )
        // A third voice, so the margin has a runner-up to measure.
        _ = try await Self.seedVoice(
            store, meeting: "m3", cluster: "run-3_speaker_00", vector: Self.vector(seed: 442)
        )

        let matches = try await service.rematchUnnamedVoices()
        #expect(matches.count == 2, "each half of the pair points at the other")
        let pairs = Set(matches.map { [$0.voice.id, $0.match.id] as Set })
        #expect(pairs == [[first.id, second.id] as Set])
        #expect(matches.allSatisfy { $0.resolution.outcome == .seenBefore($0.match.id) })
    }

    @Test("a named person is never scored as an unnamed voice")
    func aNamedPersonIsNeverScoredAsAnUnnamedVoice() async throws {
        let (store, root) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        let shared = Self.vector(seed: 451)
        _ = try await Self.enrolPerson(store, name: "Marlow", meeting: "m1", vector: shared)
        _ = try await Self.enrolPerson(store, name: "Andy", meeting: "m2", vector: shared)
        let matches = try await service.rematchUnnamedVoices()
        #expect(
            matches.isEmpty,
            "two people who sound alike are a merge the user makes, not a match"
        )
    }

    @Test("a voice in the suggestion band is left alone")
    func aVoiceInTheSuggestionBandIsLeftAlone() async throws {
        // Blended 45% of the way towards Marlow, which lands near 0.60:
        // over the 0.55 the policy will suggest at and under the 0.70 it
        // will name at. Offering it would put in front of the user a
        // decision the numbers cannot settle, which is the case for
        // showing the band rather than for hiding the row, and is a
        // change of its own.
        let (store, root) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        let marlow = Self.vector(seed: 461)
        let nearly = SpeakerFixtures.blended(
            Self.vector(seed: 462), with: marlow, towards: 0.45
        )
        // Pinned, so a fixture that drifts out of the band says so here
        // rather than passing for the wrong reason.
        let score = VoiceVector.cosine(nearly, marlow)
        #expect(
            score > SpeakerResolutionPolicy.shipping.mediumScore
                && score < SpeakerResolutionPolicy.shipping.namedHighScore,
            "fixture should sit in the suggestion band, scored \(score)"
        )
        _ = try await Self.seedVoice(
            store, meeting: "m1", cluster: "run-1_speaker_00", vector: nearly
        )
        _ = try await Self.enrolPerson(store, name: "Marlow", meeting: "m2", vector: marlow)
        _ = try await Self.enrolPerson(
            store, name: "Dara", meeting: "m3", vector: Self.vector(seed: 463)
        )
        let matches = try await service.rematchUnnamedVoices()
        #expect(matches.isEmpty, "under 0.70 nothing is offered")
    }

    @Test("confirming a match names the meeting the voice was only seeded in")
    func confirmingAMatchNamesTheMeetingTheVoiceWasOnlySeededIn() async throws {
        // The failure this guards. A voice the first pass merely
        // remembered was never written into a speaker map: it lives in
        // an occurrence row and nowhere else. Merging it into the person
        // renames nothing a reader can see, because `refreshCachedNames`
        // rewrites entries that already carry an identity and there is
        // no entry to rewrite.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SpeakerStore(
            url: root.appendingPathComponent("voices.sqlite")
        )
        let meeting = try PipelineFixtures.makeRecordedMeeting(root: root)
        let key = "remote-001_speaker_00"

        try meeting.store.writeCanonicalTranscript(CanonicalTranscript(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            utterances: [PeopleFixtures.utterance(key, "We ship Friday.", at: 0)]
        ))
        // No speaker map entry, which is the state a seeded voice leaves
        // behind.
        try meeting.store.writeSpeakerMap(SpeakerMap())

        let voice = try await Self.seedVoice(
            store, meeting: meeting.metadata.id, cluster: key, vector: Self.vector(seed: 481)
        )
        try await store.recordOccurrence(
            meetingID: meeting.metadata.id, clusterID: key, track: .remote,
            speechSeconds: 120, embedding: nil, model: nil, resolution: nil,
            identityID: voice.id, source: .ai,
            humanVerified: false, wasExpectedParticipant: false
        )
        let marlow = try await Self.enrolPerson(
            store, name: "Marlow", meeting: "later-1", vector: Self.vector(seed: 481)
        )

        let pipeline = ProcessingPipeline(
            repository: meeting.repository,
            backend: FakeAIBackend(),
            backends: ProcessingBackends(
                transcription: { _, _ in fatalError("not reached") },
                diarization: { _, _ in fatalError("not reached") },
                speakers: SpeakerRecognitionService(store: store)
            ),
            clock: ManualClock(),
            settingsProvider: { AppSettings() },
            wait: { _ in }
        )
        try await pipeline.applyRematch(
            voice: voice.id, into: marlow.id, named: "Marlow"
        )

        let map = try meeting.store.readSpeakerMap()
        #expect(map.displayName(for: key) == "Marlow", "the transcript now names him")
        #expect(map.entries[key]?.identityID == marlow.id)
        let current = try await store.current(voice.id)
        let merged = try #require(current)
        #expect(merged.id == marlow.id, "and the voice resolves to him")
    }
}
