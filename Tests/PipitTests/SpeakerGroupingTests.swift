import Foundation
import PipitCore
import Testing

/// One person, one row.
///
/// The diarizer splits a voice across several clusters and the meeting client
/// names each piece from its roster, so the same person arrives as four or five
/// keys carrying one name and one participant identifier. Everything here is
/// about collapsing those back to the person, and about the cases where two keys
/// are not evidence of one person and must stay apart.
@Suite("SpeakerGrouping")
struct SpeakerGroupingTests {
    private static func member(
        _ key: String, _ name: String? = nil, identity: Int64? = nil, participant: String? = nil
    ) -> SpeakerGroupMember {
        SpeakerGroupMember(
            key: key, displayName: name,
            identityID: identity.map { IdentityID($0) }, participantID: participant
        )
    }

    private static func keys(_ groups: [[SpeakerGroupMember]]) -> [[String]] {
        groups.map { $0.map(\.key) }
    }

    @Test("clusters the meeting client named for one account are one person")
    func clustersTheMeetingClientNamedForOneAccountAreOnePerson() async throws {
        let groups = SpeakerGrouping.groups([
            Self.member("remote-001_speaker_00", "Bryn Callister", participant: "U06"),
            Self.member("remote-001_speaker_01", "Bryn Callister", participant: "U06"),
            Self.member("remote-001_speaker_02", "Bryn Callister", participant: "U06"),
            Self.member("sensor_U06", "Bryn Callister", participant: "U06"),
        ])
        #expect(Self.keys(groups) == [[
            "remote-001_speaker_00", "remote-001_speaker_01",
            "remote-001_speaker_02", "sensor_U06",
        ]])
    }

    @Test("two accounts in one meeting stay two people")
    func twoAccountsInOneMeetingStayTwoPeople() async throws {
        let groups = SpeakerGrouping.groups([
            Self.member("remote-001_speaker_00", "Rowan Ashby", participant: "U0B"),
            Self.member("remote-001_speaker_01", "Bryn Callister", participant: "U06"),
            Self.member("remote-001_speaker_02", "Bryn Callister", participant: "U06"),
            Self.member("remote-001_speaker_03", "Rowan Ashby", participant: "U0B"),
        ])
        #expect(Self.keys(groups) == [
            ["remote-001_speaker_00", "remote-001_speaker_03"],
            ["remote-001_speaker_01", "remote-001_speaker_02"],
        ])
    }

    @Test("clusters matched to one voice profile are one person")
    func clustersMatchedToOneVoiceProfileAreOnePerson() async throws {
        let groups = SpeakerGrouping.groups([
            Self.member("remote-001_speaker_00", "Ada Lovelace", identity: 4),
            Self.member("remote-001_speaker_01", "Ada Lovelace", identity: 4),
        ])
        #expect(Self.keys(groups) == [["remote-001_speaker_00", "remote-001_speaker_01"]])
    }

    // The account and the identity name different keys, and the key
    // carrying both is what puts all three together.
    @Test("an account and an identity join through the key holding both")
    func anAccountAndAnIdentityJoinThroughTheKeyHoldingBoth() async throws {
        let groups = SpeakerGrouping.groups([
            Self.member("remote-001_speaker_00", "Ada Lovelace", participant: "U06"),
            Self.member("remote-001_speaker_01", "Ada Lovelace", identity: 4),
            Self.member("sensor_U06", "Ada Lovelace", identity: 4, participant: "U06"),
        ])
        #expect(Self.keys(groups) == [[
            "remote-001_speaker_00", "remote-001_speaker_01", "sensor_U06",
        ]])
    }

    // A name is the weakest of the three and still enough. Two chips
    // reading the same thing are a duplicate to whoever is looking at
    // them, whatever wrote them.
    @Test("the same name with nothing else behind it is still one person")
    func theSameNameWithNothingElseBehindItIsStillOnePerson() async throws {
        let groups = SpeakerGrouping.groups([
            Self.member("remote-001_speaker_00", "Bryn Callister"),
            Self.member("remote-001_speaker_01", "bryn callister"),
        ])
        #expect(Self.keys(groups) == [["remote-001_speaker_00", "remote-001_speaker_01"]])
    }

    @Test("clusters nobody has named stay apart")
    func clustersNobodyHasNamedStayApart() async throws {
        let groups = SpeakerGrouping.groups([
            Self.member("remote-001_speaker_00"),
            Self.member("remote-001_speaker_01"),
        ])
        #expect(Self.keys(groups) == [["remote-001_speaker_00"], ["remote-001_speaker_01"]])
    }

    // A sensor key says whose account it is in the key itself, so it
    // joins that person before anything has named either of them.
    @Test("an unnamed sensor key joins the account it names")
    func anUnnamedSensorKeyJoinsTheAccountItNames() async throws {
        let groups = SpeakerGrouping.groups([
            Self.member("remote-001_speaker_00", "Bryn Callister", participant: "U06"),
            Self.member("sensor_U06"),
        ])
        #expect(Self.keys(groups) == [["remote-001_speaker_00", "sensor_U06"]])
    }

    @Test("the microphone track is left alone by an unrelated name")
    func theMicrophoneTrackIsLeftAloneByAnUnrelatedName() async throws {
        let groups = SpeakerGrouping.groups([
            Self.member("local", "Marlow", identity: 1),
            Self.member("remote-001_speaker_00", "Bryn Callister", participant: "U06"),
        ])
        #expect(Self.keys(groups) == [["local"], ["remote-001_speaker_00"]])
    }
}
