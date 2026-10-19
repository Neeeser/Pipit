import Foundation
import PipitCore
import PipitServices
import PipitSpeakers
import Testing

// How a name the meeting client rendered meets a voice the people list knows.
//
// The client names whoever held the floor, in the form the account was created
// with. The voice names a person from the list, in the form a human typed. A
// confident voice outranks a client name that names somebody else, a client
// name that is another spelling of the voice's person is recorded as an alias,
// and a client name with no voice behind it still names the speaker.

/// One recorded call, a people list, and the pipeline that reads them.
private struct Call {
    let root: URL
    let storeRoot: URL
    let store: SpeakerStore
    let me: Identity
    let dara: Identity
    let meeting: (metadata: MeetingMetadata, store: MeetingStore, repository: MeetingRepository)

    /// The voice of the stored person "Dara K".
    static let daraVoice = 92
    /// A voice nobody has enrolled.
    static let strangerVoice = 7

    init(
        platformName: String, voice: Int, localAliases: [String] = [],
        store existing: (SpeakerStore, URL)? = nil
    ) async throws {
        root = try TestPaths.makeTemporaryDirectory()
        let (store, storeRoot) = try existing ?? SpeakerFixtures.makeStore()
        self.store = store
        self.storeRoot = storeRoot
        let people = try await store.identities(kind: .person)
        if let known = people.first(where: \.isLocalUser) {
            me = known
            dara = try #require(people.first { $0.displayName == "Dara K" })
        } else {
            me = try await store.createPerson(
                name: "Marlow", aliases: localAliases, isLocalUser: true)
            dara = try await store.createPerson(name: "Dara K")
            // Two people in the bank, because a match is only high when it
            // clears a margin over the runner-up.
            for (person, seed) in [(me, 41), (dara, Self.daraVoice)] {
                _ = try await store.enrol(
                    VoiceEnrollmentCandidate(
                        identityID: person.id,
                        vector: SpeakerFixtures.vector(seed: seed),
                        model: .fluidAudioOffline, speechSeconds: 60, qualityScore: 1,
                        source: .humanConfirmedUtterances,
                        evidence: VoiceEvidenceFixture.evidence(
                            meeting: "m0", seconds: 60, source: .humanConfirmedUtterances,
                            start: Double(seed) * 100
                        )
                    ))
            }
        }
        meeting = try PipelineFixtures.makeRecordedMeeting(root: root, seconds: 60)
        // The recording is two tones, and cancelling one from the other is
        // not what is under test.
        _ = try meeting.store.updateMetadata { $0.cleaningOutcome = .bypassedNoEchoPath }
        // The far end carries signal and the microphone holds no speech, so
        // the recording names nobody as the local user by itself.
        try meeting.store.writeSpeechEvidence(
            SpeechEvidence(
                levelWindowSeconds: 0.25, speechWindowSeconds: 0.25,
                micLevels: [Int8](repeating: -60, count: 240),
                remoteLevels: [Int8](repeating: -18, count: 240),
                micSpeech: [Int8](repeating: 0, count: 240),
                detector: "silero"
            ))
        // The client lit one tile for the whole stretch somebody else spoke,
        // and that tile reads `platformName`. Nobody is marked as the user.
        try meeting.store.writeRawSensors(
            RawSensors(
                source: "google-meet",
                participants: [SensorParticipant(id: "d1", displayName: platformName)],
                turns: [SensorTurn(start: 0, end: 50, participantID: "d1")]
            ))
        let words = (0..<50).map {
            RawTranscriptWord(start: Double($0), end: Double($0) + 0.5, text: " word")
        }
        var settings = AppSettings()
        settings.enrichment = EnrichmentSettings(
            generateTitle: false, generateDescription: false, generateNotes: false,
            generateSummary: false, suggestSpeakers: false
        )
        settings.localUserName = "Marlow"
        settings.processing.localUserIdentityID = me.id
        let pipeline = PipelineFixtures.makePipeline(
            repository: meeting.repository, backend: FakeAIBackend(),
            transcriber: StubLocalTranscriber(segments: [
                RawTranscriptSegment(
                    start: 0, end: 50, text: words.map(\.text).joined(), speaker: nil,
                    words: words
                )
            ]),
            diarizer: StubLocalDiarizer(
                intervals: [DiarizationInterval(start: 0, end: 50, clusterID: "S1")],
                chunkEmbeddings: [
                    DiarizationChunkEmbedding(
                        clusterID: "S1", start: 0, end: 50,
                        vector: SpeakerFixtures.vector(seed: voice)
                    )
                ]
            ),
            speakers: SpeakerRecognitionService(store: store),
            settings: settings, scratchRoot: root.appendingPathComponent("scratch")
        )
        await pipeline.process(meetingID: meeting.metadata.id)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeRoot)
    }

    /// What the speaker map calls each key the far end's lines are filed under.
    func farEndNames() throws -> Set<String> {
        let map = try meeting.store.readSpeakerMap()
        let keys = try meeting.store.readTranscriptSpeakers()
            .map(\.key).filter { $0 != SpeakerLabel.localUser }
        return Set(keys.compactMap { map.entries[$0]?.displayName })
    }

    var markdown: String { meeting.store.readTranscriptMarkdown() ?? "" }
}

