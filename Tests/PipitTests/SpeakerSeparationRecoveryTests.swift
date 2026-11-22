import CoreML
import FluidAudio
import Foundation
import PipitAudio
import PipitCore
import Testing

@testable import PipitLocalAI
@testable import PipitServices

/// What happens to Nemotron 3 when the app quits, the idle timer fires, the
/// person deletes it or progress arrives out of order, around the download and
/// the Core ML compile that follows it.
@Suite("Speaker separation recovery", .serialized)
struct SpeakerSeparationRecoveryTests {
    /// A source whose steps can be held open, so a test can act while the
    /// download or the compile is running.
    private final class GatedSource: Nemotron3ModelSource {
        let events = LockedBox<[String]>([])
        let downloadOpen: LockedBox<Bool>
        let prepareOpen: LockedBox<Bool>
        let prepareCancelled = LockedBox(false)
        /// Writes the files back when the compile is cancelled, as the library
        /// does when its load finds them gone and fetches them again.
        let refetchesWhenCancelled: Bool
        let prepareError: (any Error)?
        let downloadError: (any Error)?

        init(
            holdDownload: Bool = false, holdPrepare: Bool = false, refetchesWhenCancelled: Bool = false,
            prepareError: (any Error)? = nil, downloadError: (any Error)? = nil
        ) {
            downloadOpen = LockedBox(!holdDownload)
            prepareOpen = LockedBox(!holdPrepare)
            self.refetchesWhenCancelled = refetchesWhenCancelled
            self.prepareError = prepareError
            self.downloadError = downloadError
        }

        static func writeFiles(root: URL) throws {
            let directory = root.appendingPathComponent(Repo.nemotron3Diarization.folderName, isDirectory: true)
            let config = Nemotron3Config.offline
            let bundle = directory.appendingPathComponent("\(config.hubSubdirectory)/\(config.modelFileName)")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data().write(to: bundle.appendingPathComponent("coremldata.bin"))
            try Data().write(to: directory.appendingPathComponent(ModelNames.Nemotron3.silenceEmbeddingFile))
            try Data((ModelNames.Nemotron3.weightsVersion + "\n").utf8).write(
                to: directory.appendingPathComponent(ModelNames.Nemotron3.weightsVersionFile))
        }

        func download(
            root: URL, force: Bool, progress: @escaping @Sendable (Double, String) -> Void
        ) async throws {
            events.withLock { $0.append("download") }
            while !downloadOpen.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
            if let downloadError { throw downloadError }
            try Self.writeFiles(root: root)
        }

        func prepare(root: URL) async throws -> Double {
            events.withLock { $0.append("prepare") }
            do {
                while !prepareOpen.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
            } catch {
                prepareCancelled.withLock { $0 = true }
                if refetchesWhenCancelled {
                    // After the delete has removed the folder.
                    await Task { try? await Task.sleep(for: .milliseconds(100)) }.value
                    try Self.writeFiles(root: root)
                }
                throw error
            }
            if let prepareError { throw prepareError }
            return 0
        }

        var count: (download: Int, prepare: Int) {
            let all = events.withLock { $0 }
            return (all.filter { $0 == "download" }.count, all.filter { $0 == "prepare" }.count)
        }
    }

    private struct Failure: Error {}

    private static func manager(
        root: URL, source: GatedSource, preparing: LockedBox<[Bool]> = LockedBox([])
    ) -> LocalModelManager {
        LocalModelManager(
            applicationSupport: root, required: [], nemotron: source,
            onPreparationChange: { value in preparing.withLock { $0.append(value) } }
        )
    }

