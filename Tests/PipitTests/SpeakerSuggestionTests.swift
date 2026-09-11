import Foundation
import PipitCore
import Testing

/// The gate between what a model proposes and what the speaker strip draws.
///
/// Every rule here exists because the alternative is a wrong name on screen
/// asking to be accepted, which is worse than no name at all.
@Suite("SpeakerSuggestions")
struct SpeakerSuggestionTests {

    private static func suggestion(
        _ label: String, _ name: String, confidence: Double = 0.9,
        quote: String = "Ellis, do you want to take this?", atSeconds: Double = 12
    ) -> SpeakerNameSuggestion {
        SpeakerNameSuggestion(
            label: label, name: name, confidence: confidence, quote: quote, atSeconds: atSeconds
        )
    }

    @Test("a suggestion is drawn only for a speaker who still has no name")
    func aSuggestionIsDrawnOnlyForASpeakerWhoStillHasNoName() async throws {
        let set = SpeakerSuggestionSet(suggestions: [
            Self.suggestion("speaker_00", "Ellis"),
            Self.suggestion("speaker_01", "Joe"),
        ])
        // speaker_01 was named by hand after the model answered, so its
        // pill goes away without anything having to delete it.
        let visible = set.visible(forUnnamed: ["speaker_00"])
        #expect(visible.count == 1)
        #expect(visible.first?.name == "Ellis")
    }

