import AVFoundation
import Foundation
import PipitAudio
import PipitCore
import PipitIntegrations
import PipitServices
import Testing

/// End-to-end runs against the real API: import a recording, process it, and
/// check the archive that comes out the other side.
///
/// Gated the same way as the other live tests, plus a separate switch for the
/// long-meeting run because that one takes tens of minutes.
@Suite("LiveEndToEnd")
struct LiveEndToEndTests {
    static var wantsLongRun: Bool {
        ProcessInfo.processInfo.environment["PIPIT_LIVE_LONG"] == "1"
    }

    static var hasLongFixture: Bool {
        guard let fixtures = LiveOpenAITests.fixtureDirectory else { return false }
        return FileManager.default.fileExists(
            atPath: fixtures.appendingPathComponent("long.wav").path
        )
    }

    @Test(
        "an imported recording completes and leaves a readable archive",
        .enabled(if: LiveOpenAITests.isEnabled, LiveOpenAITests.liveReason),
        .enabled(if: LiveOpenAITests.hasKey, LiveOpenAITests.keyReason),
        .enabled(if: LiveOpenAITests.hasFixture, LiveOpenAITests.fixtureReason)
    )
    func anImportedRecordingCompletesAndLeavesAReadableArchive() async throws {
        let (_, fixtures) = try LiveOpenAITests.live()
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = MeetingRepository(root: root)
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .imported, provider: .unknown, startedAt: started,
            titles: TitleCandidates(window: "conversation", timestampFallback: "fallback"),
            now: started
        )
        let result = try AudioImporter(segmentSeconds: 30).import(
            source: fixtures.appendingPathComponent("conversation.wav"),
            into: created.store,
            meetingID: created.metadata.id
        )
        #expect(
            abs(result.durationSeconds - 38.5) <= 1.0,
            "expected \(38.5) ± \(1.0), got \(result.durationSeconds)"
        )

        var metadata = created.metadata
        metadata.durationSeconds = result.durationSeconds
        metadata.endedAt = started.addingTimeInterval(result.durationSeconds)
        metadata.importedOriginalFilename = result.originalFilename
        metadata.processing.advance(to: .finalizing, at: started)
        metadata.processing.advance(to: .audioSafe, at: started)
        try created.store.writeMetadata(metadata)
        try created.store.writeNotes(
            "Call with me (Andrew), my boss Chris, and Tim from the platform team."
        )

        var mutableSettings = AppSettings()
        mutableSettings.localUserName = "Andrew"
        let settings = mutableSettings
        let pipeline = ProcessingPipeline(
            repository: repository,
            backend: OpenAIClient(keyProvider: EnvironmentAPIKeyStore()),
            settingsProvider: { settings }
        )
        await pipeline.process(meetingID: created.metadata.id)

        let final = try created.store.readMetadata()
        #expect(
            final.processing.state == .complete,
            "processing stopped at \(final.processing.state): \(final.processing.lastFailure?.message ?? "")"
        )

        // An imported recording has one track holding everyone, so it is
        // diarized and keeps its raw labels rather than assuming a local user.
        let transcript = try #require(try created.store.readCanonicalTranscript())
        #expect(transcript.utterances.count >= 3, "got \(transcript.utterances.count) utterances")
        #expect(
            !transcript.speakerKeys.contains(SpeakerLabel.localUser),
            "an import should not claim a local user"
        )
        #expect(transcript.speakerKeys.count >= 2, "expected several speakers")

        let markdown = try String(
            contentsOf: created.store.layout.transcriptMarkdown, encoding: .utf8
        )
        #expect(markdown.contains("#"), "the transcript should render as Markdown")
        #expect(
            FileManager.default.fileExists(atPath: created.store.layout.summary.path),
            "summary.md should exist"
        )
        // The original is preserved byte for byte.
        let preserved = created.store.layout.originals
            .appendingPathComponent("conversation.wav")
        #expect(
            try Data(contentsOf: preserved)
                == (try Data(contentsOf: fixtures.appendingPathComponent("conversation.wav")))
        )
        // Human notes are never overwritten by enrichment.
        #expect(created.store.readNotes().contains("platform team"))
    }

    @Test(
        "a meeting over an hour is chunked, merged and de-duplicated",
        .enabled(if: LiveEndToEndTests.wantsLongRun,
                 "set PIPIT_LIVE_LONG=1 to run the long-meeting test"),
        .enabled(if: LiveOpenAITests.isEnabled, LiveOpenAITests.liveReason),
        .enabled(if: LiveOpenAITests.hasKey, LiveOpenAITests.keyReason),
        .enabled(if: LiveOpenAITests.hasFixture, LiveOpenAITests.fixtureReason),
        .enabled(if: LiveEndToEndTests.hasLongFixture, "run scripts/make-long-fixture.sh first")
    )
    func aMeetingOverAnHourIsChunkedMergedAndDeDuplicated() async throws {
        let (_, fixtures) = try LiveOpenAITests.live()
        let longFixture = fixtures.appendingPathComponent("long.wav")

        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root)
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .inPerson, provider: .unknown, startedAt: started, now: started
        )
        let result = try AudioImporter(segmentSeconds: 30).import(
            source: longFixture, into: created.store, meetingID: created.metadata.id
        )
        #expect(
            result.durationSeconds > 3_600,
            "the fixture should exceed an hour, got \(Int(result.durationSeconds))s"
        )

        var metadata = created.metadata
        metadata.durationSeconds = result.durationSeconds
        metadata.processing.advance(to: .finalizing, at: started)
        metadata.processing.advance(to: .audioSafe, at: started)
        try created.store.writeMetadata(metadata)

        var mutableSettings = AppSettings()
        // The transcript is what matters here; enrichment would only add cost.
        mutableSettings.enrichment = EnrichmentSettings(
            generateTitle: false, generateDescription: false, generateNotes: false,
            generateSummary: false, suggestSpeakers: false
        )
        let settings = mutableSettings
        let pipeline = ProcessingPipeline(
            repository: repository,
            backend: OpenAIClient(keyProvider: EnvironmentAPIKeyStore()),
            settingsProvider: { settings }
        )
        await pipeline.process(meetingID: created.metadata.id)

        let final = try created.store.readMetadata()
        #expect(
            final.processing.state == .complete,
            "stopped at \(final.processing.state): \(final.processing.lastFailure?.message ?? "")"
        )

        let raw = try created.store.readRawTranscript()
        #expect(raw.chunks.count >= 4, "an hour should chunk, got \(raw.chunks.count)")
        for chunk in raw.chunks {
            #expect(
                chunk.durationSeconds <= AILimits.maximumDiarizationSeconds,
                "chunk \(chunk.id) is \(Int(chunk.durationSeconds))s, over the model limit"
            )
        }
        // Raw labels stay distinct per chunk: the API's labels are only
        // meaningful inside one request.
        let rawLabels = Set(raw.chunks.flatMap { chunk in
            chunk.segments.compactMap(\.speaker).map {
                SpeakerLabel.namespaced(chunkID: chunk.id, rawLabel: $0)
            }
        })
        #expect(rawLabels.count >= raw.chunks.count, "labels collapsed across chunks")

        let transcript = try #require(try created.store.readCanonicalTranscript())
        var previousStart = -1.0
        for utterance in transcript.utterances {
            #expect(
                utterance.start >= previousStart,
                "timestamps went backwards at \(utterance.start)"
            )
            previousStart = utterance.start
        }
        #expect(
            transcript.durationSeconds > 3_000,
            "the transcript should span the recording, got \(Int(transcript.durationSeconds))s"
        )

        // The fixture repeats one conversation, so exact duplicates are
        // expected; what must not happen is the same utterance appearing
        // twice at nearly the same timestamp, which is what a missed
        // overlap de-duplication looks like.
        var duplicatesAtSameTime = 0
        for (previous, next) in zip(transcript.utterances, transcript.utterances.dropFirst()) {
            guard next.start - previous.start < 3 else { continue }
            if TextSimilarity.score(previous.text, next.text) > 0.85 { duplicatesAtSameTime += 1 }
        }
        #expect(
            duplicatesAtSameTime <= 2,
            "found \(duplicatesAtSameTime) near-identical utterances at the same time"
        )
    }
}
