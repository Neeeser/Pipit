import Foundation
import PipitCore
import PipitServices
import PipitSpeakers
import PipitUI
import Testing

/// A call that dropped and was rejoined is two recordings and one meeting.
///
/// The rule these pin: linking them changes no audio and hides nothing. Both
/// recordings keep every file they had, the second one's folder moves inside
/// the first's, the conversation reads as one in time order, and being wrong
/// about the link is undoable.
@Suite("Reconnect")
struct ReconnectTests {
    /// Two recordings fifteen minutes apart, the second linked to the first.
    private static func makeSplitMeeting(
        root: URL, link: Bool = true
    ) throws -> (repository: MeetingRepository, first: String, second: String) {
        let repository = MeetingRepository(root: root)
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let first = try repository.createMeeting(
            source: .googleMeet, provider: .googleMeet, startedAt: started,
            titles: TitleCandidates(provider: "Weekly sync", timestampFallback: "f"),
            now: started
        )
        let second = try repository.createMeeting(
            source: .googleMeet, provider: .googleMeet,
            startedAt: started.addingTimeInterval(900),
            titles: TitleCandidates(provider: "Weekly sync", timestampFallback: "f"),
            now: started.addingTimeInterval(900)
        )

        _ = try first.store.updateMetadata { $0.durationSeconds = 600 }
        _ = try second.store.updateMetadata {
            $0.durationSeconds = 1_500
            $0.possibleContinuationOf = first.metadata.id
            $0.possibleContinuationReason = "same meeting, 15 minutes later"
        }
        try first.store.writeCanonicalTranscript(
            CanonicalTranscript(
                generatedAt: started,
                utterances: [
                    Utterance(
                        id: "a1", start: 0, end: 5, track: .remote, rawSpeakerLabel: nil,
                        speakerKey: "remote-001_speaker_00", text: "before the drop",
                        chunkID: "c", model: "m"
                    )
                ]
            ))
        try second.store.writeCanonicalTranscript(
            CanonicalTranscript(
                generatedAt: started.addingTimeInterval(900),
                utterances: [
                    Utterance(
                        id: "b1", start: 0, end: 5, track: .remote, rawSpeakerLabel: nil,
                        speakerKey: "remote-001_speaker_00", text: "after the rejoin",
                        chunkID: "c", model: "m"
                    )
                ]
            ))
        var secondMap = SpeakerMap()
        secondMap.assign("Nadia", to: "remote-001_speaker_00")
        try second.store.writeSpeakerMap(secondMap)

        if link {
            _ = try second.store.updateMetadata {
                $0.mergedIntoMeetingID = first.metadata.id
                $0.possibleContinuationOf = nil
            }
            _ = try first.store.updateMetadata {
                $0.absorbedMeetingIDs = [second.metadata.id]
            }
        }
        return (repository, first.metadata.id, second.metadata.id)
    }