    @Test("a dismissed label is not offered again")
    func aDismissedLabelIsNotOfferedAgain() async throws {
        var set = SpeakerSuggestionSet(suggestions: [Self.suggestion("speaker_00", "Ellis")])
        #expect(set.visible(forUnnamed: ["speaker_00"]).count == 1)
        set.dismiss("speaker_00")
        #expect(
            set.visible(forUnnamed: ["speaker_00"]).isEmpty,
            "a name turned down came back"
        )
        // A second dismissal of the same label must not grow the list.
        set.dismiss("speaker_00")
        #expect(set.dismissedLabels.count == 1)
    }

    @Test("a re-run keeps dismissals but replaces the suggestions")
    func aReRunKeepsDismissalsButReplacesTheSuggestions() async throws {
        var set = SpeakerSuggestionSet(suggestions: [Self.suggestion("speaker_00", "Ellis")])
        set.dismiss("speaker_00")
        set.suggestions = [
            Self.suggestion("speaker_00", "Benjamin"), Self.suggestion("speaker_02", "Nicolo"),
        ]
        let visible = set.visible(forUnnamed: ["speaker_00", "speaker_02"])
        #expect(visible.count == 1, "the dismissed speaker came back under a new name")
        #expect(visible.first?.name == "Nicolo")
    }

    @Test("a guess below the floor is not drawn")
    func aGuessBelowTheFloorIsNotDrawn() async throws {
        let set = SpeakerSuggestionSet(suggestions: [
            Self.suggestion("speaker_00", "Ellis", confidence: 0.49),
            Self.suggestion("speaker_01", "Joe", confidence: 0.5),
        ])
        let visible = set.visible(forUnnamed: ["speaker_00", "speaker_01"])
        #expect(visible.count == 1)
        #expect(visible.first?.name == "Joe", "the floor is inclusive")
    }

    @Test("a name with no line behind it is dropped")
    func aNameWithNoLineBehindItIsDropped() async throws {
        let set = SpeakerSuggestionSet(suggestions: [
            Self.suggestion("speaker_00", "Ellis", quote: ""),
            Self.suggestion("speaker_01", "", quote: "Thanks Joe."),
        ])
        #expect(
            set.visible(forUnnamed: ["speaker_00", "speaker_01"]).isEmpty,
            "a suggestion with no quote or no name reached the strip"
        )
    }

    @Test("the most confident guess is drawn first")
    func theMostConfidentGuessIsDrawnFirst() async throws {
        let set = SpeakerSuggestionSet(suggestions: [
            Self.suggestion("speaker_00", "Ellis", confidence: 0.62),
            Self.suggestion("speaker_01", "Joe", confidence: 0.94),
        ])
        let visible = set.visible(forUnnamed: ["speaker_00", "speaker_01"])
        #expect(visible.map(\.name) == ["Joe", "Ellis"])
    }

    @Test("the band reads as a word rather than a percentage")
    func theBandReadsAsAWordRatherThanAPercentage() async throws {
        #expect(Self.suggestion("s", "Ellis", confidence: 0.94).band == .high)
        #expect(Self.suggestion("s", "Ellis", confidence: 0.62).band == .medium)
    }

    // MARK: - checking a suggestion against its own evidence

    private static func line(
        _ key: String, _ text: String, from start: Double
    ) -> Utterance {
        let pieces = text.split(separator: " ").map(String.init)
        var at = start
        var words: [RawTranscriptWord] = []
        for piece in pieces {
            words.append(RawTranscriptWord(start: at, end: at + 0.4, text: piece + " "))
            at += 0.5
        }
        return Utterance(
            id: "\(key)-\(start)", start: start, end: at, track: .remote,
            rawSpeakerLabel: key, speakerKey: key, text: text,
            chunkID: "remote_full", model: "test", words: words
        )
    }

    private static func transcript(_ utterances: [Utterance]) -> CanonicalTranscript {
        CanonicalTranscript(generatedAt: Date(timeIntervalSince1970: 0), utterances: utterances)
    }

    @Test("a suggestion whose line is where it says it is survives")
    func aSuggestionWhoseLineIsWhereItSaysItIsSurvives() async throws {
        let transcript = Self.transcript([
            Self.line("named", "Ellis do you want to take this", from: 12),
            Self.line("speaker_00", "Yes I can pick that up", from: 20),
        ])
        let offered = [
            Self.suggestion(
                "speaker_00", "Ellis",
                quote: "Ellis, do you want to take this?", atSeconds: 12
            )
        ]
        #expect(SpeakerSuggestionEvidence.verified(offered, against: transcript).count == 1)
    }

    @Test("a name taken from the next speaker's own line is dropped")
    func aNameTakenFromTheNextSpeakerSOwnLineIsDropped() async throws {
        // The failure this exists for, on a standup of 10 September 2026 at
        // 0.93 confidence. The quoted line was one named speaker addressing
        // another named speaker, and the label being named had said nothing
        // for a minute either side of it. The model read the turn-taking rule
        // as being about whoever spoke next rather than about the label.
        let transcript = Self.transcript([
            Self.line("named_a", "Okay good all right um Ellis", from: 471),
            Self.line("named_b", "Still working on the pipeline", from: 479),
            Self.line("speaker_00", "on", from: 1027),
        ])
        let offered = [
            Self.suggestion(
                "speaker_00", "Ellis",
                quote: "Okay. Good. All right. Um, Ellis.", atSeconds: 471
            )
        ]
        #expect(SpeakerSuggestionEvidence.verified(offered, against: transcript).isEmpty)
    }

    @Test("a line quoted from somewhere it is not is dropped")
    func aLineQuotedFromSomewhereItIsNotIsDropped() async throws {
        // The timestamp is part of the answer and it is checkable. One
        // suggestion on disk quotes a line that really is in the transcript,
        // 1612 seconds from where it says the line is.
        let transcript = Self.transcript([
            Self.line("speaker_06", "no no", from: 1637),
            Self.line("named", "Hey you hired him you hired him Tal", from: 1639),
        ])
        let offered = [
            Self.suggestion(
                "speaker_06", "Tal",
                quote: "Hey, you hired him. You hired him, Tal.", atSeconds: 27
            )
        ]
        #expect(SpeakerSuggestionEvidence.verified(offered, against: transcript).isEmpty)
    }

    @Test("a label that never says anything cannot be named from a line")
    func aLabelThatNeverSaysAnythingCannotBeNamedFromALine() async throws {
        let transcript = Self.transcript([
            Self.line("named", "okay yeah that would be easiest", from: 530)
        ])
        let offered = [
            Self.suggestion(
                "speaker_00", "Ellis",
                quote: "okay. Yeah, that would be easiest.", atSeconds: 510
            )
        ]
        #expect(SpeakerSuggestionEvidence.verified(offered, against: transcript).isEmpty)
    }

    @Test("a quote copied with the row it was rendered in still matches")
    func aQuoteCopiedWithTheRowItWasRenderedInStillMatches() async throws {
        // The prompt asks for the line verbatim and one model answers with the
        // whole rendered row. Six of its ten words are then furniture, which
        // was enough to throw away a right answer.
        let transcript = Self.transcript([
            Self.line("speaker_02", "Ellis When do you", from: 17),
            Self.line("named", "In about ten minutes", from: 25),
        ])
        let offered = [
            Self.suggestion(
                "speaker_02", "Ellis",
                quote: "[00:17] remote-001_speaker_02: Ellis. When do you", atSeconds: 17
            )
        ]
        #expect(SpeakerSuggestionEvidence.verified(offered, against: transcript).count == 1)
    }

    @Test("a meeting with no suggestions file reads as an empty set")
    func aMeetingWithNoSuggestionsFileReadsAsAnEmptySet() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipit-suggestions-\(UUID().uuidString)")
        let store = MeetingStore(layout: MeetingLayout(root: directory))
        try store.createDirectories()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(store.readSpeakerSuggestions().suggestions.isEmpty)

        try store.writeSpeakerSuggestions(
            SpeakerSuggestionSet(suggestions: [Self.suggestion("speaker_00", "Ellis")])
        )
        let read = store.readSpeakerSuggestions()
        #expect(read.suggestions.count == 1)
        #expect(read.suggestions.first?.quote == "Ellis, do you want to take this?")
        // Never in the speaker map: that file is what the meeting
        // concluded, and this is a proposal about what it could not.
        let mapEntries = try store.readSpeakerMap().entries
        #expect(mapEntries.isEmpty)
    }

    @Test("metadata written before the missing-key flag existed still decodes")
    func metadataWrittenBeforeTheMissingKeyFlagExistedStillDecodes() async throws {
        // Every meeting already on disk lacks this key. Decoding one as
        // a failure would make the whole archive unreadable.
        let json = """
            {"state":"complete","updatedAt":"2026-08-26T16:00:29.792Z",
             "attempts":{"enriching":1},"completedStages":["recording","enriching"]}
            """
        let status = try ArchiveCoding.decode(
            ProcessingStatus.self, from: Data(json.utf8), path: "metadata.json"
        )
        #expect(status.state == .complete)
        #expect(!status.skippedForMissingKey)
    }
}
