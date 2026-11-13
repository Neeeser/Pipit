import Foundation
import PipitCore
import Testing

@Suite("MicrophoneVoiceCheck")
struct MicrophoneVoiceCheckTests {
    // Scores are the ones measured on real meetings, recorded in the type's
    // documentation: the user's own lines, and lines a far-end voice leaked
    // onto the microphone while the far-end tap recorded silence.

    @Test("the user's own lines stay theirs")
    func theUsersOwnLinesStayTheirs() {
        #expect(MicrophoneVoiceCheck.decide(ownScore: 0.63, farEnd: ["remote-001_speaker_04": 0.40]) == .keep)
        #expect(MicrophoneVoiceCheck.decide(ownScore: 0.95, farEnd: ["remote-001_speaker_02": 0.43]) == .keep)
    }

    @Test("a far-end voice on the microphone goes to the far-end speaker it matches")
    func aFarEndVoiceGoesToItsSpeaker() {
        let decision = MicrophoneVoiceCheck.decide(
            ownScore: 0.15,
            farEnd: ["remote-001_speaker_06": 0.73, "remote-001_speaker_00": 0.22])
        #expect(decision == .farEnd(speakerKey: "remote-001_speaker_06"))
        #expect(
            MicrophoneVoiceCheck.decide(ownScore: 0.45, farEnd: ["remote-001_speaker_03": 0.68])
                == .farEnd(speakerKey: "remote-001_speaker_03"))
    }

    @Test("a voice that is not the user and matches nobody is unattributed")
    func anUnmatchedVoiceIsUnattributed() {
        #expect(MicrophoneVoiceCheck.decide(ownScore: 0.17, farEnd: ["remote-001_speaker_10": 0.26]) == .unattributed)
        #expect(MicrophoneVoiceCheck.decide(ownScore: 0.12, farEnd: [:]) == .unattributed)
    }

    @Test("an uncertain line with no clear far-end match stays with the user")
    func anUncertainLineStays() {
        #expect(MicrophoneVoiceCheck.decide(ownScore: 0.45, farEnd: ["remote-001_speaker_01": 0.50]) == .keep)
        #expect(
            MicrophoneVoiceCheck.decide(ownScore: 0.50, farEnd: ["remote-001_speaker_01": 0.62]) == .keep,
            "a far-end match within the margin of the user's own score is not enough")
    }

    @Test("only lines still filed under the user move")
    func onlyLinesStillFiledUnderTheUserMove() {
        func line(_ id: String, _ key: String) -> Utterance {
            Utterance(
                id: id, start: 0, end: 10, track: .mic, rawSpeakerLabel: nil, speakerKey: key,
                text: "words", chunkID: "c", model: "m")
        }
        let transcript = CanonicalTranscript(
            generatedAt: Date(timeIntervalSince1970: 0),
            utterances: [
                line("leaked", SpeakerLabel.localUser),
                line("unmatched", SpeakerLabel.localUser),
                line("own", SpeakerLabel.localUser),
                line("already-moved", "remote-001_speaker_02"),
            ])
        let updated = MicrophoneVoiceCheck.apply(
            [
                "leaked": .farEnd(speakerKey: "remote-001_speaker_06"),
                "unmatched": .unattributed,
                "own": .keep,
                "already-moved": .farEnd(speakerKey: "remote-001_speaker_06"),
            ], to: transcript)
        #expect(
            updated.utterances.map(\.speakerKey) == [
                "remote-001_speaker_06", SpeakerLabel.unattributed(track: .mic), SpeakerLabel.localUser,
                "remote-001_speaker_02",
            ])
    }
}
