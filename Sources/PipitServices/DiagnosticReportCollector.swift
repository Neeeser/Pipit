import Foundation
import PipitCore
import PipitDetection
import PipitIntegrations
import PipitLocalAI

/// Reads what a diagnostic report is built from, on this Mac
/// (`docs/DIAGNOSTICS.md`, Sections).
///
/// The runtime's own state is read on the main actor, where it lives. The
/// Keychain, the volumes, the meeting archive and the log are read off it,
/// because each can block: the Keychain on an authorisation prompt, a network
/// volume on the network, and the archive and the log on a walk of every
/// file. `DiagnosticSnapshot` turns the answers into the report's sections,
/// so nothing read here goes into a report except through its allowlist.
@MainActor
public struct DiagnosticReportCollector {
    public let runtime: PipitRuntime
    /// Whether the Keychain holds a provider's key. Called off the main
    /// actor. Injected so a test does not ask the real Keychain, which can
    /// put up a prompt.
    private let hasKey: @Sendable (LanguageModelProvider) -> Bool

    public init(runtime: PipitRuntime, hasKey: (@Sendable (LanguageModelProvider) -> Bool)? = nil) {
        self.runtime = runtime
        if let hasKey {
            self.hasKey = hasKey
        } else {
            let keys = runtime.languageModelKeys
            self.hasKey = { provider in DiskReading.hasKey(keys, provider) }
        }
    }

    /// Everything a report is assembled from.
    public func contents() async -> DiagnosticBundleContents {
        let settings = runtime.settings
        let status = runtime.status
        let modelState = runtime.localModelState
        let log = runtime.diagnostics
        let layout = log.layout
        let repository = runtime.repository
        let hasKey = self.hasKey
        let launch = DiagnosticEnvironment.current()
        let permissions = await runtime.permissions.allStatuses()

        let disk = await Task.detached(priority: .userInitiated) {
            // What is still queued goes to disk first, so the report holds the
            // moments before the person opened it. Bounded, and never on the
            // main actor, since it waits on the log's queue.
            log.flush(timeout: 1)
            return DiskReading.read(settings: settings, repository: repository, layout: layout, hasKey: hasKey)
        }.value

        #if DEBUG
            let isDebugBuild = true
        #else
            let isDebugBuild = false
        #endif
        let browsers = DiagnosticBrowserState(
            connections: status.browserSensors,
            hellos: status.browserHellos,
            firefoxLastVersion: settings.firefoxAddOnVersion,
            firefoxLastProtocol: settings.firefoxAddOnProtocol,
            firefoxHostManifest: disk.firefoxHostManifest,
            chromiumHostManifests: disk.chromiumHostManifests
        )
        return DiagnosticBundleContents(
            app: DiagnosticSnapshot.app(launch, isDebugBuild: isDebugBuild),
            system: DiagnosticSnapshot.system(
                launch,
                physicalMemory: ProcessInfo.processInfo.physicalMemory,
                cpuCores: ProcessInfo.processInfo.processorCount,
                freeBytes: disk.homeFreeBytes,
                preferredLanguage: Locale.preferredLanguages.first
            ),
            settings: DiagnosticSnapshot.settings(settings, context: disk.settingsContext),
            permissions: DiagnosticSnapshot.permissions(permissions),
            models: DiagnosticSnapshot.models(
                receipts: modelState.present.receipts.mapValues {
                    DiagnosticModelReceipt(revision: $0.revision, bytes: $0.bytes)
                },
                required: LocalModelUnit.required(for: settings),
                activity: Self.activity(modelState)
            ),
            browserAddOns: DiagnosticSnapshot.browserAddOns(browsers),
            storage: DiagnosticSnapshot.storage(meetings: disk.meetingCount, freeBytes: disk.archiveFreeBytes),
            recentFailures: DiagnosticSnapshot.recentFailures(disk.processingStatuses),
            events: disk.events,
            crashes: disk.crashes
        )
    }

    /// Builds a report from `contents`, off the main actor: fitting twenty
    /// thousand events to the limits encodes and compresses the report more
    /// than once.
    public nonisolated static func bundle(
        _ contents: DiagnosticBundleContents, kind: DiagnosticReport.Kind, identity: DiagnosticReportIdentity,
        createdAt: Date, note: String? = nil, contact: String? = nil
    ) async throws -> DiagnosticBundle {
        let request = DiagnosticBundleRequest(
            reportID: identity.reportID, kind: kind, createdAt: createdAt,
            deletionSecretHash: identity.deletionSecretHash, note: note, contact: contact
        )
        return try await Task.detached(priority: .userInitiated) {
            try DiagnosticBundleBuilder.build(contents, request: request)
        }.value
    }