@Suite("PlatformNames")
struct PlatformNameTests {
    @Test("a confident voice outranks the local user's own name on the far end")
    func aConfidentVoiceOutranksTheLocalUserSOwnNameOnTheFarEnd() async throws {
        // A Meet call where the page marked nobody as the user and the tile
        // reading their full name held the floor while a colleague talked.
        // The far end cannot hold the local user, and the voice was a known
        // colleague's.
        let call = try await Call(platformName: "Marlow Fenn", voice: Call.daraVoice)
        defer { call.cleanUp() }

        #expect(try call.farEndNames() == ["Dara K"])
        #expect(call.markdown.contains("Dara K"))
        #expect(!call.markdown.contains("Marlow Fenn"))
        #expect(!call.markdown.contains("**Marlow**"), "and not under the short name either")
    }

    @Test("the user's own name, stored as an alias, never names the far end")
    func theUserSOwnNameStoredAsAnAliasNeverNamesTheFarEnd() async throws {
        let call = try await Call(
            platformName: "Marlow Fenn", voice: Call.daraVoice, localAliases: ["Marlow Fenn"]
        )
        defer { call.cleanUp() }

        #expect(try call.farEndNames() == ["Dara K"])
        let map = try call.meeting.store.readSpeakerMap()
        #expect(
            !map.entries.keys.contains(SpeakerLabel.sensor(participantID: "d1")),
            "the tile is the user's own, so it holds no words of its own"
        )
    }

    @Test("a far-end voice nobody knows is not the user whose alias the tile reads")
    func aFarEndVoiceNobodyKnowsIsNotTheUser() async throws {
        let call = try await Call(
            platformName: "Marlow Fenn", voice: Call.strangerVoice, localAliases: ["Marlow Fenn"]
        )
        defer { call.cleanUp() }

        #expect(try call.farEndNames().isDisjoint(with: ["Marlow", "Marlow Fenn"]))
        #expect(!call.markdown.contains("Marlow Fenn"))
    }

    @Test("a platform name with no voice match still names the speaker")
    func aPlatformNameWithNoVoiceMatchStillNamesTheSpeaker() async throws {
        let call = try await Call(platformName: "Lucan Ward", voice: Call.strangerVoice)
        defer { call.cleanUp() }

        #expect(try call.farEndNames() == ["Lucan Ward"])
        #expect(call.markdown.contains("Lucan Ward"))
        let aliases = try await call.store.current(call.dara.id)?.aliases ?? []
        #expect(aliases.isEmpty, "a name nobody vouched for is not recorded against anyone")
    }

    @Test("an agreeing platform name becomes an alias and the stored name is shown")
    func anAgreeingPlatformNameBecomesAnAliasAndTheStoredNameIsShown() async throws {
        let call = try await Call(platformName: "Dara Kestrel", voice: Call.daraVoice)
        defer { call.cleanUp() }

        #expect(try call.farEndNames() == ["Dara K"])
        #expect(call.markdown.contains("Dara K"))
        #expect(!call.markdown.contains("Dara Kestrel"))
        let person = try #require(await call.store.current(call.dara.id))
        #expect(person.aliases == ["Dara Kestrel"])
        let people = try await call.store.identities(kind: .person)
        #expect(people.count == 2, "no third person was made from the platform name")
    }

    @Test("a platform name that is a stored alias names that person without a voice")
    func aPlatformNameThatIsAStoredAliasNamesThatPersonWithoutAVoice() async throws {
        let first = try await Call(platformName: "Dara Kestrel", voice: Call.daraVoice)
        defer { first.cleanUp() }
        // The next meeting, with a voice the bank cannot place, on the same
        // store.
        let second = try await Call(
            platformName: "dara kestrel", voice: Call.strangerVoice,
            store: (first.store, first.storeRoot)
        )
        defer { try? FileManager.default.removeItem(at: second.root) }

        #expect(try second.farEndNames() == ["Dara K"])
        let map = try second.meeting.store.readSpeakerMap()
        let entry = try #require(map.entries[SpeakerLabel.sensor(participantID: "d1")])
        #expect(entry.identityID == first.dara.id)
        let people = try await second.store.identities(kind: .person)
        #expect(people.count == 2)
    }
}

@Suite("PlatformNameReconciliation")
struct PlatformNameReconciliationTests {
    private let dara = KnownPerson(id: IdentityID(2), name: "Dara K")
    private let marlow = KnownPerson(id: IdentityID(1), name: "Marlow", aliases: ["Marlow F"])

    private func platformEntry(_ name: String, participant: String) -> SpeakerAssignment {
        SpeakerAssignment(
            displayName: name, origin: .sensor, participantID: participant,
            provenance: SpeakerProvenance(source: .sensor)
        )
    }

