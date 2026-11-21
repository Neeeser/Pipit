import CoreML
import FluidAudio
import Foundation
import PipitCore

/// Where the Nemotron 3 files come from and how they are made ready to run.
///
/// A seam so the install and the compile that follows it can be tested with a
/// fake; `FluidAudioNemotron3Source` is the one the application uses.
public protocol Nemotron3ModelSource: Sendable {
    /// Puts the `offline` preset's files under `root`. Downloads only; loading
    /// the model is `prepare`'s job, so an install finishes in the time the
    /// download takes.
    func download(
        root: URL, force: Bool, progress: @escaping @Sendable (Double, String) -> Void
    ) async throws

    /// Loads the downloaded model so Core ML compiles it for the Neural Engine
    /// and caches the result, which is what a first meeting would otherwise
    /// wait on. Returns the seconds the load took.
    ///
    /// Loading alone does the compile. Measured on a copy of the model in a
    /// new folder: the load took 158 s and the first prediction after it
    /// 0.15 s, so no prediction is needed to warm the cache.
    @discardableResult
    func prepare(root: URL) async throws -> Double
}

public struct FluidAudioNemotron3Source: Nemotron3ModelSource {
    public init() {}

    public func download(
        root: URL, force: Bool, progress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        let repo = Repo.nemotron3Diarization
        let directory = root.appendingPathComponent(repo.folderName, isDirectory: true)
        let config = Nemotron3Config.offline
        let manager = FileManager.default
        // The library's own loader drops a cache from another checkpoint and
        // fetches the rest; this repeats those steps without its final load.
        let marker = directory.appendingPathComponent(ModelNames.Nemotron3.weightsVersionFile)
        let cached = (try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if force || (manager.fileExists(atPath: directory.path) && cached != ModelNames.Nemotron3.weightsVersion) {
            try? manager.removeItem(at: directory)
        }
        let bundlePath = "\(config.hubSubdirectory)/\(config.modelFileName)"
        let bundle = directory.appendingPathComponent(bundlePath)
        progress(0, "Downloading speaker separation")
        if !manager.fileExists(atPath: bundle.appendingPathComponent("coremldata.bin").path) {
            try await ModelHub.download(
                repo, subdirectory: bundlePath, to: directory,
                progressHandler: { progress($0.fractionCompleted * 0.95, "Downloading speaker separation") }
            )
        }
        let silence = ModelNames.Nemotron3.silenceEmbeddingFile
        if !manager.fileExists(atPath: directory.appendingPathComponent(silence).path) {
            try await ModelHub.download(
                repo, subdirectory: "", to: directory, progressHandler: nil,
                shouldSkip: { $0 != silence }
            )
        }
        // Written last, so an interrupted download has no marker and starts
        // over, the same contract the library's loader keeps.
        try Data((ModelNames.Nemotron3.weightsVersion + "\n").utf8).write(to: marker, options: .atomic)
        progress(1, "Downloading speaker separation")
    }

    public func prepare(root: URL) async throws -> Double {
        let directory = root.appendingPathComponent(Repo.nemotron3Diarization.folderName, isDirectory: true)
        // The library's load fetches whatever is missing. A delete that raced
        // this compile must stay deleted, so the files are checked first and
        // the cancellation after.
        guard LocalModelManager.nemotron3FilesPresent(.offline, directory: directory) else {
            throw LocalModelError.notInstalled
        }
        try Task.checkCancellation()
        let start = Date()
        _ = try await Nemotron3Models.loadFromHuggingFace(
            config: .offline, cacheDirectory: root,
            computeUnits: LocalModelManager.nemotron3ComputeUnits
        )
        try Task.checkCancellation()
        return Date().timeIntervalSince(start)
    }
}