    private static func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting")
    }

    private static func directory(_ root: URL) -> URL {
        LocalModelLocations(applicationSupport: root).nemotronDiarizerDirectory
    }

    // MARK: a compile the app quit during

    @Test("a relaunch compiles an install whose compile never finished")
    func aRelaunchCompilesAnInstallWhoseCompileNeverFinished() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // The first run: the download finishes and the receipt is written, then
        // the compile fails, as it does when the app quits partway.
        let first = GatedSource(prepareError: Failure())
        let before = Self.manager(root: root, source: first)
        _ = try await before.install(units: [.nemotronDiarizer])
        await before.waitForNemotronPreparation()
        #expect(!LocalModelManager.nemotron3CompileFinished(directory: Self.directory(root)))

        let second = GatedSource()
        let preparing = LockedBox<[Bool]>([])
        let after = Self.manager(root: root, source: second, preparing: preparing)
        await after.resumeNemotronPreparation()
        await after.waitForNemotronPreparation()

        #expect(second.count == (download: 0, prepare: 1))
        #expect(preparing.withLock { $0 } == [true, false], "the row shows its bar after a relaunch")
        #expect(LocalModelManager.nemotron3CompileFinished(directory: Self.directory(root)))
    }

    @Test("a relaunch leaves a compiled install alone, and an absent one")
    func aRelaunchLeavesACompiledInstallAloneAndAnAbsentOne() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let none = GatedSource()
        let empty = Self.manager(root: root, source: none)
        await empty.resumeNemotronPreparation()
        await empty.waitForNemotronPreparation()
        #expect(none.count == (download: 0, prepare: 0), "nothing installed, nothing to compile")

        let installer = GatedSource()
        let first = Self.manager(root: root, source: installer)
        _ = try await first.install(units: [.nemotronDiarizer])
        await first.waitForNemotronPreparation()
        #expect(installer.count.prepare == 1)

        let relaunched = GatedSource()
        let second = Self.manager(root: root, source: relaunched)
        await second.resumeNemotronPreparation()
        await second.waitForNemotronPreparation()
        #expect(relaunched.count == (download: 0, prepare: 0), "the marker says it was compiled")
    }

    // MARK: the idle release

    @Test("the idle release neither cancels a running compile nor starts while it runs")
    func theIdleReleaseNeitherCancelsARunningCompileNorStartsWhileItRuns() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = GatedSource(holdPrepare: true)
        let manager = Self.manager(root: root, source: source)

        _ = try await manager.install(units: [.nemotronDiarizer])
        try await Self.waitUntil { source.count.prepare == 1 }

        let released = await manager.releaseLoadedModels()
        #expect(!released, "the compile counts as use of the models")
        try await Task.sleep(for: .milliseconds(50))
        #expect(!source.prepareCancelled.withLock { $0 })

        source.prepareOpen.withLock { $0 = true }
        await manager.waitForNemotronPreparation()
        #expect(LocalModelManager.nemotron3CompileFinished(directory: Self.directory(root)))
        #expect(await manager.releaseLoadedModels(), "once it ends the release may run")
    }

    @Test("unloading Nemotron leaves a running compile alone")
    func unloadingNemotronLeavesARunningCompileAlone() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = GatedSource(holdPrepare: true)
        let manager = Self.manager(root: root, source: source)
        _ = try await manager.install(units: [.nemotronDiarizer])
        try await Self.waitUntil { source.count.prepare == 1 }

        await manager.unload(.nemotronDiarizer)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!source.prepareCancelled.withLock { $0 })

        source.prepareOpen.withLock { $0 = true }
        await manager.waitForNemotronPreparation()
    }

    // MARK: delete during the compile

    @Test("deleting Nemotron during its compile cancels it and leaves no files behind")
    func deletingNemotronDuringItsCompileCancelsItAndLeavesNoFilesBehind() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = GatedSource(holdPrepare: true, refetchesWhenCancelled: true)
        let manager = Self.manager(root: root, source: source)
        _ = try await manager.install(units: [.nemotronDiarizer])
        try await Self.waitUntil { source.count.prepare == 1 }

        await manager.remove(unit: .nemotronDiarizer)
        await manager.waitForNemotronPreparation()

        #expect(source.prepareCancelled.withLock { $0 }, "delete cancels the compile")
        #expect(
            !FileManager.default.fileExists(atPath: Self.directory(root).path),
            "a load that fetched the files back is cleaned up")
        #expect(await manager.currentState.present.bytes(for: .nemotronDiarizer) == nil)
        #expect(!LocalModelManager.nemotron3CompileFinished(directory: Self.directory(root)))
    }

    @Test("a compile that ends after a delete does not record that it finished")
    func aCompileThatEndsAfterADeleteDoesNotRecordThatItFinished() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = GatedSource(holdPrepare: true)
        let manager = Self.manager(root: root, source: source)
        _ = try await manager.install(units: [.nemotronDiarizer])
        try await Self.waitUntil { source.count.prepare == 1 }
        await manager.remove(unit: .nemotronDiarizer)
        source.prepareOpen.withLock { $0 = true }
        await manager.waitForNemotronPreparation()
        #expect(!FileManager.default.fileExists(atPath: Self.directory(root).path))
    }

    @Test("the compile refuses to load, and so to download, when the files are gone")
    func theCompileRefusesToLoadAndSoToDownloadWhenTheFilesAreGone() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // A load with the files missing would fetch them. Offline mode makes
        // that a failure here instead of 190 MB of network.
        ModelHub.offlineMode = true
        defer { ModelHub.offlineMode = false }
        do {
            _ = try await FluidAudioNemotron3Source().prepare(root: root)
            Issue.record("expected the compile to refuse")
        } catch let error as LocalModelError {
            if case .notInstalled = error {} else { Issue.record("expected notInstalled, got \(error)") }
        } catch {
            Issue.record("expected notInstalled, got \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: Self.directory(root).path))
    }

    // MARK: progress

    @Test("download progress never steps backward, and a finished install's ticks are ignored")
    func downloadProgressNeverStepsBackwardAndAFinishedInstallsTicksAreIgnored() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = GatedSource(holdDownload: true)
        let manager = Self.manager(root: root, source: source)
        let install = Task { try await manager.install(units: [.nemotronDiarizer]) }
        try await Self.waitUntil { source.count.download == 1 }

        func fraction() async -> Double? {
            if case .downloading(let value, _, _) = await manager.currentState { return value }
            return nil
        }
        let generation = await manager.installGeneration
        await manager.publishProgress(fraction: 0.6, detail: "x", generation: generation)
        await manager.publishProgress(fraction: 0.4, detail: "x", generation: generation)
        #expect(await fraction() == 0.6)
        await manager.publishProgress(fraction: 0.9, detail: "x", generation: generation &- 1)
        #expect(await fraction() == 0.6, "a tick from another install does not count")
        await manager.publishProgress(fraction: 0.7, detail: "x", generation: generation)
        #expect(await fraction() == 0.7)

        source.downloadOpen.withLock { $0 = true }
        _ = try await install.value
        await manager.waitForNemotronPreparation()
    }

    // MARK: the update's own state

    @Test("the update's progress state lives on the runtime until it ends")
    @MainActor
    func theUpdatesProgressStateLivesOnTheRuntimeUntilItEnds() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = PipitRuntime(settingsDirectory: root)
        let source = GatedSource(holdDownload: true)
        runtime.models = Self.manager(root: root, source: source)
        #expect(!runtime.speakerSeparationUpdating)

        let update = Task { @MainActor in
            await runtime.installSpeakerSeparation(units: [.nemotronDiarizer])
        }
        try await Self.waitUntil { source.count.download == 1 }
        #expect(runtime.speakerSeparationUpdating)
        #expect(runtime.speakerSeparationUpdateBytes == LocalModelUnit.nemotronDiarizer.approximateBytes)

        source.downloadOpen.withLock { $0 = true }
        await update.value
        #expect(!runtime.speakerSeparationUpdating)
        await runtime.models?.waitForNemotronPreparation()
    }

    @Test("a failed update clears the in-progress state")
    @MainActor
    func aFailedUpdateClearsTheInProgressState() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = PipitRuntime(settingsDirectory: root)
        runtime.models = Self.manager(root: root, source: GatedSource(downloadError: Failure()))
        await runtime.installSpeakerSeparation(units: [.nemotronDiarizer])
        #expect(!runtime.speakerSeparationUpdating)
        #expect(runtime.speakerSeparationUpdateFailed)
    }
}