    private func voice(_ person: KnownPerson, cluster: String, seconds: Double = 40) -> VoiceMatch {
        VoiceMatch(
            clusterKey: cluster, person: person, confidence: 0.96, speechSeconds: seconds,
            provenance: SpeakerProvenance(
                source: .voiceProfile, identityID: person.id, score: 0.96, band: .high
            )
        )
    }

    @Test("names compare without case, diacritics or spacing")
    func namesCompareWithoutCaseDiacriticsOrSpacing() {
        #expect(PersonName.isSame("Zoë  Marsh", "zoe marsh"))
        #expect(!PersonName.isSame("Zoe Marsh", "Zoe Marshall"))
        #expect(!PersonName.isSame("", ""))
        #expect(PersonName.isCompatible(platform: "Dara Kestrel", stored: "Dara K"))
        #expect(PersonName.isCompatible(platform: "Dara Kestrel", stored: "Dara"))
        #expect(!PersonName.isCompatible(platform: "Dara Kestrel", stored: "Dara M"))
        #expect(!PersonName.isCompatible(platform: "Marlow Fenn", stored: "Dara K"))
    }

    @Test("a name that is somebody else's gives the speaker to the voice")
    func aNameThatIsSomebodyElseSGivesTheSpeakerToTheVoice() {
        var map = SpeakerMap(entries: [
            "c1": platformEntry("Marlow Fenn", participant: "d1"),
            SpeakerLabel.sensor(participantID: "d1"): platformEntry("Marlow Fenn", participant: "d1"),
        ])
        let aliases = map.reconcilePlatformNames(
            with: [voice(dara, cluster: "c1")], among: [marlow, dara]
        )
        #expect(aliases.isEmpty)
        for key in ["c1", SpeakerLabel.sensor(participantID: "d1")] {
            #expect(map.entries[key]?.displayName == "Dara K")
            #expect(map.entries[key]?.identityID == dara.id)
            #expect(map.entries[key]?.origin == .voiceProfile)
        }
    }

    @Test("two voices behind one account leave the account's own key alone")
    func twoVoicesBehindOneAccountLeaveTheAccountSOwnKeyAlone() {
        let sensorKey = SpeakerLabel.sensor(participantID: "d1")
        var map = SpeakerMap(entries: [
            "c1": platformEntry("Lucan Ward", participant: "d1"),
            "c2": platformEntry("Lucan Ward", participant: "d1"),
            sensorKey: platformEntry("Lucan Ward", participant: "d1"),
        ])
        _ = map.reconcilePlatformNames(
            with: [voice(dara, cluster: "c1"), voice(marlow, cluster: "c2")],
            among: [marlow, dara]
        )
        #expect(map.entries["c1"]?.displayName == "Dara K")
        #expect(map.entries["c2"]?.displayName == "Marlow")
        #expect(map.entries[sensorKey]?.displayName == "Lucan Ward")
    }

    @Test("a name a person set, or confirmed, is not reconciled")
    func aNameAPersonSetOrConfirmedIsNotReconciled() {
        var confirmed = platformEntry("Lucan Ward", participant: "d1")
        confirmed.provenance = SpeakerProvenance(source: .sensor, humanVerified: true)
        var map = SpeakerMap(entries: [
            "c1": confirmed,
            "c2": SpeakerAssignment(displayName: "Lucan Ward", origin: .human),
        ])
        _ = map.reconcilePlatformNames(
            with: [voice(dara, cluster: "c1"), voice(dara, cluster: "c2")], among: [dara]
        )
        #expect(map.entries["c1"]?.displayName == "Lucan Ward")
        #expect(map.entries["c2"]?.displayName == "Lucan Ward")
    }

    @Test("a name two people answer to is left to a voice or a person")
    func aNameTwoPeopleAnswerToIsLeftToAVoiceOrAPerson() {
        let other = KnownPerson(id: IdentityID(3), name: "Dara Kestrel")
        var map = SpeakerMap(entries: ["c1": platformEntry("Dara Kestrel", participant: "d1")])
        let aliases = map.reconcilePlatformNames(
            with: [voice(dara, cluster: "c1")], among: [dara, other]
        )
        #expect(aliases.isEmpty, "Dara Kestrel is somebody else's name, so it is not an alias")
        #expect(map.entries["c1"]?.displayName == "Dara K")
        #expect(map.entries["c1"]?.origin == .voiceProfile)

        var ambiguous = SpeakerMap(entries: ["c2": platformEntry("Pat", participant: "d2")])
        let twins = [
            KnownPerson(id: IdentityID(4), name: "Pat"),
            KnownPerson(id: IdentityID(5), name: "Pat", aliases: []),
        ]
        #expect(ambiguous.linkPlatformNames(to: twins) == 0)
        #expect(ambiguous.entries["c2"]?.identityID == nil)
    }
}
