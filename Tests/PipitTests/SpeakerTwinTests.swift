import Foundation
import PipitCore
import PipitSpeakers
import Testing

// Anonymous copies of a known voice.
//
// A cluster of a known person that missed the naming margin used to seed an
// anonymous identity of the same voice. That copy scored within a hundredth of
// the person in every later meeting, which failed the margin again and seeded
// another. These tests cover the three places the loop is cut: no new copy is
// seeded, existing copies are folded into the person, and a copy that still
// exists does not take the person's margin.

@Suite("SpeakerTwins")
struct SpeakerTwinTests {
    private static let personVoice = SpeakerFixtures.vector(seed: 501)
    /// Cosine ~0.97 to `personVoice`.
    private static let twinVoice = SpeakerFixtures.blended(
        personVoice, with: SpeakerFixtures.vector(seed: 502), towards: 0.2)
    /// Cosine ~0.5 to `personVoice`.
    private static let strangerVoice = SpeakerFixtures.blended(
        personVoice, with: SpeakerFixtures.vector(seed: 503), towards: 0.63)

    @discardableResult
    private static func enrolPerson(
        _ store: SpeakerStore, name: String, vector: [Float], meeting: String
    ) async throws -> Identity {
        let person = try await store.createPerson(name: name)
        _ = try await store.enrol(
            VoiceEnrollmentCandidate(
                identityID: person.id, vector: vector, model: .fluidAudioOffline,
                speechSeconds: 120, qualityScore: 1, source: .humanConfirmedCluster,
                evidence: VoiceEvidenceFixture.evidence(
                    meeting: meeting, seconds: 120, source: .humanConfirmedCluster)
            ))
        return person
    }

    @discardableResult
    private static func seedVoice(
        _ store: SpeakerStore, vector: [Float], meeting: String,
        source: VoiceEnrollmentSource = .anonymousSeed,
        state: IdentityState = .ephemeral
    ) async throws -> Identity {
        let voice = try await store.createAnonymous(state: state)
        _ = try await store.enrol(
            VoiceEnrollmentCandidate(
                identityID: voice.id, vector: vector, model: .fluidAudioOffline,
                speechSeconds: 120, qualityScore: 1, source: source,
                evidence: VoiceEvidenceFixture.evidence(
                    meeting: meeting, seconds: 120, source: source)
            ))
        return voice
    }

    private static func cluster(_ key: String, vector: [Float]) -> SpeakerClusterInput {
        let start = VoiceEvidenceFixture.lane(key)
        return SpeakerClusterInput(
            clusterID: key, track: .remote, speechSeconds: 120, centroid: vector,
            spans: [AudioSpan(start: start, end: start + 120)]
        )
    }

    // MARK: seeding

    @Test("a voice that scores like a known one is not remembered a second time")
    func aVoiceThatScoresLikeAKnownOneIsNotRememberedASecondTime() async throws {
        // With one person in the gallery there is no runner-up, so the cluster
        // is offered as a suggestion. That is a known voice that is only
        // ambiguous, and seeding an anonymous copy of it is what started the
        // loop.
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        try await Self.enrolPerson(store, name: "Ann", vector: Self.personVoice, meeting: "m0")

        let resolved = try await service.resolve(
            meetingID: "m1",
            clusters: [Self.cluster("run-001_speaker_00", vector: Self.twinVoice)],
            settings: SpeakerRecognitionSettings()
        )
        #expect(resolved.first?.resolution.outcome == .suggest)
        #expect(resolved.first?.createdIdentity == false)
        #expect(try await store.identities(kind: .anonymous).isEmpty)
    }

    @Test("a voice that scores like nobody known is still remembered")
    func aVoiceThatScoresLikeNobodyKnownIsStillRemembered() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        try await Self.enrolPerson(store, name: "Ann", vector: Self.personVoice, meeting: "m0")

