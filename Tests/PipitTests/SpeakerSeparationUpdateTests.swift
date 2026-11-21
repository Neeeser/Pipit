import CoreML
import FluidAudio
import Foundation
import PipitAudio
import PipitCore
import Testing

@testable import PipitLocalAI
@testable import PipitServices

/// Nemotron 3 Diarization as an optional unit: a fresh install gets it, a Mac
/// that updated without it is offered it, and meetings run on the previous
/// speaker model until it is there.
@Suite("Speaker separation update")
struct SpeakerSeparationUpdateTests {
    // MARK: which units

    @Test("only setup and the update fetch Nemotron; no configuration requires it")
    func onlySetupAndTheUpdateFetchNemotronNoConfigurationRequiresIt() {
        var settings = AppSettings()
        for diarization in [ProcessingBackendChoice.local, .openAI] {
            settings.processing.diarization = diarization
            #expect(!LocalModelUnit.required(for: settings).contains(.nemotronDiarizer))
            #expect(LocalModelUnit.required(for: settings).contains(.diarizer))
        }
        settings.processing.diarization = .local
        #expect(LocalModelUnit.recommended(for: settings).contains(.nemotronDiarizer))
        #expect(
            LocalModelUnit.recommended(for: settings).isSuperset(of: LocalModelUnit.required(for: settings)))
    }

    @Test("setup lists Nemotron among the units a new install downloads")
    func setupListsNemotronAmongTheUnitsANewInstallDownloads() {
        var flow = SetupSnapshot()
        flow.settings.processing.diarization = .local
        #expect(flow.recommendedUnits.contains(.nemotronDiarizer))
        #expect(flow.missingUnits.contains(.nemotronDiarizer))
        flow.installedUnits = [.nemotronDiarizer]
        #expect(!flow.missingUnits.contains(.nemotronDiarizer))
    }

    // MARK: the update on an existing install

    private static func receipt(bytes: Int64) -> LocalUnitReceipt {
        LocalUnitReceipt(revision: "test", bytes: bytes, installedAt: Date())
    }

    @Test("the update asks for whichever of the two speaker separation units is missing")
    @MainActor
    func theUpdateAsksForWhicheverOfTheTwoSpeakerSeparationUnitsIsMissing() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = PipitRuntime(settingsDirectory: root)
        var settings = runtime.settings
        settings.processing.diarization = .local
        runtime.update(settings: settings)
        let both: Set<LocalModelUnit> = [.diarizer, .nemotronDiarizer]
        #expect(PipitRuntime.speakerSeparationUnits == both)

        runtime.localModelState = .notInstalled(LocalModelSnapshot())
        #expect(runtime.speakerSeparationMissingUnits == both, "a fresh Mac needs both")
        #expect(runtime.speakerSeparationInstalledBytes == nil)

        runtime.localModelState = .installed(
            LocalModelSnapshot(receipts: [.diarizer: Self.receipt(bytes: 21_000_000)]))
        #expect(runtime.speakerSeparationMissingUnits == [.nemotronDiarizer], "an upgraded Mac needs Nemotron")
        #expect(runtime.speakerSeparationUpdateAvailable)
        #expect(runtime.speakerSeparationInstalledBytes == 21_000_000)

        runtime.localModelState = .installed(
            LocalModelSnapshot(receipts: [.nemotronDiarizer: Self.receipt(bytes: 190_000_000)]))
        #expect(runtime.speakerSeparationMissingUnits == [.diarizer])

        runtime.localModelState = .installed(
            LocalModelSnapshot(receipts: [
                .diarizer: Self.receipt(bytes: 21_000_000),
                .nemotronDiarizer: Self.receipt(bytes: 190_000_000),
            ]))
        #expect(!runtime.speakerSeparationUpdateAvailable)
        #expect(runtime.speakerSeparationInstalledBytes == 211_000_000, "one row, both sizes together")

        settings.processing.transcription = .openAI
        settings.processing.diarization = .openAI
        runtime.update(settings: settings)
        runtime.localModelState = .installed(LocalModelSnapshot())
        #expect(!runtime.speakerSeparationUpdateAvailable, "a cloud diarizer never reaches it")
    }

    // MARK: downloading, then compiling in the background

    /// Stands in for the download and the Core ML load, recording the order.
    private final class FakeSource: Nemotron3ModelSource {
        let events = LockedBox<[String]>([])
        let prepareError: (any Error)?
        let downloadError: (any Error)?

        init(prepareError: (any Error)? = nil, downloadError: (any Error)? = nil) {
            self.prepareError = prepareError
            self.downloadError = downloadError
        }

        func download(
            root: URL, force: Bool, progress: @escaping @Sendable (Double, String) -> Void
        ) async throws {
            events.withLock { $0.append("download") }
            if let downloadError { throw downloadError }
            let directory = root.appendingPathComponent(
                Repo.nemotron3Diarization.folderName, isDirectory: true)
            let config = Nemotron3Config.offline
            let bundle = directory.appendingPathComponent(
                "\(config.hubSubdirectory)/\(config.modelFileName)")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data().write(to: bundle.appendingPathComponent("coremldata.bin"))
            try Data().write(
                to: directory.appendingPathComponent(ModelNames.Nemotron3.silenceEmbeddingFile))
            try Data((ModelNames.Nemotron3.weightsVersion + "\n").utf8).write(
                to: directory.appendingPathComponent(ModelNames.Nemotron3.weightsVersionFile))
        }

        func prepare(root: URL) async throws -> Double {
            events.withLock { $0.append("prepare") }
            if let prepareError { throw prepareError }
            return 0
        }
    }

    private struct CompileFailure: Error {}

    private static func manager(
        source: FakeSource, required: Set<LocalModelUnit> = [.nemotronDiarizer],
        preparing: LockedBox<[Bool]> = LockedBox([])
    ) throws -> LocalModelManager {
        let root = try TestPaths.makeTemporaryDirectory()
        return LocalModelManager(
            applicationSupport: root, required: required, nemotron: source,
            onPreparationChange: { value in preparing.withLock { $0.append(value) } }
        )
    }

    @Test("an install that includes Nemotron downloads it, then compiles it in the background")
    func anInstallThatIncludesNemotronDownloadsItThenCompilesItInTheBackground() async throws {
        let source = FakeSource()
        let preparing = LockedBox<[Bool]>([])
        let manager = try Self.manager(source: source, preparing: preparing)

        _ = try await manager.install(units: [.nemotronDiarizer])
        await manager.waitForNemotronPreparation()

        #expect(source.events.withLock { $0 } == ["download", "prepare"])
        #expect(preparing.withLock { $0 } == [true, false])
    }

    @Test("the update installs and compiles Nemotron without making it required")
    func theUpdateInstallsAndCompilesNemotronWithoutMakingItRequired() async throws {
        let source = FakeSource()
        let manager = try Self.manager(source: source, required: [])

        let snapshot = try await manager.install(units: [.nemotronDiarizer])
        await manager.waitForNemotronPreparation()

        #expect(snapshot.bytes(for: .nemotronDiarizer) != nil)
        #expect(await manager.currentState.present.bytes(for: .nemotronDiarizer) != nil)
        #expect(source.events.withLock { $0 } == ["download", "prepare"])
        #expect(await manager.currentState.isUsable, "the install leaves the machine usable")
    }

    @Test("a download that fails is reported, and a retry that works clears it")
    @MainActor
    func aDownloadThatFailsIsReportedAndARetryThatWorksClearsIt() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = PipitRuntime(settingsDirectory: root)

        runtime.models = try Self.manager(source: FakeSource(downloadError: DownloadFailure()), required: [])
        await runtime.installSpeakerSeparation(units: [.nemotronDiarizer])
        #expect(runtime.speakerSeparationUpdateFailed)

        runtime.models = try Self.manager(source: FakeSource(), required: [])
        await runtime.installSpeakerSeparation(units: [.nemotronDiarizer])
        #expect(!runtime.speakerSeparationUpdateFailed)
    }

    private struct DownloadFailure: Error {}

    @Test("a compile that fails leaves the install done")
    func aCompileThatFailsLeavesTheInstallDone() async throws {
        let source = FakeSource(prepareError: CompileFailure())
        let manager = try Self.manager(source: source)

        _ = try await manager.install(units: [.nemotronDiarizer])
        await manager.waitForNemotronPreparation()

        #expect(await manager.currentState.isUsable)
    }

    @Test("installing again with the files present compiles nothing more")
    func installingAgainWithTheFilesPresentCompilesNothingMore() async throws {
        let source = FakeSource()
        let manager = try Self.manager(source: source)
        _ = try await manager.install(units: [.nemotronDiarizer])
        await manager.waitForNemotronPreparation()
        _ = try await manager.install(units: [.nemotronDiarizer])
        await manager.waitForNemotronPreparation()

        #expect(source.events.withLock { $0 } == ["download", "prepare"])
    }

    @Test("files on disk without a receipt are adopted, so the update finishes and compiles")
    func filesOnDiskWithoutAReceiptAreAdoptedSoTheUpdateFinishesAndCompiles() async throws {
        // A Mac can hold the files and no receipt: a download interrupted
        // before units.json was written, or a tool that fetched them into the
        // same folder. The install skipped such a unit as already there, so
        // the update button did nothing and stayed on screen.
        let source = FakeSource()
        let manager = try Self.manager(source: source, required: [])
        try await source.download(root: manager.locations.root, force: false, progress: { _, _ in })
        #expect(await manager.currentState.present.bytes(for: .nemotronDiarizer) == nil)

        _ = try await manager.install(units: [.nemotronDiarizer])
        await manager.waitForNemotronPreparation()

        #expect(await manager.currentState.present.bytes(for: .nemotronDiarizer) != nil)
        #expect(source.events.withLock { $0 }.last == "prepare")
    }

    // MARK: the previous model as the fallback

    private struct Stub: DiarizationBackend {
        var identifier: String
        var failure: (any Error)?
        var isLocal: Bool { true }
        var limits: BackendAudioLimits { .none }
        var producesEmbeddings: Bool { false }
        var producesTranscript: Bool { false }

        func diarize(
            audio: URL, progress: @escaping @Sendable (Double) -> Void
        ) async throws -> DiarizationOutput {
            if let failure { throw failure }
            return DiarizationOutput(
                intervals: [], clusters: [], configuration: ["diarizer": identifier])
        }
    }

    @Test("without the Nemotron unit a meeting runs on the previous model")
    func withoutTheNemotronUnitAMeetingRunsOnThePreviousModel() async throws {
        let backend = LocalDiarizationBackend(
            primary: Stub(identifier: "nemotron", failure: LocalModelError.notInstalled),
            fallback: Stub(identifier: "previous")
        )
        let output = try await backend.diarize(
            audio: URL(fileURLWithPath: "/nonexistent.wav"), progress: { _ in })
        #expect(output.configuration["diarizer"] == "previous")
        #expect(output.configuration["diarizerReason"] == "modelNotInstalled")
    }
}
