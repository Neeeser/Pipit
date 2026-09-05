import Foundation
import PipitCore
import PipitSpeakers
import Testing

// The rules that decide whether a voice gets a name, and what may ever be
// written into a profile.
//
// Every threshold here has a measurement behind it, and every one of them is a
// value that a well-meaning change could relax into a wrong name on somebody
// else's transcript.

private let policy = SpeakerResolutionPolicy.shipping

@Suite("SpeakerPolicy")
struct SpeakerPolicyTests {
    private static func person(_ id: Int64, _ score: Double, expected: Bool = false) -> SpeakerCandidate {
        SpeakerCandidate(
            identityID: IdentityID(id), kind: .person, displayName: "P\(id)",
            score: score, isExpectedParticipant: expected
        )
    }

    private static func anonymous(_ id: Int64, _ score: Double) -> SpeakerCandidate {
        SpeakerCandidate(
            identityID: IdentityID(id), kind: .anonymous, displayName: "Anonymous #\(id)",
            score: score
        )
    }

    @Test("naming a person needs score, margin and duration together")
    func namingAPersonNeedsScoreMarginAndDurationTogether() async throws {
        let candidates = [Self.person(1, 0.81), Self.person(2, 0.40)]
        let resolved = policy.resolve(candidates: candidates, speechSeconds: 84)
        #expect(resolved.band == .high)
        #expect(resolved.outcome == .assign(IdentityID(1)))
        #expect(
            abs((resolved.margin ?? 0) - 0.41) <= 0.001,
            "expected \(0.41) ± \(0.001), got \(resolved.margin ?? 0)"
        )
    }

    @Test("a score that clears the bar with too little speech is not a name")
    func aScoreThatClearsTheBarWithTooLittleSpeechIsNotAName() async throws {
        // 45 seconds is where the false-reject rate at 0.70 drops below
        // 1.5%. Below it the genuine floor sits under any safe threshold.
        let resolved = policy.resolve(candidates: [Self.person(1, 0.95), Self.person(2, 0.20)], speechSeconds: 30)
        #expect(resolved.band != .high)
        #expect(!resolved.outcome.isAutomatic)
    }

    @Test("under ten seconds nothing is named, whatever it scored")
    func underTenSecondsNothingIsNamedWhateverItScored() async throws {
        // At nine seconds the 1st percentile of genuine scores is 0.282
        // and an impostor reached 0.821.
        let resolved = policy.resolve(candidates: [Self.person(1, 0.99)], speechSeconds: 9)
        #expect(resolved.band == .unknown)
        #expect(resolved.outcome == .unknown)
        #expect(resolved.suggestions.isEmpty, "not even a suggestion below the floor")
        #expect(resolved.best?.identityID == IdentityID(1), "the reason is still reported")
    }

    @Test("two close candidates are never named automatically")
    func twoCloseCandidatesAreNeverNamedAutomatically() async throws {
        // The measured worst case: an impostor at 0.957 outranking the
        // true speaker's own 0.951. Score alone names the wrong person.
        let resolved = policy.resolve(
            candidates: [Self.person(1, 0.957), Self.person(2, 0.951)], speechSeconds: 300
        )
        #expect(!resolved.outcome.isAutomatic, "margin 0.006 must not auto-assign")
        #expect(resolved.band == .medium)
        #expect(resolved.suggestions.count == 2)
    }

    @Test("a listed participant relaxes the margin and nothing else")
    func aListedParticipantRelaxesTheMarginAndNothingElse() async throws {
        let listed = policy.resolve(
            candidates: [Self.person(1, 0.80, expected: true), Self.person(2, 0.73)],
            speechSeconds: 90
        )
        #expect(listed.outcome == .assign(IdentityID(1)), "0.07 clears the relaxed bar")

        let unlisted = policy.resolve(
            candidates: [Self.person(1, 0.80), Self.person(2, 0.73)], speechSeconds: 90
        )
        #expect(!unlisted.outcome.isAutomatic, "0.07 does not clear the normal bar")

        // The score gate itself never moves for a listed participant.
        let weak = policy.resolve(
            candidates: [Self.person(1, 0.62, expected: true)], speechSeconds: 300
        )
        #expect(!weak.outcome.isAutomatic, "being invited is not evidence of speaking")
    }

    @Test("an unnamed voice is linked at a stricter bar than a named one")
    func anUnnamedVoiceIsLinkedAtAStricterBarThanANamedOne() async throws {
        // 0.75 rather than 0.70, because the false-link rate for a
        // genuinely new voice grows with pool size where named matching
        // does not, and a wrong anonymous merge corrupts a profile no
        // human has ever looked at.
        let borderline = policy.resolve(
            candidates: [Self.anonymous(7, 0.72), Self.anonymous(8, 0.40)], speechSeconds: 120
        )
        #expect(!borderline.outcome.isAutomatic)

        let linked = policy.resolve(
            candidates: [Self.anonymous(7, 0.80), Self.anonymous(8, 0.40)], speechSeconds: 120
        )
        #expect(linked.outcome == .seenBefore(IdentityID(7)))
        #expect(linked.band == .high)
    }

    @Test("one candidate has no runner-up, so it is offered rather than applied")
    func oneCandidateHasNoRunnerUpSoItIsOfferedRatherThanApplied() async throws {
        // The margin gate exists because the worst impostor over 326
        // verified-distinct speakers scored 0.957 against the true
        // speaker's own 0.951: no absolute score separates a stranger
        // from the person they resemble. With one voice in the gallery
        // there is no separation to measure, and both ways of pretending
        // otherwise are wrong. Treating the absent runner-up as scoring
        // zero made the margin the whole score, so anything over 0.10
        // passed. Requiring score plus margin instead invents a
        // single-candidate bar nothing was calibrated against.
        for score in [0.72, 0.81, 0.95] {
            let alone = policy.resolve(candidates: [Self.person(1, score)], speechSeconds: 300)
            #expect(
                !alone.outcome.isAutomatic,
                "\(score) against one candidate proves no separation from anyone"
            )
            #expect(alone.band == .medium, "it is offered, and the user confirms once")
            #expect(alone.suggestions.first?.identityID == IdentityID(1))
            #expect(alone.margin == nil, "and no margin is reported, because none was measured")
        }

        // A real runner-up is what makes the separation measurable.
        #expect(
            policy.resolve(
                candidates: [Self.person(1, 0.81), Self.person(2, 0.60)], speechSeconds: 300
            ).outcome == .assign(IdentityID(1))
        )

        // The same for a remembered unnamed voice, at its own bar.
        #expect(
            !(policy.resolve(candidates: [Self.anonymous(7, 0.95)], speechSeconds: 120)
                .outcome.isAutomatic)
        )
        #expect(
            policy.resolve(
                candidates: [Self.anonymous(7, 0.86), Self.anonymous(8, 0.60)], speechSeconds: 120
            ).outcome == .seenBefore(IdentityID(7))
        )
    }

    @Test("two clusters that do not overlap may be one person")
    func twoClustersThatDoNotOverlapMayBeOnePerson() async throws {
        // The tuned clusterer prefers splitting a speaker over merging
        // two, so one recurring voice arriving as two clusters is the
        // expected failure and is recoverable by naming both.
        let candidates = [Self.person(1, 0.85), Self.person(2, 0.55)]
        #expect(
            policy.resolve(candidates: candidates, speechSeconds: 90).outcome == .assign(IdentityID(1))
        )
        // Once that person is already speaking over this audio they are
        // not available: one person is not two people talking at once.
        let overlapping = policy.resolve(
            candidates: candidates, speechSeconds: 90, concurrent: [IdentityID(1)]
        )
        #expect(
            !overlapping.outcome.isAutomatic,
            "two clusters talking over each other are two people, whatever they score"
        )
        #expect(
            overlapping.suggestions.first?.identityID == IdentityID(1),
            "still offered, because the user may know the diarizer doubled a turn"
        )
    }

    @Test("an ambiguous unnamed match stays two separate voices")
    func anAmbiguousUnnamedMatchStaysTwoSeparateVoices() async throws {
        let resolved = policy.resolve(
            candidates: [Self.anonymous(7, 0.79), Self.anonymous(8, 0.76)], speechSeconds: 200
        )
        #expect(!resolved.outcome.isAutomatic, "0.03 of margin is not a merge")
    }

    @Test("at most three candidates are offered, and none below the bar")
    func atMostThreeCandidatesAreOfferedAndNoneBelowTheBar() async throws {
        let resolved = policy.resolve(
            candidates: [Self.person(1, 0.66), Self.person(2, 0.64), Self.person(3, 0.62),
                         Self.person(4, 0.60), Self.person(5, 0.30)],
            speechSeconds: 60
        )
        #expect(resolved.band == .medium)
        #expect(resolved.suggestions.count == 3)
        #expect(resolved.suggestions.allSatisfy { $0.score >= policy.mediumScore })
    }

    @Test("an empty gallery is Unknown rather than an error")
    func anEmptyGalleryIsUnknownRatherThanAnError() async throws {
        let resolved = policy.resolve(candidates: [], speechSeconds: 300)
        #expect(resolved.outcome == .unknown)
        #expect(resolved.best == nil)
    }

    @Test("only clean speech past the enrolment bar becomes a remembered voice")
    func onlyCleanSpeechPastTheEnrolmentBarBecomesARememberedVoice() async throws {
        #expect(!policy.qualifiesForAnonymousProfile(speechSeconds: 44))
        #expect(policy.qualifiesForAnonymousProfile(speechSeconds: 45))
        #expect(!policy.qualifiesForEnrolment(speechSeconds: 30))
        #expect(policy.qualifiesForEnrolment(speechSeconds: 60))
    }
}
@Suite("VoiceVector")
struct VoiceVectorTests {
    @Test("similarity is computed on normalized vectors, not raw dot products")
    func similarityIsComputedOnNormalizedVectorsNotRawDotProducts() async throws {
        let base = SpeakerFixtures.vector(seed: 1)
        let scaled = base.map { $0 * 17 }
        #expect(
            abs(VoiceVector.cosine(base, scaled) - 1.0) <= 0.0001,
            "expected \(1.0) ± \(0.0001), got \(VoiceVector.cosine(base, scaled))"
        )
        #expect(
            abs((VoiceVector.cosine(base, SpeakerFixtures.vector(seed: 2))) - 0) <= 0.3,
            "expected \(0) ± \(0.3), got \(VoiceVector.cosine(base, SpeakerFixtures.vector(seed: 2)))"
        )
    }

    @Test("a centroid sits closer to its own samples than to another voice")
    func aCentroidSitsCloserToItsOwnSamplesThanToAnotherVoice() async throws {
        let mine = (0..<5).map { SpeakerFixtures.vector(seed: 100, jitter: Float($0) * 0.01) }
        let centroid = VoiceVector.centroid(mine)
        let ownScore = VoiceVector.cosine(centroid, mine[0])
        let otherScore = VoiceVector.cosine(centroid, SpeakerFixtures.vector(seed: 900))
        #expect(ownScore > otherScore + 0.3, "\(ownScore) vs \(otherScore)")
        #expect(
            abs(VoiceVector.cosine(centroid, centroid) - 1.0) <= 0.0001,
            "expected \(1.0) ± \(0.0001), got \(VoiceVector.cosine(centroid, centroid))"
        )
    }

    @Test("vectors survive the blob round trip byte for byte")
    func vectorsSurviveTheBlobRoundTripByteForByte() async throws {
        let original = SpeakerFixtures.vector(seed: 42)
        let decoded = try #require(VoiceVector.decode(VoiceVector.encode(original)))
        #expect(decoded.count == 256)
        #expect(VoiceVector.encode(original).count == 1_024, "Float32, 4 bytes each")
        for index in 0..<original.count {
            #expect(
                abs(Double(decoded[index]) - Double(original[index])) <= 1e-7,
                "expected \(Double(original[index])) ± \(1e-7), got \(Double(decoded[index]))"
            )
        }
    }

    @Test("a truncated blob decodes as nothing rather than as garbage")
    func aTruncatedBlobDecodesAsNothingRatherThanAsGarbage() async throws {
        var data = VoiceVector.encode(SpeakerFixtures.vector(seed: 1))
        data.removeLast()
        #expect(VoiceVector.decode(data) == nil)
    }
}
@Suite("SpeakerStore")
struct SpeakerStoreTests {
    @Test("a person, their embeddings and their profile round trip")
    func aPersonTheirEmbeddingsAndTheirProfileRoundTrip() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let bryn = try await store.createPerson(name: "Bryn", organization: "Acme")
        let result = try await store.enrol(VoiceEnrollmentCandidate(
            identityID: bryn.id, vector: SpeakerFixtures.vector(seed: 3), model: .fluidAudioOffline,
            speechSeconds: 90, qualityScore: 1, source: .humanConfirmedCluster,
            evidence: VoiceEvidenceFixture.evidence(meeting: "m1", cluster: "c1", seconds: 90, source: .humanConfirmedCluster)
        ))
        guard case .success = result else {
            Issue.record("enrolment refused: \(result)")
            return
        }
        let profiles = try await store.searchableProfiles(model: .fluidAudioOffline)
        #expect(profiles.count == 1)
        #expect(profiles.first?.identity.resolvedName == "Bryn")
        #expect(profiles.first?.identity.organization == "Acme")
        #expect(profiles.first?.centroid.count == 256)
        #expect(profiles.first?.sampleCount == 1)
    }

    @Test("a profile is never compared across embedding models")
    func aProfileIsNeverComparedAcrossEmbeddingModels() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let bryn = try await store.createPerson(name: "Bryn")
        _ = try await store.enrol(VoiceEnrollmentCandidate(
            identityID: bryn.id, vector: SpeakerFixtures.vector(seed: 3), model: .fluidAudioOffline,
            speechSeconds: 90, qualityScore: 1, source: .humanConfirmedCluster,
            evidence: VoiceEvidenceFixture.evidence(meeting: "m1", seconds: 90, source: .humanConfirmedCluster)
        ))
        let other = EmbeddingModelIdentifier(rawValue: "some-future-model-512", dimension: 512)
        #expect(
            try await store.searchableProfiles(model: other).isEmpty,
            "a vector from another model must not be a candidate"
        )
    }

    @Test("recognition never writes a profile, however confident it was")
    func recognitionNeverWritesAProfileHoweverConfidentItWas() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        let bryn = try await store.createPerson(name: "Bryn")
        _ = try await store.enrol(VoiceEnrollmentCandidate(
            identityID: bryn.id, vector: SpeakerFixtures.vector(seed: 5), model: .fluidAudioOffline,
            speechSeconds: 120, qualityScore: 1, source: .humanConfirmedCluster,
            evidence: VoiceEvidenceFixture.evidence(meeting: "m1", seconds: 120, source: .humanConfirmedCluster)
        ))
        // A gallery of one has no runner-up and so no measurable
        // separation, which the policy answers with a suggestion. Two
        // voices is what a real gallery looks like.
        let other = try await store.createPerson(name: "Nadia")
        _ = try await store.enrol(VoiceEnrollmentCandidate(
            identityID: other.id, vector: SpeakerFixtures.vector(seed: 200), model: .fluidAudioOffline,
            speechSeconds: 120, qualityScore: 1, source: .humanConfirmedCluster,
            evidence: VoiceEvidenceFixture.evidence(
                meeting: "m0", seconds: 120, source: .humanConfirmedCluster
            )
        ))
        let before = try await store.profileStatus(of: bryn.id, model: .fluidAudioOffline)

        // The same voice again, matched at the highest confidence.
        let resolved = try await service.resolve(
            meetingID: "m2",
            clusters: [SpeakerClusterInput(
                clusterID: "run-001_speaker_00", track: .remote,
                speechSeconds: 300, centroid: SpeakerFixtures.vector(seed: 5),
                spans: [AudioSpan(
                    start: VoiceEvidenceFixture.lane("run-001_speaker_00"),
                    end: VoiceEvidenceFixture.lane("run-001_speaker_00") + 300
                )]
            )],
            settings: SpeakerRecognitionSettings(),
            now: Date()
        )
        #expect(resolved.first?.identity?.id == bryn.id, "the match itself should work")
        #expect(resolved.first?.source == .voiceProfile)

        let after = try await store.profileStatus(of: bryn.id, model: .fluidAudioOffline)
        #expect(
            after.sampleCount == before.sampleCount,
            "a High automatic match must never add a vector"
        )
    }

    @Test("a named profile refuses a vector nobody stood behind")
    func aNamedProfileRefusesAVectorNobodyStoodBehind() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let bryn = try await store.createPerson(name: "Bryn")
        let result = try await store.enrol(VoiceEnrollmentCandidate(
            identityID: bryn.id, vector: SpeakerFixtures.vector(seed: 6), model: .fluidAudioOffline,
            speechSeconds: 300, qualityScore: 1, source: .anonymousSeed,
            evidence: VoiceEvidenceFixture.evidence(meeting: "m1", seconds: 300, source: .anonymousSeed)
        ))
        guard case .failure = result else {
            Issue.record("a seed vector must not enter a named profile")
            return
        }
        #expect(
            try await store.profileStatus(of: bryn.id, model: .fluidAudioOffline).sampleCount == 0
        )
    }

    @Test("a correction with too little audio behind it is refused")
    func aCorrectionWithTooLittleAudioBehindItIsRefused() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let bryn = try await store.createPerson(name: "Bryn")
        let result = try await store.enrol(VoiceEnrollmentCandidate(
            identityID: bryn.id, vector: SpeakerFixtures.vector(seed: 7), model: .fluidAudioOffline,
            speechSeconds: 12, qualityScore: 1, source: .humanConfirmedCluster,
            evidence: VoiceEvidenceFixture.evidence(meeting: "m1", seconds: 12, source: .humanConfirmedCluster)
        ))
        guard case .failure(let reason) = result else {
            Issue.record("12 seconds is below the enrolment bar")
            return
        }
        #expect(reason == .tooLittleSpeech(seconds: 12, required: 45))
    }

    @Test("correcting more lines in one meeting refines it, and enrols once")
    func correctingMoreLinesInOneMeetingRefinesItAndEnrolsOnce() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let bryn = try await store.createPerson(name: "Bryn")

        // Each round re-embeds the whole confirmed set, so a later round
        // supersedes the earlier one rather than counting it again.
        for seconds in [15.0, 30.0] {
            try await store.addPendingEnrollment(VoiceEnrollmentCandidate(
                identityID: bryn.id, vector: SpeakerFixtures.vector(seed: 8), model: .fluidAudioOffline,
                speechSeconds: seconds, qualityScore: 1,
                source: .humanConfirmedUtterances,
            evidence: VoiceEvidenceFixture.evidence(meeting: "m1", seconds: seconds, source: .humanConfirmedUtterances)
        ))
        }
        let pending = try await store.pendingSpeechSeconds(for: bryn.id, model: .fluidAudioOffline)
        #expect(
            abs(pending - 30) <= 0.001,
            "expected \(30) ± \(0.001), got \(pending) — the second round replaces the first, it does not add to it"
        )
        #expect(
            !(try await store.flushPendingEnrollment(for: bryn.id, model: .fluidAudioOffline)),
            "30 seconds is not enough"
        )

        try await store.addPendingEnrollment(VoiceEnrollmentCandidate(
            identityID: bryn.id, vector: SpeakerFixtures.vector(seed: 8), model: .fluidAudioOffline,
            speechSeconds: 50, qualityScore: 1,
            source: .humanConfirmedUtterances,
            evidence: VoiceEvidenceFixture.evidence(meeting: "m1", seconds: 50, source: .humanConfirmedUtterances)
        ))
        #expect(
            try await store.flushPendingEnrollment(for: bryn.id, model: .fluidAudioOffline),
            "50 seconds clears it"
        )
        #expect(
            try await store.profileStatus(of: bryn.id, model: .fluidAudioOffline).sampleCount == 1,
            "one embedding for the meeting, not one per round"
        )
        #expect(
            try await store.hasEnrolment(
                identityID: bryn.id, meetingID: "m1",
                source: .humanConfirmedUtterances, model: .fluidAudioOffline
            ),
            "and the meeting it came from is recorded, so it is not redone"
        )
    }

    @Test("re-analysing a meeting reuses the voice it already remembered")
    func reAnalysingAMeetingReusesTheVoiceItAlreadyRemembered() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        let settings = SpeakerRecognitionSettings()
        let voice = SpeakerFixtures.vector(seed: 44)

        let first = try await service.resolve(
            meetingID: "m1",
            clusters: [SpeakerClusterInput(
                clusterID: "remote-001_speaker_00", track: .remote,
                speechSeconds: 120, centroid: voice,
                spans: [AudioSpan(
                    start: VoiceEvidenceFixture.lane("remote-001_speaker_00"),
                    end: VoiceEvidenceFixture.lane("remote-001_speaker_00") + 120
                )]
            )],
            settings: settings
        )
        #expect(first.first?.createdIdentity == true)
        // A first-time voice is remembered but not announced, so the
        // identity comes back nil and the occurrence row carries it.
        let occurrences = try await store.occurrences(meetingID: "m1")
        let created = try #require(occurrences.first { $0.clusterID == "remote-001_speaker_00" }?.resolvedIdentityID)

        // A re-analysis renumbers the run, so the same voice arrives
        // under a key nothing has seen.
        let second = try await service.resolve(
            meetingID: "m1",
            clusters: [SpeakerClusterInput(
                clusterID: "remote-002_speaker_00", track: .remote,
                speechSeconds: 120, centroid: voice,
                spans: [AudioSpan(
                    start: VoiceEvidenceFixture.lane("remote-002_speaker_00"),
                    end: VoiceEvidenceFixture.lane("remote-002_speaker_00") + 120
                )]
            )],
            settings: settings
        )
        _ = second
        let after = try await store.occurrences(meetingID: "m1")
        #expect(
            after.first { $0.clusterID == "remote-002_speaker_00" }?.resolvedIdentityID == created,
            "the same voice in the same meeting is the same unnamed person"
        )
        #expect(
            try await store.identities(kind: .anonymous).count == 1,
            "re-analysing must not leave a second profile holding one voice"
        )
        #expect(
            second.first?.createdIdentity == true,
            "and it is still a voice heard once, not one heard before"
        )
        #expect(
            second.first?.source != .anonymousVoice,
            "reuse is not the same claim as having heard this voice elsewhere"
        )
    }

    @Test("correcting a name takes the voice out of the first profile")
    func correctingANameTakesTheVoiceOutOfTheFirstProfile() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        let settings = SpeakerRecognitionSettings()
        let dave = SpeakerFixtures.vector(seed: 61)
        let cluster = SpeakerClusterInput(
            clusterID: "remote-001_speaker_00", track: .remote,
            speechSeconds: 95, centroid: dave,
            spans: [AudioSpan(
                start: VoiceEvidenceFixture.lane("remote-001_speaker_00"),
                end: VoiceEvidenceFixture.lane("remote-001_speaker_00") + 95
            )]
        )

        // Named wrongly, then corrected.
        let alice = try await store.createPerson(name: "Alice")
        _ = try await service.confirmCluster(
            meetingID: "m1", cluster: cluster, identityID: alice.id, settings: settings
        )
        #expect(
            try await store.profileStatus(
                of: alice.id, model: .fluidAudioOffline
            ).sampleCount == 1
        )

        let bob = try await store.createPerson(name: "Bob")
        _ = try await service.confirmCluster(
            meetingID: "m1", cluster: cluster, identityID: bob.id, settings: settings
        )
        #expect(
            try await store.profileStatus(
                of: alice.id, model: .fluidAudioOffline
            ).sampleCount == 0,
            "the corrected-away person keeps none of this voice"
        )
        #expect(
            try await store.profileStatus(
                of: bob.id, model: .fluidAudioOffline
            ).sampleCount == 1
        )
        #expect(
            !(try await store.searchableProfiles(model: .fluidAudioOffline)
                .contains { $0.identity.id == alice.id }),
            "and is not a candidate at all, rather than one with a stale centroid"
        )

        // Committing the same name again refines rather than stacking.
        _ = try await service.confirmCluster(
            meetingID: "m1", cluster: cluster, identityID: bob.id, settings: settings
        )
        #expect(
            try await store.profileStatus(
                of: bob.id, model: .fluidAudioOffline
            ).sampleCount == 1,
            "one recording contributes one vector, however often it is confirmed"
        )
    }

    @Test("learning off keeps your own vector and still drops the wrong one")
    func learningOffKeepsYourOwnVectorAndStillDropsTheWrongOne() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        let alice = try await store.createPerson(name: "Alice")
        let cluster = SpeakerClusterInput(
            clusterID: "remote-001_speaker_00", track: .remote,
            speechSeconds: 95, centroid: SpeakerFixtures.vector(seed: 62),
            spans: [AudioSpan(
                start: VoiceEvidenceFixture.lane("remote-001_speaker_00"),
                end: VoiceEvidenceFixture.lane("remote-001_speaker_00") + 95
            )]
        )
        _ = try await service.confirmCluster(
            meetingID: "m1", cluster: cluster, identityID: alice.id,
            settings: SpeakerRecognitionSettings()
        )

        var off = SpeakerRecognitionSettings()
        off.learnFromCorrections = false

        // Re-confirming the same person must not destroy what they have,
        // because the setting forbids rebuilding it.
        _ = try await service.confirmCluster(
            meetingID: "m1", cluster: cluster, identityID: alice.id, settings: off
        )
        #expect(
            try await store.profileStatus(
                of: alice.id, model: .fluidAudioOffline
            ).sampleCount == 1,
            "a setting that forbids learning must not delete what was learned"
        )

        // Correcting it to somebody else does drop it: the user has just
        // said this audio is not Alice, and leaving it would auto-name
        // Bob as Alice for as long as the profile lives.
        let bob = try await store.createPerson(name: "Bob")
        _ = try await service.confirmCluster(
            meetingID: "m1", cluster: cluster, identityID: bob.id, settings: off
        )
        #expect(
            try await store.profileStatus(
                of: alice.id, model: .fluidAudioOffline
            ).sampleCount == 0,
            "the person corrected away keeps none of this voice"
        )
        #expect(
            try await store.profileStatus(
                of: bob.id, model: .fluidAudioOffline
            ).sampleCount == 0,
            "and nothing is learned for the new name, which is what the setting says"
        )
    }

    @Test("enrolling a merged identity reaches the person it reads as")
    func enrollingAMergedIdentityReachesThePersonItReadsAs() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let duplicate = try await store.createPerson(name: "Marlow")
        let survivor = try await store.createPerson(name: "Marlow Fenn")
        try await store.merge(duplicate.id, into: survivor.id)

        // A caller holding the old identifier, which is what a stored
        // localUserIdentityID is after a merge.
        _ = try await store.enrol(VoiceEnrollmentCandidate(
            identityID: duplicate.id, vector: SpeakerFixtures.vector(seed: 21),
            model: .fluidAudioOffline, speechSeconds: 240, qualityScore: 1,
            source: .micTrackDeterministic,
            evidence: VoiceEvidenceFixture.evidence(meeting: "m1", seconds: 240, source: .micTrackDeterministic)
        ))

        let profiles = try await store.searchableProfiles(model: .fluidAudioOffline)
        #expect(profiles.count == 1, "the vector is searchable, not stranded")
        #expect(profiles.first?.identity.id == survivor.id)
        #expect(
            try await store.profileStatus(
                of: survivor.id, model: .fluidAudioOffline
            ).sampleCount == 1
        )
    }

    @Test("two meetings below the bar are not merged into one vector")
    func twoMeetingsBelowTheBarAreNotMergedIntoOneVector() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let bryn = try await store.createPerson(name: "Bryn")
        for meeting in ["m1", "m2"] {
            try await store.addPendingEnrollment(VoiceEnrollmentCandidate(
                identityID: bryn.id, vector: SpeakerFixtures.vector(seed: 8), model: .fluidAudioOffline,
                speechSeconds: 30, qualityScore: 1,
                source: .humanConfirmedUtterances,
            evidence: VoiceEvidenceFixture.evidence(meeting: meeting, seconds: 30, source: .humanConfirmedUtterances)
        ))
        }
        #expect(
            !(try await store.flushPendingEnrollment(for: bryn.id, model: .fluidAudioOffline)),
            "60 seconds across two sessions is not 60 seconds of one"
        )
        // Neither meeting is marked, so both keep accumulating.
        for meeting in ["m1", "m2"] {
            #expect(
                !(try await store.hasEnrolment(
                    identityID: bryn.id, meetingID: meeting,
                    source: .humanConfirmedUtterances, model: .fluidAudioOffline
                ))
            )
        }
        let pending = try await store.pendingSpeechSeconds(for: bryn.id, model: .fluidAudioOffline)
        #expect(abs(pending - 60) <= 0.001, "expected \(60) ± \(0.001), got \(pending)")
    }

    @Test("the microphone track may enrol the local user without a confirmation")
    func theMicrophoneTrackMayEnrolTheLocalUserWithoutAConfirmation() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        let me = try await store.createPerson(name: "Marlow", isLocalUser: true)
        // The far end, on its own track, which is what makes "the
        // microphone track is the local user" mean anything.
        try await store.recordOccurrence(
            meetingID: "m1", clusterID: "remote-001_speaker_00", track: .remote,
            speechSeconds: 600, embedding: SpeakerFixtures.vector(seed: 88), model: .fluidAudioOffline,
            resolution: nil, identityID: nil, source: .ai,
            humanVerified: false, wasExpectedParticipant: false
        )
        let status = try await service.learnLocalUserVoice(
            meetingID: "m1", identityID: me.id, vector: SpeakerFixtures.vector(seed: 11),
            speechSeconds: 240, quality: 1,
            spans: [AudioSpan(start: 0, end: 240)]
        )
        #expect(status?.sampleCount == 1)
        #expect(try await store.localUser()?.id == me.id)
    }

    @Test("nothing to check bleed against is a refusal, not a pass")
    func nothingToCheckBleedAgainstIsARefusalNotAPass() async throws {
        // The far end is recorded but produced no vectors: a cloud
        // diarizer with the fill-in pass switched off, or a track that
        // would not decode. Reading "nothing to compare against" as "no
        // bleed" let the microphone's dominant voice into the one profile
        // no person ever confirms or reviews. Refusing costs this
        // meeting's learning.
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        let me = try await store.createPerson(name: "Marlow", isLocalUser: true)
        let declined = try await service.learnLocalUserVoice(
            meetingID: "m1", identityID: me.id, vector: SpeakerFixtures.vector(seed: 11),
            speechSeconds: 240, quality: 1,
            spans: [AudioSpan(start: 0, end: 240)]
        )
        #expect(declined == nil)
        #expect(try await store.searchableProfiles(model: .fluidAudioOffline).isEmpty)
    }

    @Test("the microphone track refuses a voice heard on this call's other track")
    func theMicrophoneTrackRefusesAVoiceHeardOnThisCallSOtherTrack() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        let me = try await store.createPerson(name: "Marlow", isLocalUser: true)

        // The far end, already diarized on the remote track.
        let presenter = SpeakerFixtures.vector(seed: 77)
        try await store.recordOccurrence(
            meetingID: "m1", clusterID: "remote-001_speaker_00", track: .remote,
            speechSeconds: 1_800, embedding: presenter, model: .fluidAudioOffline,
            resolution: nil, identityID: nil, source: .ai,
            humanVerified: false, wasExpectedParticipant: false
        )

        // Nothing subtracts the speakers from the microphone, and the
        // user was listening, so the presenter dominates that track too.
        let declined = try await service.learnLocalUserVoice(
            meetingID: "m1", identityID: me.id, vector: presenter,
            speechSeconds: 1_800, quality: 1,
            spans: [AudioSpan(start: 0, end: 1_800)]
        )
        #expect(declined == nil, "bleed is not the person holding the microphone")
        #expect(
            try await store.searchableProfiles(model: .fluidAudioOffline).isEmpty,
            "and nothing reached the one profile no person ever confirms"
        )

        // A different voice on the same call still enrols.
        let mine = try await service.learnLocalUserVoice(
            meetingID: "m1", identityID: me.id, vector: SpeakerFixtures.vector(seed: 12),
            speechSeconds: 240, quality: 1,
            spans: [AudioSpan(start: 0, end: 240)]
        )
        #expect(mine?.sampleCount == 1)
    }

    @Test("naming a recurring voice keeps its history and its profile")
    func namingARecurringVoiceKeepsItsHistoryAndItsProfile() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let voice = try await store.createAnonymous(state: .persistent)
        _ = try await store.enrol(VoiceEnrollmentCandidate(
            identityID: voice.id, vector: SpeakerFixtures.vector(seed: 12), model: .fluidAudioOffline,
            speechSeconds: 120, qualityScore: 1, source: .anonymousSeed,
            evidence: VoiceEvidenceFixture.evidence(meeting: "m1", seconds: 120, source: .anonymousSeed)
        ))
        try await store.recordOccurrence(
            meetingID: "m1", clusterID: "run-001_speaker_00", track: .remote,
            speechSeconds: 120, embedding: SpeakerFixtures.vector(seed: 12), model: .fluidAudioOffline,
            resolution: nil, identityID: voice.id, source: .anonymousVoice,
            humanVerified: false, wasExpectedParticipant: false
        )

        let promoted = try await store.promoteToPerson(
            voice.id, name: "Talia", organization: "Acme"
        )
        let named = try #require(promoted)
        #expect(named.id == voice.id, "promotion must not change the identifier")
        #expect(named.kind == .person)
        #expect(named.resolvedName == "Talia")
        #expect(
            try await store.occurrences(identityID: voice.id).count == 1,
            "every historical occurrence still points at the same identity"
        )
        #expect(
            try await store.profileStatus(of: voice.id, model: .fluidAudioOffline).sampleCount == 1,
            "the profile the voice already built is kept"
        )
    }

    @Test("a merge redirects instead of rewriting, and can be undone")
    func aMergeRedirectsInsteadOfRewritingAndCanBeUndone() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await store.createAnonymous(state: .persistent)
        let second = try await store.createAnonymous(state: .persistent)
        for identity in [first, second] {
            _ = try await store.enrol(VoiceEnrollmentCandidate(
                identityID: identity.id, vector: SpeakerFixtures.vector(seed: 13), model: .fluidAudioOffline,
                speechSeconds: 90, qualityScore: 1, source: .anonymousSeed,
            evidence: VoiceEvidenceFixture.evidence(meeting: "m\(identity.id.rawValue)", seconds: 90, source: .anonymousSeed)
        ))
            try await store.recordOccurrence(
                meetingID: "m\(identity.id.rawValue)", clusterID: "c", track: .remote,
                speechSeconds: 90, embedding: SpeakerFixtures.vector(seed: 13), model: .fluidAudioOffline,
                resolution: nil, identityID: identity.id, source: .anonymousVoice,
                humanVerified: false, wasExpectedParticipant: false
            )
        }

        try await store.merge(second.id, into: first.id)
        #expect(
            try await store.current(second.id)?.id == first.id,
            "a read of the merged identity resolves to the survivor"
        )
        #expect(
            try await store.searchableProfiles(model: .fluidAudioOffline).count == 1,
            "one person must not occupy two ranks and eat their own margin"
        )
        #expect(
            try await store.profileStatus(of: first.id, model: .fluidAudioOffline).sampleCount == 2,
            "the survivor is scored against both sets of vectors"
        )
        #expect(try await store.meetingCount(for: first.id) == 2)

        try await store.unmerge(second.id)
        #expect(try await store.current(second.id)?.id == second.id)
        #expect(try await store.searchableProfiles(model: .fluidAudioOffline).count == 2)
    }

    @Test("forgetting a voice removes the biometric and keeps the person")
    func forgettingAVoiceRemovesTheBiometricAndKeepsThePerson() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let bryn = try await store.createPerson(name: "Bryn")
        _ = try await store.enrol(VoiceEnrollmentCandidate(
            identityID: bryn.id, vector: SpeakerFixtures.vector(seed: 14), model: .fluidAudioOffline,
            speechSeconds: 120, qualityScore: 1, source: .humanConfirmedCluster,
            evidence: VoiceEvidenceFixture.evidence(meeting: "m1", cluster: "c1", seconds: 120, source: .humanConfirmedCluster)
        ))
        try await store.recordOccurrence(
            meetingID: "m1", clusterID: "c1", track: .remote, speechSeconds: 120,
            embedding: SpeakerFixtures.vector(seed: 14), model: .fluidAudioOffline, resolution: nil,
            identityID: bryn.id, source: .human, humanVerified: true,
            wasExpectedParticipant: false
        )

        try await store.forgetVoice(of: bryn.id)
        #expect(try await store.searchableProfiles(model: .fluidAudioOffline).isEmpty)
        #expect(try await store.current(bryn.id)?.resolvedName == "Bryn")
        #expect(
            try await store.occurrences(meetingID: "m1").first?.resolvedIdentityID == bryn.id,
            "past transcripts keep the name"
        )
    }

    @Test("deleting a person takes every vector with them")
    func deletingAPersonTakesEveryVectorWithThem() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let bryn = try await store.createPerson(name: "Bryn")
        _ = try await store.enrol(VoiceEnrollmentCandidate(
            identityID: bryn.id, vector: SpeakerFixtures.vector(seed: 15), model: .fluidAudioOffline,
            speechSeconds: 120, qualityScore: 1, source: .humanConfirmedCluster,
            evidence: VoiceEvidenceFixture.evidence(meeting: "m1", seconds: 120, source: .humanConfirmedCluster)
        ))
        try await store.delete(bryn.id)
        #expect((try await store.current(bryn.id)) == nil)
        #expect(try await store.searchableProfiles(model: .fluidAudioOffline).isEmpty)
        let statistics = try await store.statistics()
        #expect(statistics.embeddings == 0, "ON DELETE CASCADE carried the vectors away")
    }

    @Test("retained embeddings are capped so the store cannot grow without bound")
    func retainedEmbeddingsAreCappedSoTheStoreCannotGrowWithoutBound() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let bryn = try await store.createPerson(name: "Bryn")
        for index in 0..<30 {
            _ = try await store.enrol(VoiceEnrollmentCandidate(
                identityID: bryn.id, vector: SpeakerFixtures.vector(seed: 200 + index),
                model: .fluidAudioOffline, speechSeconds: 60, qualityScore: 1,
                source: .humanConfirmedCluster,
            evidence: VoiceEvidenceFixture.evidence(meeting: "m\(index)", seconds: 60, source: .humanConfirmedCluster)
        ))
        }
        #expect(
            try await store.profileStatus(of: bryn.id, model: .fluidAudioOffline).sampleCount == policy.maximumEmbeddingsPerIdentity
        )
    }

    @Test("a candidate heard once expires; one heard twice does not")
    func aCandidateHeardOnceExpiresOneHeardTwiceDoesNot() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let heardOnce = try await store.createAnonymous(state: .ephemeral, now: old)
        let heardTwice = try await store.createAnonymous(state: .ephemeral, now: old)
        _ = try await store.promoteToPersistent(heardTwice.id, now: old)

        // Seeded the way the recognizer actually creates one. A
        // candidate with no vector at all is not a state production can
        // produce, and testing only that shape hid an inverted
        // predicate that made expiry a no-op forever.
        _ = try await store.enrol(VoiceEnrollmentCandidate(
            identityID: heardOnce.id, vector: SpeakerFixtures.vector(seed: 61),
            model: .fluidAudioOffline, speechSeconds: 60, qualityScore: 0.9,
            source: .anonymousSeed,
            evidence: VoiceEvidenceFixture.evidence(meeting: "m1", seconds: 60, source: .anonymousSeed)
        ), now: old)

        let removed = try await store.expireEphemeralIdentities(now: Date())
        #expect(removed == 1)
        #expect((try await store.current(heardOnce.id)) == nil)
        #expect(try await store.current(heardTwice.id)?.id == heardTwice.id)
    }

    @Test("a candidate a person confirmed is never expired")
    func aCandidateAPersonConfirmedIsNeverExpired() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let confirmed = try await store.createAnonymous(state: .ephemeral, now: old)
        _ = try await store.enrol(VoiceEnrollmentCandidate(
            identityID: confirmed.id, vector: SpeakerFixtures.vector(seed: 62),
            model: .fluidAudioOffline, speechSeconds: 90, qualityScore: 1,
            source: .humanConfirmedCluster,
            evidence: VoiceEvidenceFixture.evidence(meeting: "m1", seconds: 90, source: .humanConfirmedCluster)
        ), now: old)

        #expect(try await store.expireEphemeralIdentities(now: Date()) == 0)
        #expect(try await store.current(confirmed.id)?.id == confirmed.id)
    }

    @Test("an automatic pass never overwrites a speaker a person confirmed")
    func anAutomaticPassNeverOverwritesASpeakerAPersonConfirmed() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let bryn = try await store.createPerson(name: "Bryn")

        try await store.recordOccurrence(
            meetingID: "m1", clusterID: "run-001_speaker_02", track: .remote,
            speechSeconds: 120, embedding: SpeakerFixtures.vector(seed: 63), model: .fluidAudioOffline,
            resolution: nil, identityID: bryn.id, source: .human,
            humanVerified: true, wasExpectedParticipant: false
        )
        // The same cluster re-resolved automatically, concluding nothing.
        try await store.recordOccurrence(
            meetingID: "m1", clusterID: "run-001_speaker_02", track: .remote,
            speechSeconds: 120, embedding: SpeakerFixtures.vector(seed: 63), model: .fluidAudioOffline,
            resolution: nil, identityID: nil, source: .ai,
            humanVerified: false, wasExpectedParticipant: false
        )

        let occurrence = try #require(try await store.occurrences(meetingID: "m1").first)
        #expect(
            occurrence.resolvedIdentityID == bryn.id,
            "a later automatic pass must not clear a person's answer"
        )
        #expect(occurrence.source == .human)
        #expect(occurrence.humanVerified)
        #expect(try await store.meetingCount(for: bryn.id) == 1)
    }

    @Test("deleting a person takes the whole merged family's vectors")
    func deletingAPersonTakesTheWholeMergedFamilySVectors() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let voice = try await store.createAnonymous(state: .persistent)
        _ = try await store.enrol(VoiceEnrollmentCandidate(
            identityID: voice.id, vector: SpeakerFixtures.vector(seed: 64), model: .fluidAudioOffline,
            speechSeconds: 90, qualityScore: 1, source: .anonymousSeed,
            evidence: VoiceEvidenceFixture.evidence(meeting: "m1", seconds: 90, source: .anonymousSeed)
        ))
        let bryn = try await store.createPerson(name: "Bryn")
        _ = try await store.enrol(VoiceEnrollmentCandidate(
            identityID: bryn.id, vector: SpeakerFixtures.vector(seed: 64), model: .fluidAudioOffline,
            speechSeconds: 90, qualityScore: 1, source: .humanConfirmedCluster,
            evidence: VoiceEvidenceFixture.evidence(meeting: "m2", seconds: 90, source: .humanConfirmedCluster)
        ))
        try await store.merge(voice.id, into: bryn.id)

        try await store.delete(bryn.id)
        #expect((try await store.current(bryn.id)) == nil)
        #expect(
            (try await store.current(voice.id)) == nil,
            "the merged identity holds the same person's voice and goes with them"
        )
        #expect(
            try await store.searchableProfiles(model: .fluidAudioOffline).isEmpty,
            "deleting a person must not leave their voice matchable"
        )
        #expect(try await store.statistics().embeddings == 0)
    }

    @Test("a merged identity still resolves to itself after separating")
    func aMergedIdentityStillResolvesToItselfAfterSeparating() async throws {
        // The meeting files keep the identity they were written with, so
        // separating a merge can find them again. Rewriting the link on
        // merge left the meeting attributed to the wrong person with no
        // way back.
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let ann = try await store.createPerson(name: "Ann")
        let bob = try await store.createPerson(name: "Bob")
        try await store.recordOccurrence(
            meetingID: "m1", clusterID: "c1", track: .remote, speechSeconds: 90,
            embedding: SpeakerFixtures.vector(seed: 71), model: .fluidAudioOffline, resolution: nil,
            identityID: ann.id, source: .human, humanVerified: true,
            wasExpectedParticipant: false
        )

        try await store.merge(ann.id, into: bob.id)
        #expect(try await store.current(ann.id)?.resolvedName == "Bob")
        #expect(
            try await store.occurrences(meetingID: "m1").first?.resolvedIdentityID == ann.id,
            "the occurrence keeps the identity it was written with"
        )

        try await store.unmerge(ann.id)
        #expect(
            try await store.current(ann.id)?.resolvedName == "Ann",
            "separating restores who the meeting was about"
        )
    }

    @Test("forgetting a voice covers what was merged into it")
    func forgettingAVoiceCoversWhatWasMergedIntoIt() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let voice = try await store.createAnonymous(state: .persistent)
        _ = try await store.enrol(VoiceEnrollmentCandidate(
            identityID: voice.id, vector: SpeakerFixtures.vector(seed: 65), model: .fluidAudioOffline,
            speechSeconds: 90, qualityScore: 1, source: .anonymousSeed,
            evidence: VoiceEvidenceFixture.evidence(meeting: "m1", seconds: 90, source: .anonymousSeed)
        ))
        let bryn = try await store.createPerson(name: "Bryn")
        try await store.merge(voice.id, into: bryn.id)

        try await store.forgetVoice(of: bryn.id)
        try await store.unmerge(voice.id)
        #expect(
            try await store.searchableProfiles(model: .fluidAudioOffline).isEmpty,
            "separating a merge must not resurrect a forgotten voice"
        )
        #expect(try await store.current(bryn.id)?.resolvedName == "Bryn")
    }

    @Test("merging an unnamed voice into a person keeps the profile human-verified")
    func mergingAnUnnamedVoiceIntoAPersonKeepsTheProfileHumanVerified() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let bryn = try await store.createPerson(name: "Bryn")
        _ = try await store.enrol(VoiceEnrollmentCandidate(
            identityID: bryn.id, vector: SpeakerFixtures.vector(seed: 66), model: .fluidAudioOffline,
            speechSeconds: 90, qualityScore: 1, source: .humanConfirmedCluster,
            evidence: VoiceEvidenceFixture.evidence(meeting: "m1", seconds: 90, source: .humanConfirmedCluster)
        ))
        let voice = try await store.createAnonymous(state: .persistent)
        _ = try await store.enrol(VoiceEnrollmentCandidate(
            identityID: voice.id, vector: SpeakerFixtures.vector(seed: 900), model: .fluidAudioOffline,
            speechSeconds: 90, qualityScore: 1, source: .anonymousSeed,
            evidence: VoiceEvidenceFixture.evidence(meeting: "m2", seconds: 90, source: .anonymousSeed)
        ))

        try await store.merge(voice.id, into: bryn.id)
        #expect(
            try await store.profileStatus(of: bryn.id, model: .fluidAudioOffline).sampleCount == 1,
            "a provisional seed must not reach a named centroid through a merge"
        )
        let profile = try #require(try await store.searchableProfiles(model: .fluidAudioOffline).first { $0.identity.id == bryn.id })
        #expect(
            VoiceVector.cosine(profile.centroid, SpeakerFixtures.vector(seed: 66)) > 0.99,
            "Bryn is still scored against his own confirmed voice alone"
        )
    }
}
@Suite("SpeakerRecognition")
struct SpeakerRecognitionTests {
    @Test("a new voice with enough speech is remembered but not announced")
    func aNewVoiceWithEnoughSpeechIsRememberedButNotAnnounced() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        let resolved = try await service.resolve(
            meetingID: "m1",
            clusters: [SpeakerClusterInput(
                clusterID: "run-001_speaker_00", track: .remote,
                speechSeconds: 120, centroid: SpeakerFixtures.vector(seed: 21),
                spans: [AudioSpan(
                    start: VoiceEvidenceFixture.lane("run-001_speaker_00"),
                    end: VoiceEvidenceFixture.lane("run-001_speaker_00") + 120
                )]
            )],
            settings: SpeakerRecognitionSettings(), now: Date()
        )
        #expect(resolved.first?.createdIdentity == true)
        #expect(resolved.first?.identity == nil, "the first meeting still shows a number")
        let stored = try await store.identities(kind: .anonymous)
        #expect(stored.count == 1)
        #expect(stored.first?.state == .ephemeral)
    }

    @Test("the same voice in a second meeting becomes a recurring identity")
    func theSameVoiceInASecondMeetingBecomesARecurringIdentity() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        let cluster = SpeakerClusterInput(
            clusterID: "run-001_speaker_00", track: .remote,
            speechSeconds: 120, centroid: SpeakerFixtures.vector(seed: 22),
            spans: [AudioSpan(
                start: VoiceEvidenceFixture.lane("run-001_speaker_00"),
                end: VoiceEvidenceFixture.lane("run-001_speaker_00") + 120
            )]
        )
        // A second voice in that first meeting, so voice memory holds
        // more than one candidate. With exactly one there is no
        // runner-up, no separation to measure, and the policy correctly
        // declines to link automatically.
        let alsoThere = SpeakerClusterInput(
            clusterID: "run-001_speaker_09", track: .remote,
            speechSeconds: 120, centroid: SpeakerFixtures.vector(seed: 199),
            spans: [AudioSpan(
                start: VoiceEvidenceFixture.lane("run-001_speaker_09"),
                end: VoiceEvidenceFixture.lane("run-001_speaker_09") + 120
            )]
        )
        _ = try await service.resolve(
            meetingID: "m1", clusters: [cluster, alsoThere],
            settings: SpeakerRecognitionSettings(), now: Date()
        )
        let second = try await service.resolve(
            meetingID: "m2", clusters: [cluster],
            settings: SpeakerRecognitionSettings(), now: Date()
        )
        #expect(second.first?.source == .anonymousVoice)
        let identity = try #require(second.first?.identity)
        #expect(identity.state == .persistent)
        #expect(identity.anonymousNumber == 1)
        #expect(second.first?.meetingCount == 2)
    }

    @Test("resolving the same meeting twice does not invent a voice heard before")
    func resolvingTheSameMeetingTwiceDoesNotInventAVoiceHeardBefore() async throws {
        // The second pass would otherwise score the cluster against the
        // profile seeded from its own vector, match at 1.0, and promote
        // a voice heard exactly once into a recurring identity.
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        let cluster = SpeakerClusterInput(
            clusterID: "run-001_speaker_00", track: .remote,
            speechSeconds: 120, centroid: SpeakerFixtures.vector(seed: 51),
            spans: [AudioSpan(
                start: VoiceEvidenceFixture.lane("run-001_speaker_00"),
                end: VoiceEvidenceFixture.lane("run-001_speaker_00") + 120
            )]
        )
        _ = try await service.resolve(
            meetingID: "m1", clusters: [cluster],
            settings: SpeakerRecognitionSettings(), now: Date()
        )
        let again = try await service.resolve(
            meetingID: "m1", clusters: [cluster],
            settings: SpeakerRecognitionSettings(), now: Date()
        )
        #expect(again.first?.identity == nil, "it has still only ever been heard once")
        #expect(again.first?.source != .anonymousVoice)
        let identities = try await store.identities(kind: .anonymous)
        #expect(identities.count == 1, "and no second candidate was created")
        #expect(
            identities.first?.state == .ephemeral,
            "nothing promoted it: promotion means a second meeting"
        )
    }

    @Test("a voice the diarizer split in two is remembered once")
    func aVoiceTheDiarizerSplitInTwoIsRememberedOnce() async throws {
        // The tuned clusterer prefers splitting a speaker over merging
        // two, so this is the expected failure. Remembering it twice is
        // what makes it unrecoverable: two centroids a few hundredths
        // apart split each other's margin, so from then on that person
        // is never recognised in any meeting.
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        let voice = SpeakerFixtures.vector(seed: 52)
        let resolved = try await service.resolve(
            meetingID: "m1",
            clusters: [
                SpeakerClusterInput(
                    clusterID: "run-001_speaker_00", track: .remote,
                    speechSeconds: 120, centroid: voice,
                    spans: [AudioSpan(start: 0, end: 120)]
                ),
                SpeakerClusterInput(
                    clusterID: "run-001_speaker_01", track: .remote,
                    speechSeconds: 120, centroid: voice,
                    spans: [AudioSpan(start: 300, end: 420)]
                ),
            ],
            settings: SpeakerRecognitionSettings(), now: Date()
        )
        #expect(resolved.count == 2)
        #expect(
            resolved.allSatisfy { $0.source != .anonymousVoice },
            "neither half was heard before this meeting, so neither is announced"
        )
        #expect(
            try await store.identities(kind: .anonymous).count == 1,
            "and the two halves leave one voice behind, not two that cancel out"
        )
        let owners = try await store.occurrences(meetingID: "m1")
            .compactMap(\.resolvedIdentityID)
        #expect(owners.count == 2, "both halves are recorded")
        #expect(
            Set(owners.map(\.rawValue)).count == 1,
            "and both point at the same voice, which is what makes naming one name both"
        )
    }

    @Test("a voice heard before is linked to one of two overlapping clusters")
    func aVoiceHeardBeforeIsLinkedToOneOfTwoOverlappingClusters() async throws {
        // The concurrency guard on the anonymous branch: two clusters
        // that talk over each other cannot both be the person voice
        // memory recognises, however alike they score.
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        let voice = SpeakerFixtures.vector(seed: 54)
        let remembered = try await store.createAnonymous(state: .persistent)
        _ = try await store.enrol(VoiceEnrollmentCandidate(
            identityID: remembered.id, vector: voice, model: .fluidAudioOffline,
            speechSeconds: 120, qualityScore: 1, source: .anonymousSeed,
            evidence: VoiceEvidenceFixture.evidence(
                meeting: "m0", seconds: 120, source: .anonymousSeed
            )
        ))
        let other = try await store.createAnonymous(state: .persistent)
        _ = try await store.enrol(VoiceEnrollmentCandidate(
            identityID: other.id, vector: SpeakerFixtures.vector(seed: 201), model: .fluidAudioOffline,
            speechSeconds: 120, qualityScore: 1, source: .anonymousSeed,
            evidence: VoiceEvidenceFixture.evidence(
                meeting: "m0b", seconds: 120, source: .anonymousSeed
            )
        ))

        let resolved = try await service.resolve(
            meetingID: "m1",
            clusters: [
                SpeakerClusterInput(
                    clusterID: "run-001_speaker_00", track: .remote,
                    speechSeconds: 120, centroid: voice,
                    spans: [AudioSpan(start: 0, end: 120)]
                ),
                SpeakerClusterInput(
                    clusterID: "run-001_speaker_01", track: .remote,
                    speechSeconds: 120, centroid: voice,
                    spans: [AudioSpan(start: 60, end: 180)]
                ),
            ],
            settings: SpeakerRecognitionSettings(), now: Date()
        )
        #expect(
            resolved.filter { $0.source == .anonymousVoice }.count == 1,
            "the first cluster is that voice; the second is somebody talking over them"
        )
    }

    @Test("two clusters talking over each other stay two voices")
    func twoClustersTalkingOverEachOtherStayTwoVoices() async throws {
        // One person is not two people at once, whatever they score.
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        let voice = SpeakerFixtures.vector(seed: 52)
        _ = try await service.resolve(
            meetingID: "m1",
            clusters: [
                SpeakerClusterInput(
                    clusterID: "run-001_speaker_00", track: .remote,
                    speechSeconds: 120, centroid: voice,
                    spans: [AudioSpan(start: 0, end: 120)]
                ),
                SpeakerClusterInput(
                    clusterID: "run-001_speaker_01", track: .remote,
                    speechSeconds: 120, centroid: voice,
                    spans: [AudioSpan(start: 60, end: 180)]
                ),
            ],
            settings: SpeakerRecognitionSettings(), now: Date()
        )
        #expect(
            try await store.identities(kind: .anonymous).count == 2,
            "an hour of overlap is two people, however alike the audio scores"
        )
    }

    @Test("an ambiguous split is remembered as nothing rather than as two")
    func anAmbiguousSplitIsRememberedAsNothingRatherThanAsTwo() async throws {
        // Between the two bars: too close to be certainly somebody else,
        // too far to be certainly the same. Seeding a second profile here
        // is the case that poisons voice memory, and the cost of
        // abstaining is one meeting's worth of learning.
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        let first = SpeakerFixtures.vector(seed: 52)
        let near = SpeakerFixtures.blended(first, with: SpeakerFixtures.vector(seed: 53), towards: 0.52)
        let score = VoiceVector.cosine(first, near)
        #expect(
            score > policy.anonymousSuggestScore && score < policy.anonymousLinkScore,
            "the fixture has to sit between the bars, and scores \(score)"
        )
        _ = try await service.resolve(
            meetingID: "m1",
            clusters: [
                SpeakerClusterInput(
                    clusterID: "run-001_speaker_00", track: .remote,
                    speechSeconds: 120, centroid: first,
                    spans: [AudioSpan(start: 0, end: 120)]
                ),
                SpeakerClusterInput(
                    clusterID: "run-001_speaker_01", track: .remote,
                    speechSeconds: 120, centroid: near,
                    spans: [AudioSpan(start: 300, end: 420)]
                ),
            ],
            settings: SpeakerRecognitionSettings(), now: Date()
        )
        #expect(
            try await store.identities(kind: .anonymous).count == 1,
            "the ambiguous half leaves nothing behind rather than a rival profile"
        )
    }

    @Test("a voice heard in a second meeting is still recognized")
    func aVoiceHeardInASecondMeetingIsStillRecognized() async throws {
        // The guard above must not cost the feature it protects.
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        let cluster = SpeakerClusterInput(
            clusterID: "run-001_speaker_00", track: .remote,
            speechSeconds: 120, centroid: SpeakerFixtures.vector(seed: 53),
            spans: [AudioSpan(
                start: VoiceEvidenceFixture.lane("run-001_speaker_00"),
                end: VoiceEvidenceFixture.lane("run-001_speaker_00") + 120
            )]
        )
        // A second voice in that first meeting, so voice memory holds
        // more than one candidate. With exactly one there is no
        // runner-up, no separation to measure, and the policy correctly
        // declines to link automatically.
        let alsoThere = SpeakerClusterInput(
            clusterID: "run-001_speaker_09", track: .remote,
            speechSeconds: 120, centroid: SpeakerFixtures.vector(seed: 199),
            spans: [AudioSpan(
                start: VoiceEvidenceFixture.lane("run-001_speaker_09"),
                end: VoiceEvidenceFixture.lane("run-001_speaker_09") + 120
            )]
        )
        _ = try await service.resolve(
            meetingID: "m1", clusters: [cluster, alsoThere],
            settings: SpeakerRecognitionSettings(), now: Date()
        )
        let second = try await service.resolve(
            meetingID: "m2", clusters: [cluster],
            settings: SpeakerRecognitionSettings(), now: Date()
        )
        #expect(second.first?.source == .anonymousVoice)
        #expect(second.first?.identity?.state == .persistent)
    }

    @Test("a brief interjection leaves nothing behind")
    func aBriefInterjectionLeavesNothingBehind() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        _ = try await service.resolve(
            meetingID: "m1",
            clusters: [SpeakerClusterInput(
                clusterID: "run-001_speaker_04", track: .remote,
                speechSeconds: 6, centroid: SpeakerFixtures.vector(seed: 23),
                spans: [AudioSpan(
                    start: VoiceEvidenceFixture.lane("run-001_speaker_04"),
                    end: VoiceEvidenceFixture.lane("run-001_speaker_04") + 6
                )]
            )],
            settings: SpeakerRecognitionSettings(), now: Date()
        )
        #expect(
            try await store.identities(kind: .anonymous).isEmpty,
            "six seconds of speech is not an identity"
        )
    }

    @Test("switching recurring voices off leaves no unnamed identities")
    func switchingRecurringVoicesOffLeavesNoUnnamedIdentities() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        _ = try await service.resolve(
            meetingID: "m1",
            clusters: [SpeakerClusterInput(
                clusterID: "run-001_speaker_00", track: .remote,
                speechSeconds: 300, centroid: SpeakerFixtures.vector(seed: 24),
                spans: [AudioSpan(
                    start: VoiceEvidenceFixture.lane("run-001_speaker_00"),
                    end: VoiceEvidenceFixture.lane("run-001_speaker_00") + 300
                )]
            )],
            settings: SpeakerRecognitionSettings(rememberRecurringVoices: false),
            now: Date()
        )
        #expect(try await store.identities(kind: .anonymous).isEmpty)
    }

    @Test("confirming a cluster names it and builds the profile")
    func confirmingAClusterNamesItAndBuildsTheProfile() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        let bryn = try await store.createPerson(name: "Bryn")
        let status = try await service.confirmCluster(
            meetingID: "m1",
            cluster: SpeakerClusterInput(
                clusterID: "run-001_speaker_01", track: .remote,
                speechSeconds: 95, centroid: SpeakerFixtures.vector(seed: 25),
                spans: [AudioSpan(
                    start: VoiceEvidenceFixture.lane("run-001_speaker_01"),
                    end: VoiceEvidenceFixture.lane("run-001_speaker_01") + 95
                )]
            ),
            identityID: bryn.id,
            settings: SpeakerRecognitionSettings()
        )
        #expect(status.sampleCount == 1)
        let recorded = try await store.occurrences(meetingID: "m1").first
        let occurrence = try #require(recorded)
        #expect(occurrence.humanVerified)
        #expect(occurrence.source == .human)
    }

    @Test("one meeting contributes one enrolment, however many lines are corrected")
    func oneMeetingContributesOneEnrolmentHoweverManyLinesAreCorrecte() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let bryn = try await store.createPerson(name: "Bryn")
        let model = EmbeddingModelIdentifier.fluidAudioOffline
        #expect(
            !(try await store.hasEnrolment(
                identityID: bryn.id, meetingID: "m1",
                source: .humanConfirmedUtterances, model: model
            ))
        )

        _ = try await store.enrol(VoiceEnrollmentCandidate(
            identityID: bryn.id, vector: SpeakerFixtures.vector(seed: 72), model: model,
            speechSeconds: 60, qualityScore: 0.5,
            source: .humanConfirmedUtterances,
            evidence: VoiceEvidenceFixture.evidence(meeting: "m1", seconds: 60, source: .humanConfirmedUtterances)
        ))
        #expect(
            try await store.hasEnrolment(
                identityID: bryn.id, meetingID: "m1",
                source: .humanConfirmedUtterances, model: model
            )
        )
        #expect(
            !(try await store.hasEnrolment(
                identityID: bryn.id, meetingID: "m2",
                source: .humanConfirmedUtterances, model: model
            )),
            "a different meeting is still fresh material"
        )
    }

    @Test("learning from corrections can be switched off entirely")
    func learningFromCorrectionsCanBeSwitchedOffEntirely() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerRecognitionService(store: store)
        let bryn = try await store.createPerson(name: "Bryn")
        let status = try await service.confirmCluster(
            meetingID: "m1",
            cluster: SpeakerClusterInput(
                clusterID: "c", track: .remote, speechSeconds: 300, centroid: SpeakerFixtures.vector(seed: 26),
                spans: [AudioSpan(
                    start: VoiceEvidenceFixture.lane("c"),
                    end: VoiceEvidenceFixture.lane("c") + 300
                )]
            ),
            identityID: bryn.id,
            settings: SpeakerRecognitionSettings(learnFromCorrections: false)
        )
        #expect(status.sampleCount == 0, "the name is applied, the voice is not learned")
        #expect(try await store.occurrences(meetingID: "m1").first?.resolvedIdentityID == bryn.id)
    }
}
@Suite("IdentityHandles")
struct IdentityHandlesTests {
    @Test("a handle names its person and follows a merge")
    func aHandleNamesItsPersonAndFollowsAMerge() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let bryn = try await store.createPerson(name: "Bryn")
        try await store.setHandle(
            IdentityHandle(provider: "slack", handle: "U0CHRIS"), to: bryn.id
        )
        #expect(await store.identity(handle: "U0CHRIS", provider: "slack")?.id == bryn.id)
        // The saved Bryn and the huddle Bryn turn out to be one
        // person. The handle keeps working, resolved to the survivor.
        let saved = try await store.createPerson(name: "Bryn Tolliver")
        try await store.merge(bryn.id, into: saved.id)
        #expect(await store.identity(handle: "U0CHRIS", provider: "slack")?.id == saved.id)
    }

    @Test("re-confirming a handle moves it to the newer person")
    func reConfirmingAHandleMovesItToTheNewerPerson() async throws {
        // A handle can only be one person, and the newest confirmation
        // is the correction of whatever the older one claimed.
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrong = try await store.createPerson(name: "Ada")
        let right = try await store.createPerson(name: "Grace")
        try await store.setHandle(
            IdentityHandle(provider: "slack", handle: "U1"), to: wrong.id
        )
        try await store.setHandle(
            IdentityHandle(provider: "slack", handle: "U1"), to: right.id
        )
        #expect(await store.identity(handle: "U1", provider: "slack")?.id == right.id)
    }

    @Test("unlinking removes the claim and nothing else")
    func unlinkingRemovesTheClaimAndNothingElse() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let person = try await store.createPerson(name: "Ada")
        let handle = IdentityHandle(provider: "slack", handle: "U1")
        try await store.setHandle(handle, to: person.id)
        try await store.removeHandle(handle)
        #expect((await store.identity(handle: "U1", provider: "slack")) == nil)
        #expect(try await store.current(person.id)?.id == person.id, "the person stays")
    }

    @Test("the People pane sees the handles a merge carried in")
    func thePeoplePaneSeesTheHandlesAMergeCarriedIn() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await store.createPerson(name: "Bryn")
        let target = try await store.createPerson(name: "Bryn Tolliver")
        try await store.setHandle(
            IdentityHandle(provider: "slack", handle: "U0CHRIS"), to: source.id
        )
        try await store.merge(source.id, into: target.id)
        let listed = try await store.handles(of: target.id)
        #expect(listed == [IdentityHandle(provider: "slack", handle: "U0CHRIS")])

        // Merges chain, and a handle two hops deep still names this
        // person, so it has to be visible where it can be withdrawn.
        let survivor = try await store.createPerson(name: "Christopher")
        try await store.merge(target.id, into: survivor.id)
        #expect(
            try await store.handles(of: survivor.id) == [IdentityHandle(provider: "slack", handle: "U0CHRIS")]
        )
    }

    @Test("a provider and handle are namespaced apart")
    func aProviderAndHandleAreNamespacedApart() async throws {
        // Two platforms can hand out the same string. One binding per
        // platform, not one per string.
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let ada = try await store.createPerson(name: "Ada")
        let grace = try await store.createPerson(name: "Grace")
        try await store.setHandle(
            IdentityHandle(provider: "slack", handle: "shared"), to: ada.id
        )
        try await store.setHandle(
            IdentityHandle(provider: "other", handle: "shared"), to: grace.id
        )
        #expect(await store.identity(handle: "shared", provider: "slack")?.id == ada.id)
        #expect(await store.identity(handle: "shared", provider: "other")?.id == grace.id)
    }
}