    @Test("both halves are one meeting, in the order they happened")
    func bothHalvesAreOneMeetingInTheOrderTheyHappened() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, first, second) = try Self.makeSplitMeeting(root: root)

        let logical = try #require(repository.logicalMeeting(id: first))
        #expect(logical.recordings.map(\.metadata.id) == [first, second])
        #expect(
            abs(logical.durationSeconds - 2_100) <= 0.001,
            "expected \(2_100) ± \(0.001), got \(logical.durationSeconds) — the conversation holds both recordings' audio"
        )

        let lines = logical.combinedTranscript()
        #expect(lines.map(\.utterance.text) == ["before the drop", "after the rejoin"])
        #expect(
            abs(lines[1].timelineStart - 900) <= 0.001,
            "expected \(900) ± \(0.001), got \(lines[1].timelineStart) — the second half is placed by when its recording started"
        )
        #expect(
            lines[1].speakerName == "Nadia",
            "and resolved through its own speaker map, not the first half's"
        )
        #expect(
            lines[0].speakerName == "Speaker 1, part 1",
            "the same key in the other recording is a different person, so the line says which part"
        )
    }

    @Test("an unnamed speaker's chip finds its lines in a split meeting")
    func anUnnamedSpeakersChipFindsItsLinesInASplitMeeting() async throws {
        // The chip named an unnamed voice "Speaker 1, part 1" while its lines
        // were named "Speaker 1", and the walk matches on the name, so the
        // chip's arrow found nothing to step through.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, first, _) = try Self.makeSplitMeeting(root: root)
        let logical = try #require(repository.logicalMeeting(id: first))
        let chipName = SpeakerMap.fallbackName(
            for: "remote-001_speaker_00", recordingIndex: 0, recordingCount: logical.recordings.count)

        let walk = TranscriptNavigation.speaker(
            chipName, recordingID: first, in: CombinedLineBlock.blocks(from: logical.combinedTranscript()))
        #expect(walk.targets.count == 1)
    }

    @Test("the folded half is reachable by its own identifier")
    func theFoldedHalfIsReachableByItsOwnIdentifier() async throws {
        // A notification posted before the two were linked still carries
        // it, and Reveal in Finder is built from it. Resolving to nothing
        // was how the second half of a dropped call became unreachable.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, first, second) = try Self.makeSplitMeeting(root: root)

        let logical = try #require(repository.logicalMeeting(id: second))
        #expect(
            logical.id == first,
            "asking about the continuation answers with the whole conversation"
        )
        #expect(logical.combinedTranscript().contains { $0.utterance.text == "after the rejoin" })
    }

    @Test("recent meetings shows one row for the whole conversation")
    func recentMeetingsShowsOneRowForTheWholeConversation() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, first, _) = try Self.makeSplitMeeting(root: root)

        let listed = repository.listMeetings()
        #expect(listed.map(\.id) == [first])
        let summary = try #require(listed.first)
        #expect(summary.recordingCount == 2)
        #expect(
            abs(summary.durationSeconds - 2_100) <= 0.001,
            "expected \(2_100) ± \(0.001), got \(summary.durationSeconds) — and reports the audio both halves hold, not just the first"
        )
    }

    @Test("separating a continuation gives back two meetings and loses nothing")
    func separatingAContinuationGivesBackTwoMeetingsAndLosesNothing() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, first, second) = try Self.makeSplitMeeting(root: root)
        let secondDirectory = try #require(
            repository.findMeeting(id: second, includingMerged: true)?.store.layout.root
        )

        await MainActor.run {
            let runtime = PipitRuntime(settingsDirectory: root)
            var settings = runtime.settings
            settings.storageRootPath = root.path
            runtime.update(settings: settings)
            runtime.detachContinuation(meetingID: second)
        }

        let listed = repository.listMeetings()
        #expect(Set(listed.map(\.id)) == Set([first, second]), "both are their own meeting again")
        #expect(listed.first { $0.id == first }?.recordingCount == 1)
        #expect(
            abs((listed.first { $0.id == first }?.durationSeconds ?? 0) - 600) <= 0.001,
            "expected \(600) ± \(0.001), got \((listed.first { $0.id == first }?.durationSeconds ?? 0)) — and the first reports only its own audio again"
        )
        #expect(
            FileManager.default.fileExists(atPath: secondDirectory.path),
            "it was never inside the first folder, so it is where it always was"
        )
        let reopened = try #require(repository.findMeeting(id: second))
        #expect(
            ((try? reopened.store.readCanonicalTranscript()) ?? nil)?.utterances
                .contains { $0.text == "after the rejoin" } ?? false
        )
    }

    @Test("a correction on the second half reaches the second half")
    func aCorrectionOnTheSecondHalfReachesTheSecondHalf() async throws {
        // The panel shows both halves as one transcript, so a correction
        // on a line from the continuation is routed to that recording.
        // Every lookup by identifier hid folded recordings, so the write
        // threw and the panel showed a change nothing had stored.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, first, second) = try Self.makeSplitMeeting(root: root)
        let (store, storeRoot) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: storeRoot) }

        let pipeline = ProcessingPipeline(
            repository: repository,
            backend: FakeAIBackend(),
            backends: ProcessingBackends(
                transcription: { _, _ in StubLocalTranscriber(segments: []) },
                diarization: { _, _ in
                    StubLocalDiarizer(intervals: [], chunkEmbeddings: [])
                },
                speakers: SpeakerRecognitionService(store: store)
            ),
            scratch: ProcessingScratch(root: root.appendingPathComponent("scratch")),
            clock: ManualClock(),
            settingsProvider: { AppSettings() },
            wait: { _ in }
        )

        try await pipeline.applyUtteranceSpeaker(
            "Dara", utteranceIDs: ["b1"], meetingID: second
        )

        let continuation = try #require(repository.findMeeting(id: second, includingMerged: true))
        let map = try continuation.store.readSpeakerMap()
        #expect(
            map.utteranceOverrides.first?.assignment.displayName == "Dara",
            "the correction is stored on the recording the line came from"
        )
        let earlier = try #require(repository.findMeeting(id: first))
        #expect(
            try earlier.store.readSpeakerMap().utteranceOverrides.isEmpty,
            "and not on the other half, which holds different audio"
        )

        // And it is what the combined view now shows.
        let logical = try #require(repository.logicalMeeting(id: second))
        #expect(logical.combinedTranscript().last?.speakerName == "Dara")
    }

    @Test("linking does not rewrite either recording's own duration")
    func linkingDoesNotRewriteEitherRecordingSOwnDuration() async throws {
        // Adding the second half into the first recording's stored total
        // made undoing the link a subtraction, and a subtraction that goes
        // wrong reports a duration no file supports.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, first, second) = try Self.makeSplitMeeting(root: root, link: false)

        await MainActor.run {
            let runtime = PipitRuntime(settingsDirectory: root)
            var settings = runtime.settings
            settings.storageRootPath = root.path
            runtime.update(settings: settings)
            runtime.combine(meetingID: second, into: first, reason: "test")
        }

        let stored = try #require(repository.findMeeting(id: first))
        #expect(
            abs(stored.metadata.durationSeconds - 600) <= 0.001,
            "expected \(600) ± \(0.001), got \(stored.metadata.durationSeconds) — the recording still reports the audio it holds"
        )
        #expect(stored.metadata.absorbedMeetingIDs == [second])
        #expect(
            abs((repository.logicalMeeting(id: first)?.durationSeconds ?? 0) - 2_100) <= 0.001,
            "expected \(2_100) ± \(0.001), got \((repository.logicalMeeting(id: first)?.durationSeconds ?? 0)) — and the conversation reports both, derived rather than stored"
        )
    }

    // MARK: - one folder per conversation

    private static func finish(_ repository: MeetingRepository, _ ids: String...) throws {
        for id in ids {
            let found = try #require(repository.findMeeting(id: id, includingMerged: true))
            _ = try found.store.updateMetadata { $0.processing.state = .complete }
        }
    }

    private static func root(_ repository: MeetingRepository, _ id: String) throws -> URL {
        try #require(repository.findMeeting(id: id, includingMerged: true)).store.layout.root
    }

    @Test("a linked recording's folder moves inside the folder the conversation started in")
    func aLinkedRecordingMovesInsideTheFirstFolder() async throws {
        // Finder showed a merged meeting as separate folders, the first
        // holding a transcript of its first few minutes only.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, first, second) = try Self.makeSplitMeeting(root: root)
        try Self.finish(repository, first, second)
        let firstRoot = try Self.root(repository, first)

        let moves = repository.tidyConversationFolders(isHeld: { _ in false })

        #expect(moves.map(\.meetingID) == [second])
        let secondRoot = try Self.root(repository, second)
        #expect(
            secondRoot.deletingLastPathComponent().standardizedFileURL
                == MeetingLayout(root: firstRoot).parts.standardizedFileURL)
        #expect(repository.listMeetings().map(\.id) == [first], "still one meeting")
        #expect(repository.logicalMeeting(id: first)?.recordings.count == 2)
        #expect(
            repository.meetingDirectories().filter { $0.lastPathComponent == secondRoot.lastPathComponent }.count == 1,
            "the part is listed once")
        #expect(repository.tidyConversationFolders(isHeld: { _ in false }).isEmpty, "a second tidy moves nothing")
        #expect(
            ((try? repository.findMeeting(id: second, includingMerged: true)?.store.readCanonicalTranscript()) ?? nil)?
                .utterances.first?.text == "after the rejoin",
            "and every file came with it")
    }

    @Test("a recording a job holds, or one still processing, stays where it is")
    func aBusyRecordingStaysWhereItIs() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, first, second) = try Self.makeSplitMeeting(root: root)
        let before = try Self.root(repository, second)

        #expect(repository.tidyConversationFolders(isHeld: { _ in false }).isEmpty, "still processing")
        try Self.finish(repository, first, second)
        #expect(repository.tidyConversationFolders(isHeld: { $0 == second }).isEmpty, "a job is writing into it")
        #expect(try Self.root(repository, second).standardizedFileURL == before.standardizedFileURL)
    }

    @Test("a separated recording goes back beside the one it was part of")
    func aSeparatedRecordingGoesBackBeside() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, first, second) = try Self.makeSplitMeeting(root: root)
        try Self.finish(repository, first, second)
        repository.tidyConversationFolders(isHeld: { _ in false })
        let firstRoot = try Self.root(repository, first)

        _ = try #require(repository.findMeeting(id: second, includingMerged: true)).store.updateMetadata {
            $0.mergedIntoMeetingID = nil
        }
        _ = try #require(repository.findMeeting(id: first)).store.updateMetadata { $0.absorbedMeetingIDs = [] }
        let moves = repository.tidyConversationFolders(around: [first, second], isHeld: { _ in false })

        #expect(moves.map(\.meetingID) == [second])
        #expect(
            try Self.root(repository, second).deletingLastPathComponent().standardizedFileURL
                == firstRoot.deletingLastPathComponent().standardizedFileURL)
        #expect(
            !FileManager.default.fileExists(atPath: MeetingLayout(root: firstRoot).parts.path),
            "an empty Parts folder is not left behind")
        #expect(Set(repository.listMeetings().map(\.id)) == Set([first, second]))
    }

    @Test("a part's bytes are counted once")
    func aPartsBytesAreCountedOnce() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, first, second) = try Self.makeSplitMeeting(root: root)
        try Self.finish(repository, first, second)
        let before = repository.usage()
        repository.tidyConversationFolders(isHeld: { _ in false })
        let after = repository.usage()
        #expect(after.bytes == before.bytes)
        #expect(after.meetingCount == 1)
    }

    @Test("the first folder's transcript holds the whole conversation")
    func theFirstFoldersTranscriptHoldsTheWholeConversation() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, first, second) = try Self.makeSplitMeeting(root: root)
        let pipeline = PipelineFixtures.makePipeline(repository: repository, backend: FakeAIBackend())

        await pipeline.rerenderMeetings([second])

        let firstText = try #require(repository.findMeeting(id: first)?.store.readTranscriptMarkdown())
        #expect(firstText.contains("## Part 1"))
        #expect(firstText.contains("## Part 2"))
        let before = try #require(firstText.range(of: "before the drop"))
        let after = try #require(firstText.range(of: "after the rejoin"))
        #expect(before.lowerBound < after.lowerBound, "in the order it was said")
        #expect(firstText.contains("**Nadia**"), "named through the second recording's own speakers")
        let secondText = try #require(
            repository.findMeeting(id: second, includingMerged: true)?.store.readTranscriptMarkdown())
        #expect(!secondText.contains("before the drop"), "a part keeps its own transcript")
    }
}
