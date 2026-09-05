import Foundation
import FluidAudio
import PipitCore
import PipitLocalAI
import PipitSpeakers
import Testing

/// Pins the settings the local stack was measured with.
///
/// Each of these is a value a refactor could silently revert, and each one has a
/// measurement behind it. The tests exist so the revert is a failure rather than
/// a slow degradation nobody attributes to anything.
@Suite("LocalConfiguration")
struct LocalConfigurationTests {
    @Test("an LS-EEND timeline keeps two speakers talking at once")
    func anLSEENDTimelineKeepsTwoSpeakersTalkingAtOnce() async throws {
        // The offline clusterer assigns one speaker per moment, so a
        // simultaneous second voice cannot exist in its output. The
        // whole point of the EEND backend is that it can, and the
        // conversion must not flatten it back out.
        let output = LSEendDiarizationBackend.output(
            segments: [
                (speaker: 0, start: 0, end: 10, activity: 0.9),
                (speaker: 1, start: 4, end: 8, activity: 0.7),
                (speaker: 0, start: 12, end: 15, activity: 0.5),
            ],
            configuration: ["backend": "test"]
        )
        #expect(output.intervals.count == 3)
        let sorted = output.intervals.sorted { $0.start < $1.start }
        #expect(sorted[0].clusterID == sorted[2].clusterID, "one voice keeps one key")
        #expect(
            sorted[1].clusterID != sorted[0].clusterID
                && sorted[1].start < sorted[0].end,
            "the second voice overlaps the first and survives as its own interval"
        )
        let byID = Dictionary(uniqueKeysWithValues: output.clusters.map { ($0.id, $0) })
        #expect(
            abs((byID[sorted[0].clusterID]?.speechSeconds ?? 0) - 13) <= 0.001,
            "expected \(13) ± \(0.001), got \((byID[sorted[0].clusterID]?.speechSeconds ?? 0)) — a cluster's speech is the sum of its own intervals"
        )
        #expect(
            abs((byID[sorted[1].clusterID]?.speechSeconds ?? 0) - 4) <= 0.001,
            "expected \(4) ± \(0.001), got \((byID[sorted[1].clusterID]?.speechSeconds ?? 0))"
        )
        #expect(output.configuration["backend"] == "test")
    }

    @Test("Canary is a bench candidate, not an offered model")
    func canaryIsABenchCandidateNotAnOfferedModel() async throws {
        // A text-only engine: its units are its own weights plus the
        // aligner that supplies the timings it does not, the same
        // shape as Cohere. It stays out of `offered` until the
        // comparative run earns it a place in the settings UI.
        var settings = AppSettings()
        settings.processing.transcription = .local
        settings.processing.localTranscriptionModel = .canary
        // The diarizer and the voice detector ride along: every
        // configuration requires both.
        #expect(
            LocalModelUnit.required(for: settings) == [.canary, .ctcAligner, .diarizer, .voiceActivity]
        )
        #expect(
            !LocalTranscriptionModel.offered.contains(.canary),
            "the settings UI does not offer what the bench has not proven"
        )
        #expect(
            LocalTranscriptionModel.canary.backendIdentifier == LocalSpeechStack.canaryBackendIdentifier
        )
        #expect(
            abs(LocalCanaryTuning.chunkSeconds - 15) <= 0.0001,
            "expected \(15) ± \(0.0001), got \(LocalCanaryTuning.chunkSeconds) — one fixed model window per chunk, so the library's own stitching never runs"
        )
    }

    @Test("Apple speech needs no downloaded units and leads where the OS has it")
    func appleSpeechNeedsNoDownloadedUnitsAndLeadsWhereTheOSHasIt() async throws {
        // The models are system assets the OS installs and owns, so
        // the configuration needs only the units every configuration
        // needs. Where macOS 26 exists it is the fresh-install
        // default, because a first meeting should transcribe without
        // a download; earlier systems default to Parakeet.
        var settings = AppSettings()
        settings.processing.transcription = .local
        settings.processing.localTranscriptionModel = .apple
        #expect(LocalModelUnit.required(for: settings) == [.diarizer, .voiceActivity])
        #expect(
            LocalTranscriptionModel.apple.backendIdentifier == LocalSpeechStack.appleBackendIdentifier
        )
        // The backend's own gate is the source of truth: OS and the
        // SDK this binary was built against, together.
        if AppleSpeechTranscriptionBackend.isAvailable {
            #expect(LocalTranscriptionModel.preferred == .apple)
            #expect(LocalTranscriptionModel.offered == [.apple, .parakeet])
        } else {
            #expect(LocalTranscriptionModel.preferred == .parakeet)
            #expect(LocalTranscriptionModel.offered == [.parakeet])
        }
        #expect(
            AppSettings().processing.localTranscriptionModel == LocalTranscriptionModel.preferred,
            "a fresh install starts on the preferred engine"
        )
    }

    @Test("the cloud lineup is the diarize model first and no whisper-1 row")
    func theCloudLineupIsTheDiarizeModelFirstAndNoWhisper1Row() async throws {
        // Set by the 2026-08-24 deciding run: whisper-1 won zero of
        // fourteen cases against the free local default, and its word
        // timings come from the local aligner now. It still parses
        // and times for anyone who types it under Custom.
        #expect(
            AIModelSettings.transcriptionChoices == ["gpt-4o-transcribe-diarize", "gpt-transcribe"]
        )
        #expect(
            AIModelSettings().transcription == "gpt-4o-transcribe-diarize",
            "choosing Cloud starts on the model that does both jobs"
        )
        #expect(
            AIModelSettings.transcriptionTiming(for: "whisper-1") == .words,
            "a typed whisper-1 still knows its timings"
        )
    }

    @Test("attributed runs become words that keep the aligner's conventions")
    func attributedRunsBecomeWordsThatKeepTheAlignerSConventions() async throws {
        // Aligned word texts are bare tokens: `segments` adds the
        // assembler's leading space itself, so a token that arrives
        // with one renders every gap as a double space. A run's words
        // split its span evenly, and a run the recognizer left
        // untimed rides the previous edge rather than inventing a
        // time.
        let words = AppleSpeechTranscriptionBackend.words(from: [
            (text: "Hello there ", start: 0, end: 2),
            (text: "world", start: 2, end: 3),
        ])
        #expect(words.map(\.text) == ["Hello", "there", "world"])
        #expect(
            abs(words[0].start - 0) <= 0.0001,
            "expected \(0) ± \(0.0001), got \(words[0].start)"
        )
        #expect(abs(words[0].end - 1) <= 0.0001, "expected \(1) ± \(0.0001), got \(words[0].end)")
        #expect(
            abs(words[1].start - 1) <= 0.0001,
            "expected \(1) ± \(0.0001), got \(words[1].start)"
        )
        #expect(abs(words[2].end - 3) <= 0.0001, "expected \(3) ± \(0.0001), got \(words[2].end)")

        let tail = AppleSpeechTranscriptionBackend.words(from: [
            (text: "one", start: 0, end: 1),
            (text: "two", start: nil, end: nil),
        ])
        #expect(abs(tail[1].start - 1) <= 0.0001, "expected \(1) ± \(0.0001), got \(tail[1].start)")
        #expect(abs(tail[1].end - 1) <= 0.0001, "expected \(1) ± \(0.0001), got \(tail[1].end)")
    }

    @Test("a meeting where nobody spoke is empty, not failed")
    func aMeetingWhereNobodySpokeIsEmptyNotFailed() async throws {
        // FluidAudio raises noSpeechDetected rather than returning zero
        // turns. Passed on as an error it failed the meeting, so a
        // recording that captured exactly what happened was filed as
        // needing attention with no transcript, markdown or mixdown.
        let empty = LocalModelManager.silentMeeting(
            OfflineDiarizationError.noSpeechDetected, speakerCount: nil
        )
        let output = try #require(empty)
        #expect(output.intervals.isEmpty)
        #expect(output.clusters.isEmpty)
        #expect(output.configuration["warmStartFa"] != nil, "and still records how it was diarized")

        // Everything else is still a failure.
        #expect(
            LocalModelManager.silentMeeting(
                OfflineDiarizationError.modelNotLoaded("segmentation"), speakerCount: nil
            ) == nil
        )
    }

    @Test("the diarizer runs with the tuned acoustic scaling, not the library default")
    func theDiarizerRunsWithTheTunedAcousticScalingNotTheLibraryDefau() async throws {
        // 0.07 finds 8 speakers where there are 17 and leaves 35.4% of
        // reference speakers without a cluster. 0.20 improves DER, JER,
        // speaker count, word attribution and speaker recovery at once.
        #expect(
            abs(LocalDiarizationTuning.warmStartFa - 0.20) <= 0.0001,
            "expected \(0.20) ± \(0.0001), got \(LocalDiarizationTuning.warmStartFa)"
        )
        #expect(
            LocalDiarizationTuning.warmStartFa != LocalDiarizationTuning.libraryDefaultWarmStartFa
        )
        let config = LocalModelManager.diarizerConfiguration(speakerCount: nil)
        #expect(
            abs(config.clustering.warmStartFa - 0.20) <= 0.0001,
            "expected \(0.20) ± \(0.0001), got \(config.clustering.warmStartFa)"
        )
    }

    @Test("no speaker count is ever supplied automatically")
    func noSpeakerCountIsEverSuppliedAutomatically() async throws {
        // The tuned automatic configuration beat the exact true count on
        // word attribution, on merges the user has to perform, and on
        // speakers recovered. A participant list is worse than not asking.
        #expect(LocalDiarizationTuning.automaticSpeakerCount == nil)
        let automatic = LocalModelManager.diarizerConfiguration(speakerCount: nil)
        #expect(automatic.clustering.numSpeakers == nil)
        #expect(automatic.clustering.minSpeakers == nil)
        #expect(automatic.clustering.maxSpeakers == nil)

        // Only an explicit human request reaches the field.
        let requested = LocalModelManager.diarizerConfiguration(speakerCount: 7)
        #expect(requested.clustering.numSpeakers == 7)
    }

    @Test("chunk embeddings are exposed, because speaker memory needs them")
    func chunkEmbeddingsAreExposedBecauseSpeakerMemoryNeedsThem() async throws {
        #expect(LocalModelManager.diarizerConfiguration(speakerCount: nil).exposeChunkEmbeddings)
    }

    @Test("the run records the configuration that produced it")
    func theRunRecordsTheConfigurationThatProducedIt() async throws {
        let provenance = LocalModelManager.diarizerProvenance(speakerCount: nil)
        #expect(provenance["warmStartFa"] == "0.2")
        #expect(provenance["pipeline"] == "offline-vbx")
        #expect(provenance["numSpeakers"] == nil)
        #expect(LocalModelManager.diarizerProvenance(speakerCount: 5)["numSpeakers"] == "5")
    }

    @Test("the decoder keeps its timings and skips the special tokens")
    func theDecoderKeepsItsTimingsAndSkipsTheSpecialTokens() async throws {
        // The library default leaks <|startoftranscript|> into the text.
        #expect(LocalTranscriptionTuning.skipSpecialTokens)
        // Word timings are what speaker attribution consumes.
        #expect(LocalTranscriptionTuning.wordTimestamps)
        // Prompting improves punctuation and collapses word timings:
        // 198 distinct word starts became 153, 43 with zero duration.
        #expect(!LocalTranscriptionTuning.usesPromptConditioning)
        // VAD chunking was faster and dropped 231 of 9278 words.
        #expect(!LocalTranscriptionTuning.usesVADChunking)
    }

    @Test("the pinned model identifiers are the ones that were measured")
    func thePinnedModelIdentifiersAreTheOnesThatWereMeasured() async throws {
        #expect(LocalSpeechStack.whisperModel == "openai_whisper-large-v3-v20240930_turbo_632MB")
        #expect(LocalSpeechStack.whisperPackage == "argmax-oss-swift 1.1.0")
        #expect(LocalSpeechStack.diarizerPackage == "FluidAudio 0.15.6")
    }
}

