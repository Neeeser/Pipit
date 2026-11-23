import AVFoundation
import CoreML
import FluidAudio
import Foundation
import PipitAudio
import PipitCore
import PipitSpeakers
import Synchronization
import Testing

@testable import PipitLocalAI
@testable import PipitServices

/// The local diarizer a finished meeting gets: Nemotron 3, with the offline
/// clusterer behind it where Nemotron cannot do the job.
@Suite("LocalDiarizationBackend")
struct LocalDiarizationBackendTests {
    private struct StubDiarizer: DiarizationBackend {
        var identifier: String
        var result: Result<DiarizationOutput, any Error>
        var progressSteps: [Double] = [1]
        var isLocal: Bool { true }
        var limits: BackendAudioLimits { .none }
        var producesEmbeddings: Bool { false }
        var producesTranscript: Bool { false }

        func diarize(
            audio: URL, progress: @escaping @Sendable (Double) -> Void
        ) async throws -> DiarizationOutput {
            for step in progressSteps { progress(step) }
            return try result.get()
        }
    }

    private struct Unrelated: Error {}

    private static func output(
        speakers: Int, configuration: [String: String] = [:]
    ) -> DiarizationOutput {
        let intervals = (0..<speakers).map {
            DiarizationInterval(
                start: Double($0) * 3, end: Double($0) * 3 + 2, clusterID: "S\($0)")
        }
        return DiarizationOutput(
            intervals: intervals,
            clusters: intervals.map {
                DiarizationCluster(id: $0.clusterID, speechSeconds: $0.duration)
            },
            configuration: configuration
        )
    }

    private static func backend(
        primary: Result<DiarizationOutput, any Error>,
        primarySteps: [Double] = [1], fallbackSteps: [Double] = [1]
    ) -> LocalDiarizationBackend {
        LocalDiarizationBackend(
            primary: StubDiarizer(identifier: "primary", result: primary, progressSteps: primarySteps),
            fallback: StubDiarizer(
                identifier: "fallback",
                result: .success(Self.output(speakers: 12, configuration: ["diarizer": "vbx"])),
                progressSteps: fallbackSteps
            )
        )
    }

    private static let audio = URL(fileURLWithPath: "/nonexistent.wav")

    // MARK: choosing between the two models

    @Test("a meeting within Nemotron's limits keeps Nemotron's answer")
    func aMeetingWithinNemotronsLimitsKeepsNemotronsAnswer() async throws {
        let result = try await Self.backend(primary: .success(Self.output(speakers: 3)))
            .diarize(audio: Self.audio, progress: { _ in })
        #expect(result.clusters.count == 3)
        #expect(result.configuration["diarizerReason"] == "preferred")
        #expect(result.configuration["diarizer"] == nil, "the stub names no diarizer of its own")
    }

    @Test("a meeting that fills every speaker slot keeps Nemotron's answer")
    func aMeetingThatFillsEverySlotKeepsNemotronsAnswer() async throws {
        // Nemotron usually merges voices and reports fewer than eight when a
        // meeting has more people, and its count was right on a real
        // eight-person meeting, so a full set of slots is not a reason to
        // switch to the clusterer, which over-counts.
        let slots = LocalSpeechStack.nemotron3SpeakerSlots
        let result = try await Self.backend(primary: .success(Self.output(speakers: slots)))
            .diarize(audio: Self.audio, progress: { _ in })
        #expect(result.clusters.count == slots)
        #expect(result.configuration["diarizerReason"] == "preferred")
        #expect(result.configuration["diarizer"] == nil, "the clusterer was not called")
    }

    @Test("a machine without the Nemotron files uses the clusterer")
    func aMachineWithoutTheNemotronFilesUsesTheClusterer() async throws {
        let result = try await Self.backend(primary: .failure(LocalModelError.notInstalled))
            .diarize(audio: Self.audio, progress: { _ in })
        #expect(result.configuration["diarizer"] == "vbx")
        #expect(result.configuration["diarizerReason"] == "modelNotInstalled")
    }

    @Test("a Nemotron failure uses the clusterer and says so")
    func aNemotronFailureUsesTheClustererAndSaysSo() async throws {
        let result = try await Self.backend(primary: .failure(Unrelated()))
            .diarize(audio: Self.audio, progress: { _ in })
        #expect(result.configuration["diarizer"] == "vbx")
        #expect(result.configuration["diarizerReason"] == "modelFailed")
    }

