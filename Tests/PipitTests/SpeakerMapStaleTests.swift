import PipitCore
import Testing

/// Which entries of a speaker map go when a new diarization no longer has
/// their cluster key.
@Suite("SpeakerMapStale")
struct SpeakerMapStaleTests {
    private static let stale = "remote-001_speaker_00"
    private static let live = "remote-002_speaker_00"
    private static let liveKeys: Set<String> = [live, SpeakerLabel.localUser]

    @Test("an automatic entry on a key the new run no longer has is dropped")
    func anAutomaticEntryOnAStaleKeyIsDropped() {
        var map = SpeakerMap(entries: [
            Self.stale: SpeakerAssignment(displayName: "Old Guess", origin: .voiceProfile)
        ])
        #expect(map.dropEntriesForVanishedClusters(keeping: Self.liveKeys) == 1)
        #expect(map.entries.isEmpty)
    }

    @Test("an automatic entry on a live key is kept")
    func aLiveAutomaticEntryIsKept() {
        var map = SpeakerMap(entries: [
            Self.live: SpeakerAssignment(displayName: "Kept Guess", origin: .voiceProfile)
        ])
        #expect(map.dropEntriesForVanishedClusters(keeping: Self.liveKeys) == 0)
        #expect(map.entries[Self.live]?.displayName == "Kept Guess")
    }

    @Test("sensor entries and the microphone entry are not cluster keys and stay")
    func sensorAndDeterministicEntriesStay() {
        var map = SpeakerMap(entries: [
            "sensor_person_1": SpeakerAssignment(displayName: "Sensor Person", origin: .sensor),
            SpeakerLabel.localUser: SpeakerAssignment(displayName: "Local Person", origin: .deterministic),
        ])
        #expect(map.dropEntriesForVanishedClusters(keeping: []) == 0)
        #expect(map.entries.count == 2)
    }

    @Test("a name a person set with no identity is kept when nobody else carries it")
    func aHumanNameWithNoIdentityIsKept() {
        var map = SpeakerMap(entries: [
            Self.stale: SpeakerAssignment(displayName: "Typed Name", origin: .human)
        ])
        #expect(map.dropEntriesForVanishedClusters(keeping: Self.liveKeys) == 0)
        #expect(map.entries[Self.stale]?.displayName == "Typed Name")
    }

    @Test("a name with no identity is dropped once a live person-set entry has the same name")
    func aHumanNameCarriedByDisplayNameIsDropped() {
        var map = SpeakerMap(entries: [
            Self.stale: SpeakerAssignment(displayName: "Typed Name", origin: .human),
            Self.live: SpeakerAssignment(displayName: "typed name", origin: .human),
        ])
        #expect(map.dropEntriesForVanishedClusters(keeping: Self.liveKeys) == 1)
        #expect(map.entries[Self.stale] == nil)
        #expect(map.entries[Self.live] != nil)
    }

    @Test("a person-set name is dropped when the same identity is named on a live key by a person")
    func aHumanNameCarriedByIdentityIsDropped() {
        let id = IdentityID(1)
        var map = SpeakerMap(entries: [
            Self.stale: SpeakerAssignment(displayName: "Typed Name", origin: .human, identityID: id),
            Self.live: SpeakerAssignment(displayName: "Typed Name", origin: .human, identityID: id),
        ])
        #expect(map.dropEntriesForVanishedClusters(keeping: Self.liveKeys) == 1)
    }

    @Test("a person-set name is dropped when a live key holds a confident recognition of the same identity")
    func aConfidentRecognitionCarriesAHumanName() {
        let id = IdentityID(1)
        var map = SpeakerMap(entries: [
            Self.stale: SpeakerAssignment(displayName: "Typed Name", origin: .human, identityID: id),
            Self.live: SpeakerAssignment(displayName: "Typed Name", origin: .voiceProfile, identityID: id),
        ])
        #expect(map.dropEntriesForVanishedClusters(keeping: Self.liveKeys) == 1)
    }

    @Test("a person-set name is kept when only a weak guess on a live key shares its identity")
    func aWeakGuessDoesNotCarryAHumanName() {
        let id = IdentityID(1)
        var map = SpeakerMap(entries: [
            Self.stale: SpeakerAssignment(displayName: "Typed Name", origin: .human, identityID: id),
            Self.live: SpeakerAssignment(displayName: "Typed Name", origin: .anonymousVoice, identityID: id),
        ])
        #expect(map.dropEntriesForVanishedClusters(keeping: Self.liveKeys) == 0)
        #expect(map.entries[Self.stale] != nil)
    }
}
