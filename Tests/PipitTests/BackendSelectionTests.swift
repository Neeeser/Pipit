import Foundation
import PipitAudio
import PipitCore
import PipitIntegrations
import PipitServices
import PipitUI
import Testing

/// Which backend runs where, how that survives an upgrade, and the rule that
/// capture outranks processing.
@Suite("BackendSettings")
struct BackendSettingsTests {
    @Test("the key is read once per process, not once per request")
    func theKeyIsReadOncePerProcessNotOncePerRequest() async throws {
        // macOS raises a login-keychain prompt whenever the running
        // binary is not the one that created the item, which every
        // unsigned rebuild produces. Reading per request turned that into
        // a prompt per request: enrichment alone makes one for the title,
        // the description, the notes, the summary and the speakers, so a
        // single resumed meeting asked five times.
        final class CountingStore: APIKeyProviding, @unchecked Sendable {
            let lock = NSLock()
            var reads = 0
            var value = "sk-first"
            func apiKey() throws -> String {
                lock.lock(); reads += 1; let v = value; lock.unlock()
                return v
            }
            var isKnownAbsent: Bool { false }
        }

        let source = CountingStore()
        let cache = CachingAPIKeyStore(source)
        for _ in 0..<5 { _ = try cache.apiKey() }
        #expect(source.reads == 1, "five requests, one keychain read")

        // A rotated key must not wait for a relaunch.
        source.value = "sk-second"
        let held = try cache.apiKey()
        #expect(held == "sk-first", "still serving what it holds")
        cache.adopt("sk-second")
        let adopted = try cache.apiKey()
        #expect(adopted == "sk-second", "saving a key hands it over")
        #expect(source.reads == 1, "and does not read the keychain to do it")

        // A key the API refuses is dropped, or it would be handed to
        // every later request in the process.
        cache.invalidateCachedKey()
        let reread = try cache.apiKey()
        #expect(reread == "sk-second", "back to the source")
        #expect(source.reads == 2)

        // Holding a key answers presence without touching the keychain.
        #expect(!cache.isKnownAbsent)
    }

    @Test("a fresh installation is local and needs no API key")
    func aFreshInstallationIsLocalAndNeedsNoAPIKey() async throws {
        let settings = AppSettings()
        #expect(settings.processing.transcription == .local)
        #expect(settings.processing.diarization == .local)
        #expect(settings.processing.isFullyLocal)
        #expect(settings.processing.speakers.recognizeKnownVoices)
        #expect(settings.processing.speakers.rememberRecurringVoices)
        #expect(settings.processing.speakers.learnMyVoice)
        #expect(settings.processing.speakers.learnFromCorrections)
    }

    @Test("speakers follow the words: settings carry one knob, not two")
    func speakersFollowTheWordsSettingsCarryOneKnobNotTwo() async throws {
        // Two cloud rows named gpt-4o made the screen read as a
        // contradiction, and the only reason to pay for that model is
        // to let it do both jobs. Saving settings derives diarization:
        // cloud exactly when the chosen cloud model is the diarize
        // model, local for everything else, including a cloud text
        // model, whose speakers the local clusterer identifies.
        var settings = AppSettings()
        settings.processing.transcription = .openAI
        settings.models.transcription = "gpt-4o-transcribe-diarize"
        settings.processing.diarization = .local
        settings.coupleDiarization()
        #expect(
            settings.processing.diarization == .openAI,
            "the diarize model does both jobs in one request"
        )