@Suite("LocalModelStorage")
struct LocalModelStorageTests {
    @Test("models never land in Documents")
    func modelsNeverLandInDocuments() async throws {
        // WhisperKit's own default is ~/Documents/huggingface, which puts
        // 624 MB where Finder shows it and iCloud Drive syncs it.
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pipit")
        let locations = LocalModelLocations(applicationSupport: support)
        for url in [locations.root, locations.whisperBase, locations.whisperModelFolder,
                    locations.diarizerDirectory, locations.parakeetDirectory,
                    locations.cohereDirectory, locations.alignerDirectory,
                    locations.inventory] {
            #expect(!url.path.contains("/Documents/"), "\(url.path) is inside Documents")
            #expect(
                url.path.contains("Application Support/Pipit"),
                "\(url.path) is outside Pipit's own directory"
            )
        }
    }

    @Test("the whisper model folder matches the layout the library builds")
    func theWhisperModelFolderMatchesTheLayoutTheLibraryBuilds() async throws {
        let locations = LocalModelLocations(
            applicationSupport: URL(fileURLWithPath: "/tmp/pipit-test")
        )
        #expect(
            locations.whisperModelFolder.path == "/tmp/pipit-test/Models/Whisper/models/argmaxinc/whisperkit-coreml/"
                + LocalSpeechStack.whisperModel
        )
    }

    @Test("a fresh directory reports the models as missing rather than usable")
    func aFreshDirectoryReportsTheModelsAsMissingRatherThanUsable() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = LocalModelManager(applicationSupport: root)
        let state = await manager.currentState
        #expect(!state.isUsable)
        #expect(!state.isBusy)
    }

    @Test("a cloud-only configuration still refuses when no models are installed")
    func aCloudOnlyConfigurationStillRefusesWhenNoModelsAreInstalled() async throws {
        // The wiring, not the closure a test hands in: `required(for:)`
        // decides what `ensureInstalled` checks, and when it answered
        // with an empty set for a cloud/cloud machine, ensureInstalled
        // reported success with nothing on disk. Voice memory then
        // reached the embedding extractor and threw from inside the
        // speaker stage, which is not retryable, so the meeting never
        // reached the stage that writes the markdown and the mixdown.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = AppSettings()
        settings.processing.transcription = .openAI
        settings.processing.diarization = .openAI
        let manager = LocalModelManager(
            applicationSupport: root, required: LocalModelUnit.required(for: settings)
        )
        await #expect(
            throws: (any Error).self,
            "a machine with no models must say so, whatever the backends are"
        ) {
            try await manager.ensureInstalled()
        }
        #expect(!(await manager.isInstalled))
    }

    @Test("a unit nobody asked about does not read as a machine with no models")
    func aUnitNobodyAskedAboutDoesNotReadAsAMachineWithNoModels() async throws {
        // `ensureInstalled` used to judge the whole required set, so
        // every unit added to that set turned voice memory off on
        // machines already installed: the new unit has no receipt, the
        // check throws, and `localModelsAvailable` reads that as "no
        // models" for work the new unit has nothing to do with. Voice
        // memory embeds with the diarizer and asks for it by name.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = LocalModelLocations(applicationSupport: root)
        try FileManager.default.createDirectory(
            at: locations.diarizerDirectory, withIntermediateDirectories: true
        )
        try LocalModelReceiptStore(locations: locations).write([
            .diarizer: LocalUnitReceipt(
                revision: LocalSpeechStack.revision(for: .diarizer),
                bytes: 1, installedAt: Date()
            ),
        ])
        let manager = LocalModelManager(
            applicationSupport: root, required: [.diarizer, .voiceActivity]
        )

        try await manager.ensureInstalled(units: [.diarizer])

        await #expect(
            throws: (any Error).self, "the unit that really is missing still says so"
        ) {
            try await manager.ensureInstalled(units: [.voiceActivity])
        }
        await #expect(
            throws: (any Error).self,
            "and so does the set as a whole, which is what the download button reads"
        ) {
            try await manager.ensureInstalled()
        }
    }

    @Test("a receipt from a different pinned revision is not treated as current")
    func aReceiptFromADifferentPinnedRevisionIsNotTreatedAsCurrent() async throws {
        let stale = LocalUnitReceipt(
            revision: "openai_whisper-small @ argmax-oss-swift 0.9.0",
            bytes: 1, installedAt: Date()
        )
        #expect(!stale.matchesCurrentBuild(for: .whisper))

        for unit in LocalModelUnit.allCases {
            let current = LocalUnitReceipt(
                revision: LocalSpeechStack.revision(for: unit),
                bytes: 1, installedAt: Date()
            )
            #expect(current.matchesCurrentBuild(for: unit))
        }
    }

    @Test("a legacy single receipt reads as a whisper and diarizer install")
    func aLegacySingleReceiptReadsAsAWhisperAndDiarizerInstall() async throws {
        // The old installed.json described whisper plus the diarizer;
        // an upgrade must keep reporting them as installed rather than
        // offering the same 650 MB again.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = LocalModelLocations(applicationSupport: root)
        try FileManager.default.createDirectory(
            at: locations.root, withIntermediateDirectories: true
        )
        let legacy = """
            {"whisperVariant": "\(LocalSpeechStack.whisperModel)",
             "whisperFolderPath": "/tmp/nowhere",
             "whisperBytes": 5, "diarizerBytes": 7,
             "installedAt": "2026-01-01T00:00:00Z",
             "whisperPackage": "\(LocalSpeechStack.whisperPackage)",
             "diarizerPackage": "\(LocalSpeechStack.diarizerPackage)"}
            """
        try Data(legacy.utf8).write(to: locations.legacyReceipt)
        let receipts = LocalModelReceiptStore(locations: locations).read()
        #expect(receipts[.whisper]?.bytes == 5)
        #expect(receipts[.diarizer]?.bytes == 7)
        #expect(receipts[.whisper]?.matchesCurrentBuild(for: .whisper) == true)
        #expect(receipts[.whisper]?.detail == "/tmp/nowhere")
    }

    @Test("the new engines and the aligner are pinned like the rest of the stack")
    func theNewEnginesAndTheAlignerArePinnedLikeTheRestOfTheStack() async throws {
        #expect(LocalSpeechStack.parakeetBackendIdentifier == "fluidaudio-parakeet-tdt-v3")
        #expect(
            LocalSpeechStack.cohereBackendIdentifier == "fluidaudio-cohere-transcribe-03-2026-q8"
        )
        #expect(LocalSpeechStack.alignerIdentifier == "fluidaudio-parakeet-ctc-0.6b")
        #expect(
            LocalSpeechStack.revision(for: .cohere) == "cohere-transcribe-03-2026-q8 @ FluidAudio 0.15.6"
        )
        #expect(
            LocalSpeechStack.revision(for: .parakeet) == "parakeet-tdt-0.6b-v3-int8 @ FluidAudio 0.15.6"
        )
        #expect(
            LocalSpeechStack.revision(for: .ctcAligner) == "parakeet-ctc-0.6b @ FluidAudio 0.15.6"
        )

        // Alignment tuning: the aligner's segments feed duplicate
        // detection and attribution, and the chunk length bounds the
        // Viterbi trellis.
        #expect(LocalAlignmentTuning.segmentPauseSeconds == 1.0)
        #expect(LocalAlignmentTuning.segmentMaximumSeconds == 30)
        #expect(LocalAlignmentTuning.chunkSeconds == 300)
        // One model window per Cohere chunk: the library's own window
        // stitching dropped a five-second span on the fixture.
        #expect(LocalCohereTuning.chunkSeconds == 35)
    }

    @Test("the voice database is outside the meeting archive")
    func theVoiceDatabaseIsOutsideTheMeetingArchive() async throws {
        let support = URL(fileURLWithPath: "/tmp/pipit-support")
        let database = SpeakerStoreLocation.url(applicationSupport: support)
        #expect(database.path.hasPrefix("/tmp/pipit-support"))
        #expect(
            !database.path.contains(MeetingArchiveLayout.defaultRoot.path),
            "voice vectors must never live in a folder the user exports"
        )
    }

    @Test("the decoder is built with the settings the numbers came from")
    func theDecoderIsBuiltWithTheSettingsTheNumbersCameFrom() async throws {
        // The options the transcriber actually passes, not the constants
        // beside them: these were literals at the call site, so turning
        // VAD chunking back on left every assertion here green while the
        // measured regression shipped.
        let options = LocalModelManager.decodingOptions()
        #expect(options.skipSpecialTokens, "or <|startoftranscript|> leaks into text")
        #expect(options.wordTimestamps, "speaker attribution consumes them")
        #expect(
            options.chunkingStrategy == nil,
            "VAD chunking dropped 231 of 9278 words over 65 minutes"
        )
        #expect(options.promptTokens == nil)
        #expect(
            !options.usePrefillPrompt,
            "prompting took 198 distinct word starts to 153, 43 of them zero-length"
        )
    }
}
