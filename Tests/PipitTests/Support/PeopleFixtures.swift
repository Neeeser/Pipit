import Foundation
import PipitCore
import PipitSpeakers

/// Transcript lines and stored appearances for the people directory.
public enum PeopleFixtures {
    public static func utterance(_ speaker: String, _ text: String, at start: Double) -> Utterance {
        Utterance(
            id: "u-\(start)", start: start, end: start + 2, track: .remote,
            rawSpeakerLabel: speaker, speakerKey: speaker, text: text,
            chunkID: "c0", model: "test"
        )
    }

    /// A meeting on disk with one named speaker, and a stand-in for the
    /// mixdown. Nothing here decodes the audio, so a file that exists is
    /// everything the sample needs from it.
    @MainActor
    public static func makeAppearance(
        store: SpeakerStore, identityID: IdentityID,
        root: URL, title: String, at started: Date, turns: [(Double, Double)],
        writingAudio: Bool = true
    ) async throws -> String {
        let meeting = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: title, startedAt: started
        )
        var map = SpeakerMap()
        map.assign("Ben", to: "remote-001_speaker_00", identityID: identityID)
        try meeting.store.writeSpeakerMap(map)
        try meeting.store.writeCanonicalTranscript(CanonicalTranscript(
            generatedAt: started,
            utterances: turns.enumerated().map { index, turn in
                Utterance(
                    id: "u\(index)", start: turn.0, end: turn.1, track: .remote,
                    rawSpeakerLabel: "remote-001_speaker_00",
                    speakerKey: "remote-001_speaker_00",
                    text: "the northwind renewal", chunkID: "c1", model: "m"
                )
            }
        ))
        if writingAudio {
            try Data([0x00]).write(to: meeting.store.layout.recordingAudio)
        }
        try await store.recordOccurrence(
            meetingID: meeting.id, clusterID: "remote-001_speaker_00", track: .remote,
            speechSeconds: turns.reduce(0) { $0 + ($1.1 - $1.0) }, embedding: nil, model: nil,
            resolution: nil, identityID: identityID, source: .human,
            humanVerified: true, wasExpectedParticipant: false
        )
        return meeting.id
    }
}