    private static func activity(_ state: LocalModelState) -> DiagnosticModelActivity {
        switch state {
        case .downloading: .installing
        case .failed: .failed
        case .notInstalled, .installed, .outdated: .idle
        }
    }
}

/// What the collector reads from the disk and the Keychain, in one pass off
/// the main actor.
private struct DiskReading: Sendable {
    var settingsContext: DiagnosticSettingsContext
    var homeFreeBytes: Int64?
    var archiveFreeBytes: Int64?
    var meetingCount = 0
    var processingStatuses: [ProcessingStatus] = []
    var firefoxHostManifest = false
    var chromiumHostManifests: [String: Bool] = [:]
    var events: [DiagnosticEvent] = []
    var crashes: [CrashSummary] = []

    static func read(
        settings: AppSettings, repository: MeetingRepository, layout: DiagnosticLayout?,
        hasKey: @Sendable (LanguageModelProvider) -> Bool
    ) -> DiskReading {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = settings.storageRoot
        let existingRoot = nearestExisting(root)
        let rootValues = try? existingRoot.resourceValues(
            forKeys: [.isUbiquitousItemKey, .volumeIsLocalKey, .volumeIsInternalKey]
        )
        let volume = DiagnosticStorageVolume.classify(
            folder: existingRoot, home: home, isUbiquitous: rootValues?.isUbiquitousItem,
            isLocal: rootValues?.volumeIsLocal, isInternal: rootValues?.volumeIsInternal
        )
        var reading = DiskReading(
            settingsContext: DiagnosticSettingsContext(
                hasOpenAIKey: hasKey(.openAI),
                hasOpenRouterKey: hasKey(.openRouter),
                hasCustomEndpointKey: hasKey(.custom),
                storageVolume: volume,
                defaultStorageRoot: MeetingArchiveLayout.defaultRoot
            ),
            homeFreeBytes: freeBytes(home),
            archiveFreeBytes: freeBytes(existingRoot)
        )

        for directory in repository.meetingDirectories() {
            guard let metadata = try? MeetingStore(layout: MeetingLayout(root: directory)).readMetadata() else {
                continue
            }
            // Counted as the Meetings window counts them: a recording folded
            // into another is part of that meeting.
            if metadata.mergedIntoMeetingID == nil { reading.meetingCount += 1 }
            if metadata.processing.lastFailure != nil { reading.processingStatuses.append(metadata.processing) }
        }

        let installer = NativeMessagingInstaller()
        let fileManager = FileManager.default
        reading.firefoxHostManifest = fileManager.fileExists(atPath: installer.firefoxManifestURL.path)
        for browser in SensorTransport.chromiumBrowsers
        where fileManager.fileExists(atPath: browser.dataDirectory.path) {
            let manifest = browser.hostManifestDirectory
                .appendingPathComponent("\(SensorTransport.nativeMessagingHostName).json")
            reading.chromiumHostManifests[browser.name] = fileManager.fileExists(atPath: manifest.path)
        }

        if let layout {
            let safari = SafariSensorSocket.diagnosticsFile().map { [$0] } ?? []
            reading.events = layout.storedEvents(additionalFiles: safari)
            // Only the summaries already reduced into crashes/. Reading
            // DiagnosticReports is the launch scan's job.
            reading.crashes =
                CrashReportScanner(
                    reportsDirectory: CrashReportScanner(home: home).reportsDirectory,
                    crashesDirectory: layout.crashes
                )
                .stored().map(\.summary)
        }
        return reading
    }

    /// Whether the Keychain holds a key, without reading it.
    ///
    /// A key the process already holds answers yes without asking. Otherwise
    /// the Keychain is asked for the item's attributes only, which can still
    /// wait on an authorisation prompt for a build the item does not trust.
    static func hasKey(_ keys: LanguageModelKeyring, _ provider: LanguageModelProvider) -> Bool {
        guard let store = keys.store(for: provider) else { return false }
        return !store.isKnownAbsent
    }

    private static func freeBytes(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// The folder itself, or the nearest folder above it that exists, which
    /// is on the volume the folder will be made on.
    private static func nearestExisting(_ url: URL) -> URL {
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        return probe
    }
}