    @Test("an empty answer for audible audio uses the clusterer, and for silence it stands")
    func anEmptyAnswerForAudibleAudioUsesTheClusterer() async throws {
        let empty = try await Self.backend(primary: .success(Self.output(speakers: 0)))
            .diarize(audio: Self.audio, progress: { _ in })
        #expect(empty.configuration["diarizer"] == "vbx")
        #expect(empty.configuration["diarizerReason"] == "modelFailed")

        let silent = try await Self.backend(
            primary: .success(Self.output(speakers: 0, configuration: ["silentAudio": "true"]))
        ).diarize(audio: Self.audio, progress: { _ in })
        #expect(silent.clusters.isEmpty, "nobody spoke, and the empty answer is the right one")
        #expect(silent.configuration["diarizerReason"] == "preferred")
    }

    @Test("an audio decode failure fails the stage instead of running the clusterer")
    func anAudioDecodeFailureFailsTheStage() async throws {
        await #expect(throws: ProcessingError.self) {
            _ = try await Self.backend(
                primary: .failure(ProcessingError.audioUnreadable(path: "meeting.wav"))
            ).diarize(audio: Self.audio, progress: { _ in })
        }
        await #expect(throws: LocalModelError.self) {
            _ = try await Self.backend(primary: .failure(LocalModelError.audioUnreadable("meeting.wav")))
                .diarize(audio: Self.audio, progress: { _ in })
        }
    }

    @Test("progress keeps rising when the clusterer takes over")
    func progressKeepsRisingWhenTheClustererTakesOver() async throws {
        let seen = Mutex<[Double]>([])
        _ = try await Self.backend(
            primary: .failure(Unrelated()), primarySteps: [0.2, 0.6, 1],
            fallbackSteps: [0, 0.4, 1]
        ).diarize(audio: Self.audio, progress: { value in seen.withLock { $0.append(value) } })
        let values = seen.withLock { $0 }
        #expect(values == values.sorted(), "never goes back: \(values)")
        #expect(values.last == 1)

        let direct = Mutex<[Double]>([])
        _ = try await Self.backend(primary: .success(Self.output(speakers: 2)), primarySteps: [0.3, 1])
            .diarize(audio: Self.audio, progress: { value in direct.withLock { $0.append(value) } })
        #expect(direct.withLock { $0 }.last == 1, "a finished Nemotron run reaches the end")
    }

    @Test("a rejected Nemotron answer leaves the clusterer room to fill")
    func aRejectedAnswerLeavesRoom() async throws {
        let seen = Mutex<[Double]>([])
        _ = try await Self.backend(
            primary: .success(Self.output(speakers: 8)), primarySteps: [0.5, 1], fallbackSteps: [0, 0.5, 1]
        ).diarize(audio: Self.audio, progress: { value in seen.withLock { $0.append(value) } })
        let values = seen.withLock { $0 }
        #expect(values == values.sorted(), "never goes back: \(values)")
        #expect(values.prefix(2).allSatisfy { $0 < 1 }, "Nemotron alone never fills the bar: \(values)")
        #expect(Set(values.dropFirst(2)).count == 3, "the clusterer moves the bar: \(values)")
        #expect(values.last == 1)
    }

    @Test("cancelling the job does not start the clusterer")
    func cancellingTheJobDoesNotStartTheClusterer() async throws {
        await #expect(throws: CancellationError.self) {
            _ = try await Self.backend(primary: .failure(CancellationError()))
                .diarize(audio: Self.audio, progress: { _ in })
        }
    }

    @Test("a typed speaker count is recorded as the reason the clusterer ran")
    func aTypedSpeakerCountIsRecordedAsTheReasonTheClustererRan() {
        let counted = LocalModelManager.diarizerProvenance(speakerCount: 4)
        #expect(counted["diarizer"] == "vbx")
        #expect(counted["diarizerReason"] == "speakerCountRequested")
        #expect(counted["numSpeakers"] == "4")

        let automatic = LocalModelManager.diarizerProvenance(speakerCount: nil)
        #expect(automatic["diarizer"] == "vbx")
        #expect(automatic["diarizerReason"] == nil)
    }

    @Test("the clusterer's re-cluster cache is still keyed by the meeting")
    func theClusterersCacheIsStillKeyedByTheMeeting() async throws {
        // The clusterer's cached segmentation is what makes a second typed
        // count take about a second, so the re-analysis entry that serves an
        // automatic count must hand the meeting's key to its fallback.
        let manager = LocalModelManager(applicationSupport: URL(fileURLWithPath: "/nonexistent"))
        let keyed = LocalDiarizationBackend(models: manager, cacheKey: "meeting")
        #expect(keyed.identifier == Nemotron3DiarizationBackend(models: manager).identifier)
        #expect(!keyed.producesEmbeddings)
        let reanalyzed = await manager.hasPreparedDiarization(cacheKey: "meeting")
        #expect(!reanalyzed, "nothing is cached until the clusterer has run")
    }

    // MARK: the model's own guards

    @Test("Nemotron runs on the CPU and Neural Engine, never the GPU")
    func nemotronRunsOnTheCPUAndNeuralEngine() {
        #expect(LocalModelManager.nemotron3ComputeUnits == .cpuAndNeuralEngine)
    }

    @Test("empty and near-silent audio never reaches the model")
    func emptyAndNearSilentAudioNeverReachesTheModel() {
        #expect(Self.isSilent([]))
        #expect(Self.isSilent([Float](repeating: 0.5, count: 100)))
        #expect(Self.isSilent([Float](repeating: 0, count: 160_000)))
        #expect(Self.isSilent([Float](repeating: 5e-5, count: 160_000)))
        #expect(!Self.isSilent([Float](repeating: 0.01, count: 160_000)))

        var burst = [Float](repeating: 0, count: 160_000)
        burst[150_000] = 0.2
        #expect(!Self.isSilent(burst), "one audible sample is speech enough to look")
    }

    /// The silence check's answer for samples already in memory.
    private static func isSilent(_ samples: [Float]) -> Bool {
        var probe = Nemotron3DiarizationBackend.SilenceProbe()
        _ = probe.add(samples)
        return probe.isSilent
    }

    @Test("the silence check on a file stops reading once it hears sound")
    func theSilenceCheckOnAFileStopsReadingOnceItHearsSound() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let quiet = root.appendingPathComponent("quiet.wav")
        try Self.writeWave([Float](repeating: 5e-5, count: 160_000), to: quiet)
        let short = root.appendingPathComponent("short.wav")
        try Self.writeWave([Float](repeating: 0.5, count: 100), to: short)
        let lateBurst = root.appendingPathComponent("late.wav")
        var late = [Float](repeating: 0, count: 600_000)
        late[590_000] = 0.2
        try Self.writeWave(late, to: lateBurst)
        let loud = root.appendingPathComponent("loud.wav")
        try Self.writeWave([Float](repeating: 0.01, count: 1_600_000), to: loud)

        #expect(try Nemotron3DiarizationBackend.isEffectivelySilent(audio: quiet).silent)
        #expect(try Nemotron3DiarizationBackend.isEffectivelySilent(audio: short).silent)
        #expect(try !Nemotron3DiarizationBackend.isEffectivelySilent(audio: lateBurst).silent)

        // A meeting is loud from its first seconds, so the check costs one block
        // of decoding however long the file is. A block is one converter
        // buffer: 65,536 input frames plus 4,096 of headroom at 16 kHz.
        let check = try Nemotron3DiarizationBackend.isEffectivelySilent(audio: loud)
        #expect(!check.silent)
        #expect(check.samplesRead <= 69_632, "read \(check.samplesRead) of 1,600,000 samples")
        let lateCheck = try Nemotron3DiarizationBackend.isEffectivelySilent(audio: lateBurst)
        #expect(lateCheck.samplesRead == 600_000, "a file quiet until its end is read to its end")
    }

    @Test("a silent file gives an empty diarization without loading anything")
    func aSilentFileGivesAnEmptyDiarizationWithoutLoadingAnything() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let silent = root.appendingPathComponent("silent.wav")
        try Self.writeWave([Float](repeating: 0, count: 32_000), to: silent)

        // Files for the offline preset are present, but empty: if the guard let
        // the audio through, loading them would throw.
        let manager = LocalModelManager(applicationSupport: root)
        try Self.fakeInstall(in: manager.locations.nemotronDiarizerDirectory)
        let output = try await Nemotron3DiarizationBackend(models: manager).diarize(
            audio: silent, progress: { _ in })
        #expect(output.intervals.isEmpty && output.clusters.isEmpty)
        #expect(output.configuration["silentAudio"] == "true")
        #expect(output.configuration["diarizer"] == "nemotron3")
    }

    @Test("a cancelled job stops before it reads or loads anything", .timeLimit(.minutes(1)))
    func aCancelledJobStopsBeforeItReadsOrLoadsAnything() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = LocalModelManager(applicationSupport: root)
        let task = Task {
            // Bounded, so a missing cancellation check fails instead of hanging.
            let deadline = ContinuousClock.now + .seconds(5)
            while !Task.isCancelled, ContinuousClock.now < deadline { await Task.yield() }
            return try await Nemotron3DiarizationBackend(models: manager).diarize(
                audio: Self.audio, progress: { _ in })
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    // MARK: the run queue

    @Test("two Nemotron runs never overlap", .timeLimit(.minutes(1)))
    func twoNemotronRunsNeverOverlap() async throws {
        let queue = Nemotron3RunQueue()
        // LockedBox rather than Mutex: these cross into escaping task closures,
        // which the Swift 6.3 compiler CI uses rejects for a noncopyable Mutex.
        let running = LockedBox(0)
        let overlapped = LockedBox(false)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await queue.run {
                        let now = running.withLock { count -> Int in
                            count += 1
                            return count
                        }
                        if now > 1 { overlapped.withLock { $0 = true } }
                        try await Task.sleep(for: .milliseconds(40))
                        running.withLock { $0 -= 1 }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(!overlapped.withLock { $0 })
    }

    @Test("cancelling the caller cancels the running job, and a queued one never starts", .timeLimit(.minutes(1)))
    func cancellingTheCallerCancelsTheRunningJob() async throws {
        let queue = Nemotron3RunQueue()
        let started = LockedBox(0)
        let sawCancel = LockedBox(false)
        let first = Task {
            try await queue.run {
                started.withLock { $0 += 1 }
                // Bounded, so cancellation that never arrives fails the test.
                let deadline = ContinuousClock.now + .seconds(3)
                while !Task.isCancelled, ContinuousClock.now < deadline {
                    // A cancelled sleep throws, which is also the job seeing it.
                    try? await Task.sleep(for: .milliseconds(5))
                }
                sawCancel.withLock { $0 = Task.isCancelled }
                try Task.checkCancellation()
            }
        }
        // The second job is made only once the first holds the queue: tasks start
        // in no fixed order, and a second job that reached the queue first would
        // run to the end before anything is cancelled.
        let giveUp = ContinuousClock.now + .seconds(3)
        while started.withLock({ $0 }) == 0, ContinuousClock.now < giveUp {
            try await Task.sleep(for: .milliseconds(5))
        }
        let second = Task {
            try await queue.run { started.withLock { $0 += 1 } }
        }
        // Long enough for it to wait in the queue; if it has not arrived yet, a
        // cancelled job still never starts, so the expectations hold either way.
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()
        second.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(sawCancel.withLock { $0 }, "the job itself saw the cancellation")
        #expect(started.withLock { $0 } == 1, "the queued job never began")
    }

    @Test("the offline preset is never downloaded from inside a diarization")
    func theOfflinePresetIsNeverDownloadedFromInsideADiarization() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = LocalModelManager(applicationSupport: root)
        await #expect(throws: LocalModelError.self) {
            _ = try await Nemotron3DiarizationBackend(models: manager).diarize(
                audio: Self.audio, progress: { _ in })
        }
        #expect(
            !FileManager.default.fileExists(atPath: manager.locations.nemotronDiarizerDirectory.path),
            "nothing was fetched or created")
    }

    // MARK: installation

    @Test("Nemotron's files are present only for the checkpoint this build expects")
    func nemotronsFilesArePresentOnlyForTheCheckpointThisBuildExpects() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("repo")
        #expect(!LocalModelManager.nemotron3FilesPresent(.offline, directory: directory))

        try Self.fakeInstall(in: directory)
        #expect(LocalModelManager.nemotron3FilesPresent(.offline, directory: directory))
        #expect(
            !LocalModelManager.nemotron3FilesPresent(.fast128, directory: directory),
            "another preset's bundle is a different folder")

        try "an-older-checkpoint\n".write(
            to: directory.appendingPathComponent(ModelNames.Nemotron3.weightsVersionFile),
            atomically: true, encoding: .utf8)
        #expect(
            !LocalModelManager.nemotron3FilesPresent(.offline, directory: directory),
            "a cache from another checkpoint would make FluidAudio delete it and download again")
    }

    @Test("the pinned checkpoint name is the one FluidAudio checks")
    func thePinnedCheckpointNameIsTheOneFluidAudioChecks() {
        #expect(LocalSpeechStack.nemotron3WeightsVersion == ModelNames.Nemotron3.weightsVersion)
        #expect(LocalSpeechStack.nemotron3SpeakerSlots == Nemotron3Config.offline.numSpeakers)
    }

    @Test("setup installs the Nemotron unit for local diarization and not for a cloud diarizer")
    func setupInstallsTheNemotronUnitForLocalDiarizationAndNotForACloudDiarizer() {
        var settings = AppSettings()
        settings.processing.diarization = .local
        #expect(LocalModelUnit.recommended(for: settings).contains(.nemotronDiarizer))
        #expect(
            !LocalModelUnit.required(for: settings).contains(.nemotronDiarizer),
            "a machine without it diarizes with the clusterer instead of downloading 190 MB mid-meeting")
        #expect(
            LocalModelUnit.required(for: settings).contains(.diarizer),
            "voice memory embeds with the clusterer's models")

        settings.processing.diarization = .openAI
        #expect(!LocalModelUnit.recommended(for: settings).contains(.nemotronDiarizer))
        #expect(LocalModelUnit.recommended(for: settings).contains(.diarizer))
    }

    @Test("the unit's size is the model hub's, and its revision names the checkpoint")
    func theUnitsSizeIsTheModelHubsAndItsRevisionNamesTheCheckpoint() {
        // 199,160,355 bytes of bundle plus the 2,048-byte silence embedding.
        let hub: Int64 = 199_162_403
        let size = LocalModelUnit.nemotronDiarizer.approximateBytes
        #expect(size >= hub, "an estimate that is low shows a smaller download than the real one")
        #expect(size - hub < 2 * 1_024 * 1_024, "and one that is far above misleads the other way")
        #expect(
            LocalSpeechStack.revision(for: .nemotronDiarizer).contains(
                LocalSpeechStack.nemotron3WeightsVersion))
        #expect(LocalModelUnit(rawValue: "nemotron-diarizer") == .nemotronDiarizer)
    }

    @Test("an install of the Nemotron unit leaves a state that reads as installed")
    func theUnitIsJudgedOnItsFilesOnDisk() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = LocalModelManager(applicationSupport: root, required: [.nemotronDiarizer])
        await #expect(throws: LocalModelError.self) {
            try await manager.ensureInstalled(units: [.nemotronDiarizer])
        }
        try Self.fakeInstall(in: manager.locations.nemotronDiarizerDirectory)
        try await manager.ensureInstalled(units: [.nemotronDiarizer])
    }

    // MARK: voice memory

    /// Marks the files the presence check reads, with nothing a model could load.
    private static func fakeInstall(in directory: URL) throws {
        let config = Nemotron3Config.offline
        let bundle = directory.appendingPathComponent(
            "\(config.hubSubdirectory)/\(config.modelFileName)")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data([0]).write(to: bundle.appendingPathComponent("coremldata.bin"))
        try Data([0]).write(
            to: directory.appendingPathComponent(ModelNames.Nemotron3.silenceEmbeddingFile))
        try (ModelNames.Nemotron3.weightsVersion + "\n").write(
            to: directory.appendingPathComponent(ModelNames.Nemotron3.weightsVersionFile),
            atomically: true, encoding: .utf8)
    }

    private static func writeWave(_ samples: [Float], to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    /// Records what the pipeline asked the extractor to embed.
    private final class RecordingExtractor: SpeakerEmbeddingExtractor, @unchecked Sendable {
        private let asked = Mutex<[[DiarizationInterval]]>([])
        var model: EmbeddingModelIdentifier { .fluidAudioOffline }
        var requests: [[DiarizationInterval]] { asked.withLock { $0 } }

        func embed(
            audio: URL, intervals: [DiarizationInterval]
        ) async throws -> [DiarizationChunkEmbedding] {
            asked.withLock { $0.append(intervals) }
            return intervals.map {
                DiarizationChunkEmbedding(
                    clusterID: $0.clusterID, start: $0.start, end: $0.end,
                    vector: SpeakerFixtures.vector(seed: $0.clusterID == "nemotron3_0" ? 71 : 72))
            }
        }
    }

    @Test("a diarizer that returns no vectors still gives voice memory its voices")
    func aDiarizerThatReturnsNoVectorsStillGivesVoiceMemoryItsVoices() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try PipelineFixtures.makeRecordedMeeting(root: root, seconds: 6)
        let (voices, voiceRoot) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: voiceRoot) }

        // Overlap, as Nemotron reports it: cluster 1 talks inside cluster 0's
        // turn. Only the solo stretches are handed to the extractor.
        var diarizer = StubLocalDiarizer(
            intervals: [
                DiarizationInterval(start: 0, end: 3, clusterID: "nemotron3_0"),
                DiarizationInterval(start: 2, end: 5, clusterID: "nemotron3_1"),
            ],
            chunkEmbeddings: []
        )
        diarizer.producesEmbeddings = false
        diarizer.identifier = "fluidaudio-nemotron3-offline-0.18.2"
        let stub = diarizer

        let extractor = RecordingExtractor()
        var settings = AppSettings()
        settings.enrichment = EnrichmentSettings(
            generateTitle: false, generateDescription: false, generateNotes: false,
            generateSummary: false, suggestSpeakers: false
        )
        let resolved = settings
        let pipeline = ProcessingPipeline(
            repository: meeting.repository, backend: FakeAIBackend(),
            backends: ProcessingBackends(
                transcription: { _, _ in
                    StubLocalTranscriber(segments: [
                        RawTranscriptSegment(
                            start: 0, end: 5, text: "hello there", speaker: nil,
                            words: [RawTranscriptWord(start: 0, end: 1, text: " hello")])
                    ])
                },
                diarization: { _, _ in stub },
                embeddings: extractor, speakers: SpeakerRecognitionService(store: voices)
            ),
            scratch: ProcessingScratch(root: root.appendingPathComponent("scratch")),
            clock: ManualClock(), settingsProvider: { resolved }, wait: { _ in }
        )
        await pipeline.process(meetingID: meeting.metadata.id)

        let asked = extractor.requests.flatMap { $0 }
        #expect(!asked.isEmpty, "the extractor ran over the intervals the diarizer returned")
        #expect(
            Set(asked.map(\.clusterID)) == ["nemotron3_0", "nemotron3_1"],
            "every cluster is embedded, so each has a voice to be recognised by")

        let run = try #require(
            try meeting.store.readRawDiarization().activeRun(track: .remote))
        for cluster in run.clusters {
            let key = SpeakerLabel.namespaced(chunkID: run.id, rawLabel: cluster.id)
            let vector = try await voices.occurrenceEmbedding(
                meetingID: meeting.metadata.id, clusterID: key)
            #expect(vector != nil, "\(cluster.id) has a voice vector in voice memory")
        }
    }

    @Test("the run records the model that ran, and the reason, from the output")
    func theRunRecordsTheModelThatRanAndTheReasonFromTheOutput() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try PipelineFixtures.makeRecordedMeeting(root: root, seconds: 6)
        var settings = AppSettings()
        settings.enrichment = EnrichmentSettings(
            generateTitle: false, generateDescription: false, generateNotes: false,
            generateSummary: false, suggestSpeakers: false
        )
        let resolved = settings
        let pipeline = ProcessingPipeline(
            repository: meeting.repository, backend: FakeAIBackend(),
            backends: ProcessingBackends(
                transcription: { _, _ in
                    StubLocalTranscriber(segments: [
                        RawTranscriptSegment(
                            start: 0, end: 5, text: "hello there", speaker: nil,
                            words: [RawTranscriptWord(start: 0, end: 1, text: " hello")])
                    ])
                },
                diarization: { _, _ in
                    StaticDiarizer(
                        output: Self.output(
                            speakers: 2,
                            configuration: [
                                "backend": LocalSpeechStack.diarizerBackendIdentifier,
                                "diarizer": "vbx", "diarizerReason": "modelNotInstalled",
                            ]))
                }
            ),
            scratch: ProcessingScratch(root: root.appendingPathComponent("scratch")),
            clock: ManualClock(), settingsProvider: { resolved }, wait: { _ in }
        )
        await pipeline.process(meetingID: meeting.metadata.id)

        let run = try #require(
            try meeting.store.readRawDiarization().activeRun(track: .remote))
        #expect(
            run.backend == LocalSpeechStack.diarizerBackendIdentifier,
            "the model that ran, not the identifier of the wrapper that chose it")
        #expect(run.configuration["diarizerReason"] == "modelNotInstalled")
    }

    /// A local backend whose identifier differs from the model its output
    /// names, as `LocalDiarizationBackend`'s does.
    private struct StaticDiarizer: DiarizationBackend {
        var output: DiarizationOutput
        var identifier: String { "fluidaudio-nemotron3-offline-0.18.2" }
        var isLocal: Bool { true }
        var limits: BackendAudioLimits { .none }
        var producesEmbeddings: Bool { false }
        var producesTranscript: Bool { false }

        func diarize(
            audio: URL, progress: @escaping @Sendable (Double) -> Void
        ) async throws -> DiarizationOutput { output }
    }
}
