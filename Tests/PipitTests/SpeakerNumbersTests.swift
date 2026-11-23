import Foundation
import PipitCore
import Testing

private func line(_ id: String, _ key: String, at start: Double) -> Utterance {
    Utterance(
        id: id, start: start, end: start + 2,
        track: key == SpeakerLabel.localUser ? .mic : .remote,
        rawSpeakerLabel: key, speakerKey: key, text: "line \(id)",
        chunkID: "remote_full", model: "test"
    )
}

/// A transcript shaped like a diarizer whose slot numbers have nothing to do
/// with who spoke first: slot 0 only joins near the end.
private let slotOrderedLate = [
    line("u1", "remote-001_speaker_nemotron3_1", at: 78),
    line("u2", "remote-001_speaker_nemotron3_2", at: 84),
    line("u3", SpeakerLabel.localUser, at: 86),
    line("u4", "remote-001_speaker_nemotron3_3", at: 918),
    line("u5", "remote-001_speaker_nemotron3_0", at: 1488),
    line("u6", "remote-001_speaker_nemotron3_1", at: 1500),
]

@Suite("Speaker numbers")
struct SpeakerNumbersTests {
    @Test("an unnamed speaker is numbered by when they first talk, not by the model's slot")
    func numberedByFirstLine() {
        let numbers = SpeakerNumbers(slotOrderedLate)
        let names = SpeakerMap().namesByKey(slotOrderedLate, numbers: numbers)
        #expect(names["remote-001_speaker_nemotron3_1"] == "Speaker 1")
        #expect(names["remote-001_speaker_nemotron3_2"] == "Speaker 2")
        #expect(names["remote-001_speaker_nemotron3_3"] == "Speaker 3")
        #expect(names["remote-001_speaker_nemotron3_0"] == "Speaker 4")
        #expect(names[SpeakerLabel.localUser] == "Me", "the microphone takes no number")
    }

    @Test("naming one speaker leaves every other speaker's number alone")
    func namingDoesNotRenumber() {
        var map = SpeakerMap()
        map.assign("Talia", to: "remote-001_speaker_nemotron3_1")
        map.assign("Bryn", to: "remote-001_speaker_nemotron3_2")
        let names = map.namesByKey(slotOrderedLate, numbers: SpeakerNumbers(slotOrderedLate))
        #expect(names["remote-001_speaker_nemotron3_1"] == "Talia")
        #expect(names["remote-001_speaker_nemotron3_3"] == "Speaker 3")
        #expect(names["remote-001_speaker_nemotron3_0"] == "Speaker 4")
    }

    @Test("a label outside the transcript reads as a numbered speaker, never as the raw label")
    func labelOutsideTheTranscript() {
        let name = SpeakerMap.fallbackName(
            for: "remote-001_speaker_nemotron3_0", numbers: SpeakerNumbers())
        #expect(name == "Speaker 1")
        let other = SpeakerMap.fallbackName(for: "remote-001_speaker_eend_2", numbers: SpeakerNumbers())
        #expect(other == "Speaker 3")
    }

    @Test("labels from different chunks read as different speakers")
    func chunksReadAsDifferentSpeakers() {
        let lines = [
            line("u1", "remote_chunk_001_speaker_00", at: 0),
            line("u2", "remote_chunk_002_speaker_00", at: 700),
        ]
        let numbers = SpeakerNumbers(lines)
        let first = SpeakerMap.fallbackName(for: "remote_chunk_001_speaker_00", numbers: numbers)
        let second = SpeakerMap.fallbackName(for: "remote_chunk_002_speaker_00", numbers: numbers)
        #expect(first == "Speaker 1")
        #expect(second == "Speaker 2")
    }

    @Test("a meeting of several recordings says which recording a generated name belongs to")
    func recordingPartSuffix() {
        let name = SpeakerMap.fallbackName(
            for: "remote-001_speaker_nemotron3_0", numbers: SpeakerNumbers(slotOrderedLate),
            recordingIndex: 1, recordingCount: 2)
        #expect(name == "Speaker 4, part 2")
    }

    @Test("the chip, the suggestion pill and the lines agree when the first voice holds a late slot")
    func chipPillAndLinesAgree() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root)
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let meeting = try repository.createMeeting(
            source: .googleMeet, provider: .googleMeet, startedAt: started,
            titles: TitleCandidates(provider: "Weekly sync", timestampFallback: "f"), now: started)
        try meeting.store.writeCanonicalTranscript(
            CanonicalTranscript(generatedAt: started, utterances: slotOrderedLate))
        let logical = try #require(repository.logicalMeeting(id: meeting.metadata.id))
        let key = "remote-001_speaker_nemotron3_0"

        // The chip row numbers from the transcript, the pill from the
        // lightweight speaker list. Both must name the line the same way.
        let transcript = try #require(try meeting.store.readCanonicalTranscript())
        let chip = SpeakerMap.fallbackName(
            for: key, numbers: SpeakerNumbers(transcript.utterances), recordingIndex: 0, recordingCount: 1)
        let pill = SpeakerMap.fallbackName(
            for: key, numbers: SpeakerNumbers(lineKeys: try meeting.store.readTranscriptSpeakers().map(\.key)),
            recordingIndex: 0, recordingCount: 1)
        let lines = logical.combinedTranscript()
        #expect(chip == "Speaker 4")
        #expect(pill == chip)
        #expect(lines.first { $0.utterance.speakerKey == key }?.speakerName == chip)

        let walk = TranscriptNavigation.speaker(
            chip, recordingID: meeting.metadata.id, in: CombinedLineBlock.blocks(from: lines))
        #expect(walk.targets.count == 1)
    }

    @Test("the written transcript uses the same first-to-talk names")
    func renderedTranscriptUsesTheNumbers() {
        let transcript = CanonicalTranscript(generatedAt: Date(), utterances: slotOrderedLate)
        let text = TranscriptRenderer().plainText(transcript: transcript, speakers: SpeakerMap())
        #expect(text.contains("Speaker 4: line u5"))
        #expect(!text.contains("NEMOTRON"))
    }
}

extension SpeakerMap {
    fileprivate func namesByKey(_ lines: [Utterance], numbers: SpeakerNumbers) -> [String: String] {
        var out: [String: String] = [:]
        for line in lines { out[line.speakerKey] = resolvedName(for: line, numbers: numbers) }
        return out
    }
}
