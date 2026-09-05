import Foundation
import PipitAudio
import PipitCore
import PipitLocalAI
import PipitSpeakers
import Testing

private func localModelsEnabled() -> Bool {
    ProcessInfo.processInfo.environment["PIPIT_LOCAL_MODELS"] == "1"
}

private func localFixtureDirectory() -> URL? {
    ProcessInfo.processInfo.environment["PIPIT_LIVE_FIXTURE"].map { URL(fileURLWithPath: $0) }
}

private func localConversationFixture() -> URL? {
    guard let file = localFixtureDirectory()?.appendingPathComponent("conversation.wav"),
        FileManager.default.fileExists(atPath: file.path)
    else { return nil }
    return file
}

/// Opt-in tests that load the real on-device models.
///
/// Skipped unless `PIPIT_LOCAL_MODELS=1`, because the first run downloads
/// about 650 MB and the runner has no per-test timeout. The audio is the same
/// locally synthesised fixture the live API tests use, so nothing here costs
/// money or leaves the machine.
@Suite(
    "LocalModels",
    .enabled(
        if: localModelsEnabled(),
        "set PIPIT_LOCAL_MODELS=1 to run the on-device model tests"
    ),
    .enabled(
        if: localFixtureDirectory() != nil,
        "run scripts/make-live-fixture.sh and set PIPIT_LIVE_FIXTURE"
    ),
    .enabled(
        if: localConversationFixture() != nil,
        "the fixture directory has no conversation.wav"
    )
)
struct LocalModelTests {
    private static func requireModels() throws -> (URL, URL) {
        let conversation = try #require(
            localConversationFixture(), "the fixture directory has no conversation.wav"
        )
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pipit", isDirectory: true)
        return (support, conversation)
    }

    @Test("the models install into Pipit's own directory and load")
    func theModelsInstallIntoPipitsOwnDirectoryAndLoad() async throws {
        let (support, _) = try Self.requireModels()
        let manager = LocalModelManager(applicationSupport: support)
        let snapshot = try await manager.install()
        let whisper = try #require(snapshot.receipts[.whisper])
        #expect(whisper.revision == LocalSpeechStack.revision(for: .whisper))
        let folder = try #require(whisper.detail)
        #expect(
            folder.contains("Application Support/Pipit/Models/Whisper"),
            "got \(folder)"
        )
        #expect(!folder.contains("/Documents/"))
        #expect(
            whisper.bytes > 300_000_000,
            "the model is about 624 MB, got \(whisper.bytes)"
        )
        #expect(snapshot.receipts[.diarizer] != nil, "the diarizer installs with it")
        let installed = await manager.isInstalled
        #expect(installed)
    }

    @Test("transcription returns words with usable timings and no special tokens")
    func transcriptionReturnsWordsWithUsableTimingsAndNoSpecialTokens() async throws {
        let (support, audio) = try Self.requireModels()
        let manager = LocalModelManager(applicationSupport: support)
        _ = try await manager.install()
        let backend = WhisperTranscriptionBackend(models: manager)

        // Warm the pipeline first. On a 38-second clip the one-off
        // model load dominates, and timing it would pin the load rather
        // than the transcription.
        _ = try await backend.transcribe(audio: audio) { _ in }
        let started = Date()
        let output = try await backend.transcribe(audio: audio) { _ in }
        let seconds = Date().timeIntervalSince(started)

        #expect(!output.text.isEmpty)
        #expect(
            !output.text.contains("<|"),
            "skipSpecialTokens is off: \(output.text.prefix(80))"
        )
        #expect(output.hasWordTimings, "word timings are what attribution consumes")
        #expect(output.wordCount > 50, "got \(output.wordCount) words")

        var last = -1.0
        var zeroLength = 0
        for segment in output.segments {
            #expect(segment.start >= last - 0.001, "segment starts went backwards")
            last = segment.start
            for word in segment.words ?? [] where word.end <= word.start {
                zeroLength += 1
            }
        }
        #expect(
            zeroLength * 10 < output.wordCount,
            "\(zeroLength) of \(output.wordCount) words have no duration"
        )

        let audioSeconds = MonoAudioDecoder.durationSeconds(audio)
        Log.processing.info(
            "local ASR: \(audioSeconds, privacy: .public)s in \(seconds, privacy: .public)s"
        )
        #expect(
            seconds < audioSeconds,
            "warm transcription ran slower than real time: \(seconds)s for \(audioSeconds)s"
        )
    }

    @Test("diarization separates the fixture's voices and returns their vectors")
    func diarizationSeparatesTheFixturesVoicesAndReturnsTheirVectors() async throws {
        let (support, audio) = try Self.requireModels()
        let manager = LocalModelManager(applicationSupport: support)
        _ = try await manager.install()
        let backend = FluidAudioDiarizationBackend(models: manager)

        let output = try await backend.diarize(audio: audio) { _ in }
        #expect(output.configuration["warmStartFa"] == "0.2")
        #expect(
            output.speakerCount >= 2,
            "the fixture has three voices, found \(output.speakerCount)"
        )
        #expect(!output.chunkEmbeddings.isEmpty)
        #expect(output.chunkEmbeddings.first?.vector.count == 256)

        // Different clusters must be further apart than one cluster is
        // from itself, or nothing downstream can work.
        var byCluster: [String: [[Float]]] = [:]
        for chunk in output.chunkEmbeddings {
            byCluster[chunk.clusterID, default: []].append(chunk.vector)
        }
        let centroids = byCluster.mapValues { VoiceVector.centroid($0) }
        let ids = centroids.keys.sorted()
        if ids.count >= 2 {
            let across = VoiceVector.cosine(centroids[ids[0]]!, centroids[ids[1]]!)
            let within = VoiceVector.cosine(
                centroids[ids[0]]!, VoiceVector.l2Normalized(byCluster[ids[0]]![0])
            )
            #expect(
                within > across,
                "a cluster should sit closer to its own chunks (\(within)) than to another cluster (\(across))"
            )
        }
    }

    @Test("parakeet transcribes the fixture with word timings of its own")
    func parakeetTranscribesTheFixtureWithWordTimingsOfItsOwn() async throws {
        let (support, audio) = try Self.requireModels()
        let manager = LocalModelManager(applicationSupport: support)
        _ = try await manager.install(units: [.parakeet])
        let output = try await ParakeetTranscriptionBackend(models: manager)
            .transcribe(audio: audio) { _ in }
        #expect(!output.text.isEmpty)
        #expect(output.hasWordTimings, "word timings are what attribution consumes")
        #expect(output.wordCount > 50, "got \(output.wordCount) words")
    }

    @Test("the aligner recovers timings for a text-only transcript")
    func theAlignerRecoversTimingsForATextOnlyTranscript() async throws {
        let (support, audio) = try Self.requireModels()
        let manager = LocalModelManager(applicationSupport: support)
        _ = try await manager.install(units: [.parakeet, .ctcAligner])
        // Parakeet's own timed words are the reference: align its text
        // as though it had none, and the timings should come back
        // close to where the decoder heard them.
        let reference = try await ParakeetTranscriptionBackend(models: manager)
            .transcribe(audio: audio) { _ in }
        let aligned = try await CtcTranscriptAligner(models: manager)
            .align(audio: audio, text: reference.text)

        let alignedWords = aligned.flatMap { $0.words ?? [] }
        let referenceWords = reference.segments.flatMap { $0.words ?? [] }
        #expect(
            alignedWords.count * 10 >= referenceWords.count * 9,
            "aligned \(alignedWords.count) of \(referenceWords.count) words"
        )
        var last = -1.0
        for word in alignedWords {
            #expect(word.start >= last - 0.001, "word starts went backwards")
            last = word.start
        }
        // Same words in, so start times should track the decoder's own.
        var deviations: [Double] = []
        for (aligned, reference) in zip(alignedWords, referenceWords)
        where aligned.text.trimmingCharacters(in: .whitespaces).lowercased()
            == reference.text.trimmingCharacters(in: .whitespaces).lowercased() {
            deviations.append(abs(aligned.start - reference.start))
        }
        let mean = deviations.isEmpty
            ? .infinity : deviations.reduce(0, +) / Double(deviations.count)
        #expect(
            mean < 0.5,
            "mean start deviation \(mean)s over \(deviations.count) matched words"
        )
    }

    @Test("cohere transcribes the fixture, text only, and the pipeline shape holds")
    func cohereTranscribesTheFixtureTextOnlyAndThePipelineShapeHolds() async throws {
        // The heavyweight: about 2.1 GB on first run and a several
        // minute ANE compile. Deliberately last in the suite.
        let (support, audio) = try Self.requireModels()
        let manager = LocalModelManager(applicationSupport: support)
        _ = try await manager.install(units: [.cohere])
        let backend = CohereTranscriptionBackend(models: manager)
        #expect(backend.timing == .text)
        let output = try await backend.transcribe(audio: audio) { _ in }
        #expect(!output.text.isEmpty)
        #expect(output.segments.count == 0, "no timings are invented")
        let terms = ["staging", "rollback", "replication"]
        let survived = terms.filter { output.text.lowercased().contains($0) }
        #expect(
            survived.count >= 2,
            "expected the fixture's terms to survive, got: \(output.text.prefix(120))"
        )
    }

    @Test("the archive bitrate preserves the voices the identity models read")
    func theArchiveBitratePreservesTheVoicesTheIdentityModelsRead() async throws {
        let (support, audio) = try Self.requireModels()
        let manager = LocalModelManager(applicationSupport: support)
        _ = try await manager.install()
        let backend = FluidAudioDiarizationBackend(models: manager)

        // The fixture re-encoded exactly as compaction stores a track:
        // AAC, mono, 16 kHz, 48 kbps. Identity margins are thin (the
        // worst impostor scored 0.957 against the true speaker's own
        // 0.951), so the archive representation must keep each voice
        // where the PCM put it.
        let tmp = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let info = try AudioFileInspector().inspect(url: audio)
        let location = TrackAudioLocation.archived(
            track: .remote,
            record: AudioArchive.Track(
                file: audio.lastPathComponent, sampleRate: info.sampleRate,
                channelCount: info.channelCount, frameCount: info.frameCount,
                seconds: info.seconds, firstFrameHostTime: nil
            ),
            directory: audio.deletingLastPathComponent(),
            compactedAt: Date()
        )
        let compressed = tmp.appendingPathComponent("archive.m4a")
        _ = try TrackArchiveExporter().export(location: location, to: compressed)

        let original = try await backend.diarize(audio: audio) { _ in }
        let archived = try await backend.diarize(audio: compressed) { _ in }
        #expect(
            archived.speakerCount >= 2,
            "the archive still separates the voices, found \(archived.speakerCount)"
        )

        func centroids(_ chunks: [(clusterID: String, vector: [Float])]) -> [[Float]] {
            var byCluster: [String: [[Float]]] = [:]
            for chunk in chunks { byCluster[chunk.clusterID, default: []].append(chunk.vector) }
            return byCluster.values.map { VoiceVector.centroid($0) }
        }
        let pcmVoices = centroids(original.chunkEmbeddings.map { ($0.clusterID, $0.vector) })
        let aacVoices = centroids(archived.chunkEmbeddings.map { ($0.clusterID, $0.vector) })
        for voice in pcmVoices {
            let best = aacVoices.map { VoiceVector.cosine(voice, $0) }.max() ?? -1
            #expect(
                best > 0.9,
                "each PCM voice has a close match in the archive, best \(best)"
            )
        }
    }

    @Test("the models load with the network refused")
    func theModelsLoadWithTheNetworkRefused() async throws {
        let (support, audio) = try Self.requireModels()
        let manager = LocalModelManager(applicationSupport: support)
        _ = try await manager.install()
        // A fresh manager over the same directory: nothing is cached in
        // memory, so this is the path a relaunch takes.
        let cold = LocalModelManager(applicationSupport: support)
        let coldInstalled = await cold.isInstalled
        #expect(coldInstalled, "the receipt survives a restart")

        let output = try await FluidAudioDiarizationBackend(models: cold)
            .diarize(audio: audio) { _ in }
        #expect(
            !output.intervals.isEmpty,
            "the diarizer resolved its own models without downloading"
        )
        let words = try await WhisperTranscriptionBackend(models: cold)
            .transcribe(audio: audio) { _ in }
        #expect(
            !words.segments.isEmpty,
            "WhisperKit resolved its model folder without downloading"
        )
    }
}