        let resolved = try await service.resolve(
            meetingID: "m1",
            clusters: [
                Self.cluster("run-001_speaker_00", vector: SpeakerFixtures.vector(seed: 504))
            ],
            settings: SpeakerRecognitionSettings()
        )
        #expect(resolved.first?.createdIdentity == true)
        #expect(try await store.identities(kind: .anonymous).count == 1)
    }

    // MARK: recognition with a copy already stored

    @Test("a person is named even though an anonymous copy of them is stored")
    func aPersonIsNamedEvenThoughAnAnonymousCopyOfThemIsStored() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        let ann = try await Self.enrolPerson(
            store, name: "Ann", vector: Self.personVoice, meeting: "m0")
        try await Self.enrolPerson(
            store, name: "Bo", vector: SpeakerFixtures.vector(seed: 505), meeting: "m0b")
        try await Self.seedVoice(store, vector: Self.twinVoice, meeting: "m00")

        let resolved = try await service.resolve(
            meetingID: "m1",
            clusters: [Self.cluster("run-001_speaker_00", vector: Self.personVoice)],
            settings: SpeakerRecognitionSettings()
        )
        #expect(resolved.first?.identity?.id == ann.id)
        #expect(resolved.first?.resolution.outcome == .assign(ann.id))
    }

    // MARK: consolidation

    @Test("a copy of a person is folded into them and the profile is unchanged")
    func aCopyOfAPersonIsFoldedIntoThemAndTheProfileIsUnchanged() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let ann = try await Self.enrolPerson(
            store, name: "Ann", vector: Self.personVoice, meeting: "m0")
        let copy = try await Self.seedVoice(store, vector: Self.twinVoice, meeting: "m1")
        let later = try await Self.seedVoice(
            store, vector: Self.twinVoice, meeting: "m2", state: .persistent)
        _ = try await store.recordOccurrence(
            meetingID: "m1", clusterID: "run-001_speaker_00", track: .remote,
            speechSeconds: 120, embedding: Self.twinVoice, model: .fluidAudioOffline,
            resolution: nil, identityID: copy.id, source: .ai, humanVerified: false,
            wasExpectedParticipant: false
        )
        let before = try #require(
            try await store.searchableProfiles(model: .fluidAudioOffline)
                .first { $0.identity.id == ann.id })

        let result = try await store.foldAnonymousTwins()
        #expect(result.intoPeople == 2)
        #expect(result.intoLocalUser == 0)

        #expect(try await store.current(copy.id)?.id == ann.id)
        #expect(try await store.current(later.id)?.id == ann.id)
        #expect(
            try await store.occurrences(meetingID: "m1").first?.resolvedIdentityID == copy.id,
            "the occurrence is untouched and reads as Ann through the merge")
        #expect(try await store.meetingsReferencing(ann.id).contains("m1"))
        let after = try #require(
            try await store.searchableProfiles(model: .fluidAudioOffline)
                .first { $0.identity.id == ann.id })
        #expect(after.sampleCount == before.sampleCount, "provisional seeds stay out of the profile")
        #expect(VoiceVector.cosine(after.centroid, before.centroid) > 0.9999)
        #expect(try await store.identities(kind: .anonymous).isEmpty)

        let again = try await store.foldAnonymousTwins()
        #expect(again.total == 0, "a second run has nothing left to fold")
    }

    @Test("a copy of the local user counts toward the local user")
    func aCopyOfTheLocalUserCountsTowardTheLocalUser() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let me = try await store.createPerson(name: "Me", isLocalUser: true)
        _ = try await store.enrol(
            VoiceEnrollmentCandidate(
                identityID: me.id, vector: Self.personVoice, model: .fluidAudioOffline,
                speechSeconds: 120, qualityScore: 1, source: .micTrackDeterministic,
                evidence: VoiceEvidenceFixture.evidence(
                    meeting: "m0", seconds: 120, source: .micTrackDeterministic)
            ))
        try await Self.seedVoice(store, vector: Self.twinVoice, meeting: "m1")

        let result = try await store.foldAnonymousTwins()
        #expect(result.intoLocalUser == 1)
        #expect(result.intoPeople == 0)
    }

    @Test("an unrelated anonymous voice is left alone")
    func anUnrelatedAnonymousVoiceIsLeftAlone() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.enrolPerson(store, name: "Ann", vector: Self.personVoice, meeting: "m0")
        let stranger = try await Self.seedVoice(
            store, vector: Self.strangerVoice, meeting: "m1", state: .persistent)

        let result = try await store.foldAnonymousTwins()
        #expect(result.total == 0)
        #expect(try await store.current(stranger.id)?.id == stranger.id)
    }

    @Test("a copy that resembles two people is not folded into either")
    func aCopyThatResemblesTwoPeopleIsNotFoldedIntoEither() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.enrolPerson(store, name: "Ann", vector: Self.personVoice, meeting: "m0")
        let other = SpeakerFixtures.blended(
            Self.personVoice, with: SpeakerFixtures.vector(seed: 506), towards: 0.2)
        try await Self.enrolPerson(store, name: "Bo", vector: other, meeting: "m0b")
        let between = SpeakerFixtures.blended(Self.personVoice, with: other, towards: 0.5)
        let voice = try await Self.seedVoice(store, vector: between, meeting: "m1")

        let result = try await store.foldAnonymousTwins()
        #expect(result.total == 0)
        #expect(try await store.current(voice.id)?.id == voice.id)
    }

    @Test("an unnamed voice a person confirmed material for is left for them")
    func anUnnamedVoiceAPersonConfirmedMaterialForIsLeftForThem() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.enrolPerson(store, name: "Ann", vector: Self.personVoice, meeting: "m0")
        let voice = try await Self.seedVoice(
            store, vector: Self.twinVoice, meeting: "m1",
            source: .humanConfirmedCluster, state: .persistent)

        let result = try await store.foldAnonymousTwins()
        #expect(result.total == 0)
        #expect(try await store.current(voice.id)?.id == voice.id)
    }
}