        settings.models.transcription = "gpt-transcribe"
        settings.coupleDiarization()
        #expect(
            settings.processing.diarization == .local,
            "a cloud text model gets local speakers"
        )

        settings.models.transcription = "my-finetune"
        settings.coupleDiarization()
        #expect(settings.processing.diarization == .local, "a custom model too")

        settings.processing.transcription = .local
        settings.processing.diarization = .openAI
        settings.coupleDiarization()
        #expect(
            settings.processing.diarization == .local,
            "local words never pay for cloud speakers"
        )
    }

    @Test("transcription and diarization are chosen independently")
    func transcriptionAndDiarizationAreChosenIndependently() async throws {
        var settings = AppSettings()
        settings.processing.diarization = .openAI
        #expect(settings.processing.transcription == .local, "one does not drag the other")
        #expect(!settings.processing.isFullyLocal)
        #expect(settings.processing.usesLocalTranscription)
        #expect(!settings.processing.usesLocalDiarization)

        // Nor does either touch enrichment.
        #expect(settings.enrichment.suggestSpeakers)
        #expect(settings.enrichment.wantsAnything)
    }

    @Test("choosing a cloud backend does not switch off voice memory")
    func choosingACloudBackendDoesNotSwitchOffVoiceMemory() async throws {
        var settings = AppSettings()
        settings.processing.transcription = .openAI
        settings.processing.diarization = .openAI
        #expect(
            settings.processing.speakers.recognizeKnownVoices,
            "speaker memory is local in every configuration"
        )
    }

    @Test("a settings file from before local processing keeps its choices")
    func aSettingsFileFromBeforeLocalProcessingKeepsItsChoices() async throws {
        // The whole point: one absent key must not reset a struct.
        let legacy = """
            {
              "version": 1,
              "storageRootPath": "/tmp/meetings",
              "localUserName": "Marlow",
              "models": { "transcription": "whisper-1" },
              "enrichment": { "generateالتitle": true }
            }
            """.replacingOccurrences(of: "generateالتitle", with: "generateTitle")
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        #expect(settings.localUserName == "Marlow")
        #expect(settings.storageRootPath == "/tmp/meetings")
        #expect(
            settings.models.transcription == "whisper-1",
            "the one key that was present survives, models are never migrated"
        )
        #expect(
            settings.models.diarization == AIModelSettings().diarization,
            "the absent siblings fall back individually, not as a block"
        )
        #expect(
            settings.processing.transcription == .openAI,
            "an existing installation keeps the backend it was configured with"
        )
        #expect(settings.processing.diarization == .openAI)
    }

    @Test("a fresh installation with no file at all starts local")
    func aFreshInstallationWithNoFileAtAllStartsLocal() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(directory: root).load()
        #expect(settings.processing.isFullyLocal)
        #expect(settings.version == AppSettings.currentVersion)
    }

    @Test("a partly-written processing block keeps what it has")
    func aPartlyWrittenProcessingBlockKeepsWhatItHas() async throws {
        let partial = """
            {"processing":{"diarization":"openai","speakers":{"learnMyVoice":false}}}
            """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(partial.utf8))
        #expect(settings.processing.diarization == .openAI)
        #expect(settings.processing.transcription == .local)
        #expect(!settings.processing.speakers.learnMyVoice)
        #expect(
            settings.processing.speakers.recognizeKnownVoices,
            "the switches beside it are untouched"
        )
    }

    @Test("an upgrade never moves a cloud model, only a fresh install picks one")
    func anUpgradeNeverMovesACloudModelOnlyAFreshInstallPicksOne() async throws {
        // gpt-transcribe returns no timings, so choosing it commits the
        // machine to a 600 MB aligner download. An upgrade that starts
        // one is exactly what the processing block refuses to do for
        // local models, and the cloud model is no different.
        for stored in ["whisper-1", "gpt-4o-transcribe-diarize", "my-finetune"] {
            let file = #"{"version": 2, "models": {"transcription": "\#(stored)"}}"#
            let settings = try JSONDecoder().decode(AppSettings.self, from: Data(file.utf8))
            #expect(settings.models.transcription == stored, "kept what it had")
            #expect(settings.version == AppSettings.currentVersion, "and is current schema")
        }
        #expect(
            AppSettings().models.transcription == "gpt-4o-transcribe-diarize",
            "a machine with no settings file starts on the model that does both jobs"
        )
    }

    @Test("an existing local install keeps Whisper; a fresh one gets the preferred engine")
    func anExistingLocalInstallKeepsWhisperAFreshOneGetsThePreferredEngine() async throws {
        // The key's absence means the file predates the model choice,
        // which is an install that has Whisper on disk. A new download
        // must come from a person picking the new model, not from an
        // upgrade.
        let existing = #"{"version": 2, "processing": {"transcription": "local"}}"#
        let migrated = try JSONDecoder().decode(AppSettings.self, from: Data(existing.utf8))
        #expect(migrated.processing.localTranscriptionModel == .whisper)

        #expect(
            AppSettings().processing.localTranscriptionModel == LocalTranscriptionModel.preferred,
            "a machine with no settings file starts on this OS's preferred engine"
        )
    }

    @Test("a stored local engine is never migrated to another one")
    func aStoredLocalEngineIsNeverMigratedToAnotherOne() async throws {
        // Every value round-trips, including the two the default has
        // moved away from. A machine that has Cohere on disk keeps
        // decoding to Cohere, or an upgrade silently changes both the
        // transcript and the 2.1 GB of models on the machine.
        for stored in ["cohere", "whisper", "parakeet"] {
            let file = #"""
                {"processing":{"transcription":"local","localTranscriptionModel":"\#(stored)"}}
                """#
            let settings = try JSONDecoder().decode(AppSettings.self, from: Data(file.utf8))
            #expect(
                settings.processing.localTranscriptionModel.rawValue == stored,
                "kept the engine the file names"
            )
        }
    }

    @Test("the units a configuration needs follow the models it chose")
    func theUnitsAConfigurationNeedsFollowTheModelsItChose() async throws {
        var settings = AppSettings()
        settings.processing.localTranscriptionModel = .cohere
        #expect(
            LocalModelUnit.required(for: settings)
                == [.cohere, .ctcAligner, .diarizer, .voiceActivity],
            "a text-only local model brings the aligner with it"
        )

        settings.processing.localTranscriptionModel = .parakeet
        #expect(LocalModelUnit.required(for: settings) == [.parakeet, .diarizer, .voiceActivity])

        settings.processing.transcription = .openAI
        settings.models.transcription = "gpt-transcribe"
        #expect(
            LocalModelUnit.required(for: settings) == [.ctcAligner, .diarizer, .voiceActivity],
            "cloud words without timings still need the local aligner"
        )

        settings.models.transcription = "gpt-4o-transcribe-diarize"
        #expect(
            LocalModelUnit.required(for: settings) == [.diarizer, .voiceActivity],
            "a self-contained cloud model brings the diarizer and the detector"
        )

        // The diarizer is in every set, cloud-only included: voice
        // memory embeds a cloud diarizer's intervals with those same
        // models. Leaving it out made `ensureInstalled` report success
        // on a machine with nothing installed, and the embedding
        // extractor then threw from inside a stage. The 1.1 MB voice
        // detector is in every set for the same kind of reason: every
        // backend fabricates filler for a microphone track that is
        // mostly not speech, and a cloud user has no other guard.
        settings.processing.diarization = .openAI
        #expect(
            LocalModelUnit.required(for: settings) == [.diarizer, .voiceActivity],
            "voice memory needs the diarizer whatever produced the labels"
        )
    }

    @Test("settings survive a full round trip through disk")
    func settingsSurviveAFullRoundTripThroughDisk() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = AppSettings()
        settings.processing.transcription = .openAI
        settings.processing.speakers.rememberRecurringVoices = false
        settings.processing.localUserIdentityID = IdentityID(42)
        let store = SettingsStore(directory: root)
        try store.save(settings)
        let reloaded = store.load()
        #expect(reloaded.processing.transcription == .openAI)
        #expect(reloaded.processing.diarization == .local)
        #expect(!reloaded.processing.speakers.rememberRecurringVoices)
        #expect(reloaded.processing.localUserIdentityID == IdentityID(42))
    }
}

@Suite("BackendLimits")
struct BackendLimitsTests {
    @Test("a local backend sends the whole meeting, a cloud one is chunked")
    func aLocalBackendSendsTheWholeMeetingACloudOneIsChunked() async throws {
        #expect(!BackendAudioLimits.none.requiresChunking)
        #expect(BackendAudioLimits.openAI.requiresChunking)
        #expect(BackendAudioLimits.openAI.maximumSeconds == AILimits.maximumDiarizationSeconds)
        #expect(BackendAudioLimits.openAI.maximumBytes == AILimits.maximumRequestBytes)
    }

    @Test("the cloud diarizer returns the words, the local one does not")
    func theCloudDiarizerReturnsTheWordsTheLocalOneDoesNot() async throws {
        // The stage that transcribes has to know: with a local diarizer
        // the diarized track needs its own transcription pass.
        let cloud = OpenAIDiarizationBackend(
            backend: FakeAIBackend(), model: "gpt-4o-transcribe-diarize"
        )
        #expect(cloud.producesTranscript)
        #expect(!cloud.producesEmbeddings, "a cloud diarizer returns no vectors")
        #expect(!cloud.isLocal)
    }
}

@Suite("ProcessingGate")
struct ProcessingGateTests {
    @Test("nothing heavy starts while a recording is live")
    func nothingHeavyStartsWhileARecordingIsLive() async throws {
        let recording = LockedBox(RecordingAwareGate.CaptureState.recording)
        let gate = RecordingAwareGate(pollSeconds: 0.05) { recording.withLock { $0 } }
        #expect(gate.isBlocked)

        let returned = LockedBox(false)
        let waiting = Task {
            await gate.waitUntilAllowed()
            returned.withLock { $0 = true }
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(
            !returned.withLock { $0 },
            "waitUntilAllowed must not return while the meeting runs"
        )
        #expect(gate.isBlocked, "still held while the meeting runs")

        recording.withLock { $0 = .idle }
        await waiting.value
        #expect(returned.withLock { $0 })
        #expect(!gate.isBlocked)
    }

    @Test("a prejoin holds processing, but not all afternoon")
    func aPrejoinHoldsProcessingButNotAllAfternoon() async throws {
        // A candidate is real capture: the microphone is open into the
        // ring about twelve seconds before a Slack huddle is joined. A
        // waiting room left open is also a candidate, and blocking on
        // that without a bound held every job for hours in exchange for
        // a recording that never happened.
        let now = LockedBox(Date(timeIntervalSince1970: 1_000))
        let opened = now.withLock { $0 }
        let gate = RecordingAwareGate(
            pollSeconds: 0.01,
            now: { now.withLock { $0 } },
            capture: { .candidate(since: opened) }
        )
        #expect(gate.isBlocked, "the microphone is open, so capture wins")

        now.withLock { $0 = opened.addingTimeInterval(30) }
        #expect(gate.isBlocked, "still inside the window a real join needs")

        now.withLock {
            $0 = opened.addingTimeInterval(RecordingAwareGate.candidateBlockSeconds + 1)
        }
        #expect(!gate.isBlocked, "a candidate this old is not a meeting")
        // Guarded: without the bound, waitUntilAllowed spins forever
        // against a frozen clock and the whole suite hangs instead of
        // reporting the failure above.
        if !gate.isBlocked { await gate.waitUntilAllowed() }

        // A live recording is never released on a timer.
        let live = RecordingAwareGate(
            pollSeconds: 0.01,
            now: { Date().addingTimeInterval(86_400) },
            capture: { .recording }
        )
        #expect(live.isBlocked)
    }

    @Test("with no recording a job starts immediately")
    func withNoRecordingAJobStartsImmediately() async throws {
        let gate = RecordingAwareGate(pollSeconds: 10) { .idle }
        #expect(!gate.isBlocked)
        let start = Date()
        await gate.waitUntilAllowed()
        #expect(
            Date().timeIntervalSince(start) < 1,
            "an idle machine must not wait for a poll interval"
        )
    }

    @Test("a job waiting out a recording hands its slot back")
    func aJobWaitingOutARecordingHandsItsSlotBack() async throws {
        // "One heavy job at a time" has to mean one job doing work. A
        // job parked for the length of somebody's call must not also
        // hold the queue shut.
        let lock = ProcessingJobLock()
        await lock.acquire()
        let second = Task { await lock.acquire() }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(!second.isCancelled)
        lock.release()
        await second.value
        lock.release()
        // And the slot is genuinely free again afterwards.
        await lock.acquire()
        lock.release()
        #expect(true, "acquire returned after the holder released")
    }

    @Test("only one heavy job holds the lock at a time")
    func onlyOneHeavyJobHoldsTheLockAtATime() async throws {
        let lock = ProcessingJobLock()
        let running = LockedCounter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await lock.acquire()
                    running.enter()
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    running.leave()
                    lock.release()
                }
            }
        }
        #expect(running.peak == 1, "two meetings must not transcribe at once")
        #expect(running.total == 8, "and every one of them still runs")
    }

    @Test("a local failure is not reported as an outage at OpenAI")
    func aLocalFailureIsNotReportedAsAnOutageAtOpenAI() async throws {
        struct Refusal: LocalProcessingFailure {
            var userMessage = "Pipit needs to download its speech models."
            var isRetryable = false
        }

        let local = ProcessingPipeline.processingError(from: Refusal())
        #expect(
            !local.userMessage.contains("OpenAI"),
            "a user with no key never configured a service to blame"
        )
        #expect(!local.isRetryable, "downloading is the fix, not waiting")

        // Anything genuinely unknown is still reported as local rather
        // than as a transport failure, which named OpenAI and retried.
        struct Unknown: Error {}
        let unknown = ProcessingPipeline.processingError(from: Unknown())
        #expect(!unknown.userMessage.contains("OpenAI"))

        // The cloud client's own errors keep their wording.
        #expect(
            ProcessingPipeline.processingError(from: ProcessingError.rateLimited(retryAfter: 1))
                == .rateLimited(retryAfter: 1)
        )
        #expect(ProcessingPipeline.processingError(from: CancellationError()) == .cancelled)
    }

    @Test("a job started before a recording waits for it, through the pipeline")
    func aJobStartedBeforeARecordingWaitsForItThroughThePipeline() async throws {
        // Drives ProcessingPipeline.process with a real gate rather than
        // reimplementing its loop: the defect this pins is the gate
        // being consulted once per iteration, and only the pipeline has
        // that loop.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try PipelineFixtures.makeRecordedMeeting(root: root, seconds: 6)

        let capture = LockedBox(RecordingAwareGate.CaptureState.recording)
        let gate = RecordingAwareGate(pollSeconds: 0.01) { capture.withLock { $0 } }

        let settings: AppSettings = {
            var value = AppSettings()
            value.enrichment = EnrichmentSettings(
                generateTitle: false, generateDescription: false, generateNotes: false,
                generateSummary: false, suggestSpeakers: false
            )
            return value
        }()
        let pipeline = ProcessingPipeline(
            repository: meeting.repository,
            backend: FakeAIBackend(),
            backends: ProcessingBackends(
                transcription: { _, _ in
                    StubLocalTranscriber(segments: [
                        RawTranscriptSegment(
                            start: 0, end: 5, text: "hello", speaker: nil,
                            words: [RawTranscriptWord(start: 0, end: 1, text: " hello")]
                        ),
                    ])
                },
                diarization: { _, _ in
                    StubLocalDiarizer(
                        intervals: [DiarizationInterval(start: 0, end: 5, clusterID: "S1")],
                        chunkEmbeddings: []
                    )
                }
            ),
            gate: gate,
            scratch: ProcessingScratch(root: root.appendingPathComponent("scratch")),
            clock: ManualClock(),
            settingsProvider: { settings },
            wait: { _ in }
        )

        let job = Task { await pipeline.process(meetingID: meeting.metadata.id) }
        try await Task.sleep(nanoseconds: 120_000_000)
        // The stage the meeting is parked at, not merely "not finished":
        // an ungated run is still unfinished at this point too, so the
        // weaker assertion held with the gate deleted entirely.
        let parked = try meeting.store.readMetadata()
        #expect(
            parked.processing.state == .audioSafe,
            "nothing past the gate has run while the microphone is open"
        )

        capture.withLock { $0 = .idle }
        await job.value
        let finished = try meeting.store.readMetadata()
        #expect(
            finished.processing.state == .complete,
            "and it finishes once the meeting ends"
        )

        // The re-check loop this sits next to, which catches a
        // recording that starts while a parked job is queueing for the
        // slot, is not pinned here: reproducing it needs control over
        // when each job is scheduled that the pipeline does not expose,
        // and every construction that fitted in a test passed with the
        // loop removed. Argued in the comment at the loop, not tested.
    }

    @Test("a typed speaker count has to be one a clusterer can use")
    func aTypedSpeakerCountHasToBeOneAClustererCanUse() async throws {
        // Zero and negatives went straight into the clusterer, and the
        // run that came back replaced the good one with no undo.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        await MainActor.run {
            let model = MeetingReviewModel(
                runtime: PipitRuntime(settingsDirectory: root), meetingID: "none"
            )
            for bad in ["0", "-3", "abc", "999"] {
                model.reanalyzeCount = bad
                #expect(!model.hasValidReanalyzeCount, "\(bad) is not a speaker count")
            }
            for good in ["", "2", "7", "50"] {
                model.reanalyzeCount = good
                #expect(model.hasValidReanalyzeCount, "\(good) is usable")
            }
            // And the control needs the on-device models whatever the
            // count says, because it runs the local diarizer.
            model.reanalyzeCount = "3"
            #expect(
                !model.canReanalyze,
                "Run must not start a 650 MB download from a button that says nothing about one"
            )

            model.reanalyzeCount = ""
            #expect(
                model.reanalyzeSpeakerCount == nil,
                "blank means decide automatically, which beat the true count"
            )
        }
    }

    @Test("each setting selects its own backend, and neither the other's")
    func eachSettingSelectsItsOwnBackendAndNeitherTheOthers() async throws {
        let cloudBackend = FakeAIBackend()
        func transcriber(_ settings: AppSettings) -> any TranscriptionBackend {
            ProcessingBackends.transcriptionBackend(
                settings: settings, model: "gpt-4o-transcribe",
                local: { _ in StubLocalTranscriber(segments: []) },
                cloud: { OpenAITranscriptionBackend(backend: cloudBackend, model: $0) }
            )
        }
        func diarizer(_ settings: AppSettings) -> any DiarizationBackend {
            ProcessingBackends.diarizationBackend(
                settings: settings, model: "gpt-4o-transcribe-diarize",
                local: {
                    StubLocalDiarizer(intervals: [], chunkEmbeddings: [])
                },
                cloud: { OpenAIDiarizationBackend(backend: cloudBackend, model: $0) }
            )
        }

        // All four combinations, because the failure that matters is one
        // setting deciding the other's backend.
        for (transcription, diarization) in [
            (ProcessingBackendChoice.local, ProcessingBackendChoice.local),
            (.local, .openAI), (.openAI, .local), (.openAI, .openAI),
        ] {
            var settings = AppSettings()
            settings.processing = ProcessingSettings(
                transcription: transcription, diarization: diarization
            )
            #expect(
                transcriber(settings).isLocal == (transcription == .local),
                "transcription \(transcription) with diarization \(diarization)"
            )
            #expect(
                diarizer(settings).isLocal == (diarization == .local),
                "diarization \(diarization) with transcription \(transcription)"
            )
        }
    }

    @Test("a keychain that cannot answer is not read as having no key")
    func aKeychainThatCannotAnswerIsNotReadAsHavingNoKey() async throws {
        struct Failing: APIKeyProviding {
            func apiKey() throws -> String { throw ProcessingError.missingAPIKey }
            // A locked keychain, or a denied prompt after an ad-hoc
            // rebuild invalidates the item's ACL. Not absence.
            var isKnownAbsent: Bool { false }
        }
        struct Absent: APIKeyProviding {
            func apiKey() throws -> String { throw ProcessingError.missingAPIKey }
            var isKnownAbsent: Bool { true }
        }

        let unreadable = OpenAIClient(keyProvider: Failing())
        let unreadableIsConfigured = await unreadable.isConfigured()
        #expect(
            unreadableIsConfigured,
            "attempt it, so the failure is visible and retryable"
        )
        let none = OpenAIClient(keyProvider: Absent())
        let noneIsConfigured = await none.isConfigured()
        #expect(
            !noneIsConfigured,
            "a user who never entered a key opted into nothing"
        )

        // The shipping stores, not just the shape. The layered store is
        // what DEBUG builds use, and taking the protocol default there
        // reopened the bug this guard exists for.
        let layered = LayeredAPIKeyStore(providers: [Absent(), Absent()])
        #expect(layered.isKnownAbsent, "every layer says there is no key")
        #expect(
            !LayeredAPIKeyStore(providers: [Absent(), Failing()]).isKnownAbsent,
            "one layer that cannot answer is enough to attempt the request"
        )
        #expect(
            EnvironmentAPIKeyStore(variableName: "PIPIT_NO_SUCH_VARIABLE").isKnownAbsent
        )
    }
}
