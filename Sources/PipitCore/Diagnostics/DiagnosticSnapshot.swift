import Foundation

/// The `app`, `system` and `summary` sections of a report, built from values
/// the caller has already read (`docs/DIAGNOSTICS.md`, Report format).
///
/// Everything here is a pure function of its arguments, so what a section
/// may hold is tested without a Mac's keychain, volumes or permissions. The
/// service layer reads those and passes the answers in. Every string a
/// section produces is an enum's raw value, a count, a bucket, or a token
/// checked against `DiagnosticTokenRule`.
public enum DiagnosticSnapshot {}

// MARK: - free disk

/// Free space as a bucket, never a byte count. Decimal gigabytes, the unit
/// the Finder shows. `<` and `>` break the token rule, so the ends are
/// spelled `lt` and `gt`.
public enum DiagnosticDiskSpace: String, Sendable, CaseIterable {
    case under5GB = "lt5GB"
    case from5To20GB = "5-20GB"
    case from20To100GB = "20-100GB"
    case over100GB = "gt100GB"
    /// The volume did not say, which a network mount often does not.
    case unknown

    public init(freeBytes: Int64?) {
        guard let freeBytes, freeBytes >= 0 else {
            self = .unknown
            return
        }
        let gigabyte: Int64 = 1_000_000_000
        switch freeBytes {
        case ..<(5 * gigabyte): self = .under5GB
        case ..<(20 * gigabyte): self = .from5To20GB
        case ..<(100 * gigabyte): self = .from20To100GB
        default: self = .over100GB
        }
    }
}

// MARK: - storage volume

/// What kind of volume the meetings folder is on.
///
/// A recording that stops, a file that cannot be read back, and a folder
/// that fills up all look different on a synced or network volume, and the
/// path that would say which is exactly what a report must not carry.
public enum DiagnosticStorageVolume: String, Sendable, CaseIterable {
    case `internal`
    case external
    case network
    /// Inside iCloud Drive, or a File Provider folder such as Dropbox's or
    /// OneDrive's under `~/Library/CloudStorage`.
    case cloudSynced = "cloud_synced"
    case unknown

    /// Classifies a folder from where it is and what its volume says.
    ///
    /// `isUbiquitous` is the folder's own `isUbiquitousItem`, which is how a
    /// Desktop or Documents folder that iCloud syncs in place is caught.
    /// `isLocal` and `isInternal` are the volume's. A nil is a question the
    /// system did not answer.
    public static func classify(
        folder: URL, home: URL, isUbiquitous: Bool?, isLocal: Bool?, isInternal: Bool?
    ) -> DiagnosticStorageVolume {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let library = home.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent("Library", isDirectory: true)
        let synced = ["Mobile Documents", "CloudStorage"].map {
            library.appendingPathComponent($0, isDirectory: true).path
        }
        if isUbiquitous == true || synced.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return .cloudSynced
        }
        if isLocal == false { return .network }
        switch isInternal {
        case true?: return .internal
        case false?: return .external
        case nil: return .unknown
        }
    }
}

// MARK: - app and system

extension DiagnosticSnapshot {
    /// The report's `app` section, from what `app.launched` records.
    ///
    /// The channel is read from the version: a local build is stamped
    /// `<version>-dev.<sha>` by `scripts/app-version.sh`, a pre-release
    /// carries any other suffix, and a release has none.
    public static func app(_ launch: DiagnosticEvent.AppLaunch, isDebugBuild: Bool) -> DiagnosticReport.App {
        let version = launch.version.value
        let channel: String
        if version.contains("-dev") {
            channel = "dev"
        } else if version.contains("-") {
            channel = "prerelease"
        } else {
            channel = "release"
        }
        return DiagnosticReport.App(
            version: version,
            build: Int(launch.build.value) ?? 0,
            commit: launch.commit.value,
            channel: channel,
            configuration: isDebugBuild ? "debug" : "release"
        )
    }

    /// The report's `system` section.
    ///
    /// `preferredLanguage` is the first of the person's preferred languages,
    /// such as `en-GB`; only its language code is kept, never the region.
    public static func system(
        _ launch: DiagnosticEvent.AppLaunch, physicalMemory: UInt64, cpuCores: Int, freeBytes: Int64?,
        preferredLanguage: String?
    ) -> DiagnosticReport.System {
        DiagnosticReport.System(
            os: launch.os.value,
            osBuild: launch.osBuild.value,
            hardware: launch.hardware.value,
            arch: launch.arch.rawValue,
            memoryGB: Int((Double(physicalMemory) / 1_073_741_824).rounded()),
            cpuCores: max(0, cpuCores),
            freeDisk: DiagnosticDiskSpace(freeBytes: freeBytes).rawValue,
            language: languageCode(preferredLanguage)
        )
    }

    /// `en` from `en-GB` or `en_GB`, or `unknown`.
    static func languageCode(_ identifier: String?) -> String {
        guard let identifier,
            let code = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first?.lowercased(),
            (2...3).contains(code.count),
            code.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) })
        else { return "unknown" }
        return code
    }
}

// MARK: - settings

/// What the settings section needs that `AppSettings` does not hold.
public struct DiagnosticSettingsContext: Sendable, Equatable {
    /// Whether the Keychain holds a key for each provider. Presence only: the
    /// value is never read to answer this.
    public var hasOpenAIKey: Bool
    public var hasOpenRouterKey: Bool
    public var hasCustomEndpointKey: Bool
    public var storageVolume: DiagnosticStorageVolume
    /// The folder meetings go to when nobody chose one.
    public var defaultStorageRoot: URL

    public init(
        hasOpenAIKey: Bool, hasOpenRouterKey: Bool, hasCustomEndpointKey: Bool,
        storageVolume: DiagnosticStorageVolume, defaultStorageRoot: URL
    ) {
        self.hasOpenAIKey = hasOpenAIKey
        self.hasOpenRouterKey = hasOpenRouterKey
        self.hasCustomEndpointKey = hasCustomEndpointKey
        self.storageVolume = storageVolume
        self.defaultStorageRoot = defaultStorageRoot
    }
}

extension DiagnosticSnapshot {
    /// The settings a report carries, by name.
    ///
    /// An allowlist written out key by key. Nothing here walks `AppSettings`
    /// by reflection or encodes it, so a field added to settings stays out of
    /// reports until a line here names it. Free text is never copied: the
    /// person's name becomes whether one is set, vocabulary hints a count, the
    /// custom endpoint its scheme and whether it is this Mac, the meetings
    /// folder whether it was moved and what kind of volume it is on, and the
    /// application lists their lengths. A model is named only when Pipit
    /// offered it; one a person typed reads `custom`.
    ///
    /// The keys are listed in `docs/DIAGNOSTICS.md`, Settings in a report.
    public static func settings(_ settings: AppSettings, context: DiagnosticSettingsContext) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]

        // General
        out["launchAtLogin"] = .bool(settings.launchAtLogin)
        out["showNotifications"] = .bool(settings.showNotifications)
        out["showsDockIcon"] = .bool(settings.showsDockIcon)
        out["receivesBetaUpdates"] = .bool(settings.receivesBetaUpdates)
        out["hasCompletedOnboarding"] = .bool(settings.hasCompletedOnboarding)

        // Processing
        let processing = settings.processing
        out["transcriptionBackend"] = .string(processing.transcription.rawValue)
        out["diarizationBackend"] = .string(processing.diarization.rawValue)
        out["localTranscriptionModel"] = .string(processing.localTranscriptionModel.rawValue)
        out["cloudTranscriptionModel"] = .string(
            offered(settings.models.transcription, among: AIModelSettings.transcriptionChoices)
        )
        out["recognizeKnownVoices"] = .bool(processing.speakers.recognizeKnownVoices)
        out["rememberRecurringVoices"] = .bool(processing.speakers.rememberRecurringVoices)
        out["learnMyVoice"] = .bool(processing.speakers.learnMyVoice)
        out["learnFromCorrections"] = .bool(processing.speakers.learnFromCorrections)
        out["hasLocalUserIdentity"] = .bool(processing.localUserIdentityID != nil)
        out["vocabularyHintCount"] = .integer(Int64(settings.models.keywordList.count))

        // Titles, summaries and notes
        let provider = settings.models.metadataProvider
        out["metadataProvider"] = .string(provider.rawValue)
        out["metadataModel"] = .string(metadataModel(settings.models.metadata, provider: provider))
        out["metadataContextTokens"] = .integer(Int64(settings.models.metadataContextTokens))
        out["hasOpenAIKey"] = .bool(context.hasOpenAIKey)
        out["hasOpenRouterKey"] = .bool(context.hasOpenRouterKey)
        out["hasCustomEndpointKey"] = .bool(context.hasCustomEndpointKey)
        let endpoint = endpointShape(settings.models.customEndpoint)
        out["customEndpointScheme"] = .string(endpoint.scheme)
        out["customEndpointIsLoopback"] = .bool(endpoint.isLoopback)
        let enrichment = settings.enrichment
        out["generateTitle"] = .bool(enrichment.generateTitle)
        out["generateDescription"] = .bool(enrichment.generateDescription)
        out["generateNotes"] = .bool(enrichment.generateNotes)
        out["generateSummary"] = .bool(enrichment.generateSummary)
        out["suggestSpeakers"] = .bool(enrichment.suggestSpeakers)
        out["suggestFolders"] = .bool(enrichment.suggestFolders)
        out["folderReach"] = .string(enrichment.folderReach.rawValue)
        out["filesMatchingMeetings"] = .bool(enrichment.filesMatchingMeetings)
        out["noticesRecurringMeetings"] = .bool(enrichment.noticesRecurringMeetings)

        // People
        let name = settings.localUserName.trimmingCharacters(in: .whitespacesAndNewlines)
        out["hasLocalUserName"] = .bool(!name.isEmpty && name != defaultLocalUserName)

        // Recording and detection
        out["segmentSeconds"] = number(settings.segmentSeconds)
        out["preRollSeconds"] = number(settings.preRollSeconds)
        out["meetingEndGraceSeconds"] = number(settings.meetingEndGraceSeconds)
        out["meetingReconnectWindowSeconds"] = number(settings.meetingReconnectWindowSeconds)
        out["alwaysRecordAppCount"] = .integer(Int64(settings.alwaysRecordApplications.count))
        out["neverRecordAppCount"] = .integer(Int64(settings.neverRecordApplications.count))
        let providers = settings.providers
        out["detectionPaused"] = .bool(providers.detectionPaused)
        for (key, policy) in [
            ("slack", providers.slack), ("googleMeet", providers.googleMeet), ("zoom", providers.zoom),
            ("faceTime", providers.faceTime), ("unknownCalls", providers.unknownCalls),
        ] {
            out["\(key)AutoStart"] = .string(policy.autoStart.rawValue)
            out["\(key)AutoStop"] = .bool(policy.autoStop)
        }

        // Storage
        let isDefaultRoot =
            settings.storageRoot.standardizedFileURL.path == context.defaultStorageRoot.standardizedFileURL.path
        out["storageRoot"] = .string(isDefaultRoot ? "default" : "custom")
        out["storageVolume"] = .string(context.storageVolume.rawValue)

        // Browsers
        out["firefoxProfileAccess"] = .string(settings.firefoxProfileAccess.rawValue)
        out["firefoxSensorHasConnected"] = .bool(settings.firefoxSensorHasConnected)
        return out
    }

    /// The name a fresh install gives the local speaker.
    static let defaultLocalUserName = AppSettings().localUserName

    /// A model Pipit offers by name, `custom` for anything else, `none` for
    /// nothing chosen.
    static func offered(_ model: String, among choices: [String]) -> String {
        if model.isEmpty { return "none" }
        return choices.contains(model) ? model : "custom"
    }

    /// The titles-and-summaries model as a report may name it.
    ///
    /// OpenAI's is named when it is one of the models Settings lists; a
    /// fine-tuned model's identifier carries the organisation's name and its
    /// own suffix. OpenRouter's is picked from OpenRouter's public catalogue,
    /// whose identifiers are `vendor/model`, and a slash breaks the token
    /// rule, so it is written `vendor:model`. Ollama's and a custom
    /// endpoint's are whatever the person named their model, and are never
    /// sent.
    static func metadataModel(_ model: String, provider: LanguageModelProvider) -> String {
        if model.isEmpty { return "none" }
        switch provider {
        case .openAI:
            return offered(model, among: AIModelSettings.metadataChoices)
        case .openRouter:
            let parts = model.split(separator: "/", omittingEmptySubsequences: false)
            let isCatalogue =
                parts.count == 2
                && parts.allSatisfy { part in
                    !part.isEmpty
                        && part.unicodeScalars.allSatisfy { scalar in
                            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
                                || [".", "-", "_", ":"].contains(scalar)
                        }
                }
            let written = parts.joined(separator: ":")
            return isCatalogue && DiagnosticTokenRule.accepts(written) ? written : "custom"
        case .ollama, .custom:
            return "custom"
        }
    }

    /// The custom endpoint's scheme, `none` when nothing is typed, `other`
    /// for text that is not a web address, and whether it names this Mac.
    static func endpointShape(_ text: String) -> (scheme: String, isLoopback: Bool) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ("none", false) }
        guard let url = EndpointAddress.normalized(text), let scheme = url.scheme?.lowercased() else {
            return ("other", false)
        }
        let host = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.host ?? "").lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let isLoopback = host == "localhost" || host == "::1" || host.hasPrefix("127.")
        return (scheme, isLoopback)
    }

    /// A whole number as an integer, so `30` reads `30`, and anything else to
    /// the millisecond. Settings never hold a value that is not finite; one
    /// would read 0.
    static func number(_ value: Double) -> JSONValue {
        guard value.isFinite else { return .integer(0) }
        if let whole = Int64(exactly: value) { return .integer(whole) }
        return .double((value * 1_000).rounded() / 1_000)
    }
}

// MARK: - permissions

extension DiagnosticSnapshot {
    /// Permission to state, in the names `permission.state` events use.
    public static func permissions(_ statuses: [PermissionStatus]) -> [String: String] {
        var out: [String: String] = [:]
        for status in statuses {
            out[DiagnosticEvent.Permission(status.kind).rawValue] =
                DiagnosticEvent.PermissionGrant(status.state).rawValue
        }
        return out
    }
}

// MARK: - models

/// What one unit's receipt says, without the free-form `detail` it can carry.
public struct DiagnosticModelReceipt: Sendable, Equatable {
    public var revision: String
    public var bytes: Int64

    public init(revision: String, bytes: Int64) {
        self.revision = revision
        self.bytes = bytes
    }
}

/// What model installation is doing as a whole.
public enum DiagnosticModelActivity: Sendable, Equatable {
    case idle
    case installing
    case failed
}

extension DiagnosticSnapshot {
    /// One row per unit that is installed or that the settings need, in
    /// `LocalModelUnit` order.
    ///
    /// `installed` matches this build's pinned revision and `outdated` does
    /// not. A unit the settings need with no receipt is `installing`,
    /// `failed`, or `missing`, from what installation as a whole is doing.
    public static func models(
        receipts: [LocalModelUnit: DiagnosticModelReceipt], required: Set<LocalModelUnit>,
        activity: DiagnosticModelActivity
    ) -> [DiagnosticReport.Model] {
        LocalModelUnit.allCases.compactMap { unit in
            if let receipt = receipts[unit] {
                let isCurrent = receipt.revision == LocalSpeechStack.revision(for: unit)
                return DiagnosticReport.Model(
                    unit: unit.rawValue, state: isCurrent ? "installed" : "outdated",
                    revision: revisionToken(receipt.revision), bytes: Int(clamping: max(0, receipt.bytes))
                )
            }
            guard required.contains(unit) else { return nil }
            let state: String
            switch activity {
            case .idle: state = "missing"
            case .installing: state = "installing"
            case .failed: state = "failed"
            }
            return DiagnosticReport.Model(unit: unit.rawValue, state: state)
        }
    }

    /// A receipt's revision as a token.
    ///
    /// Pipit writes revisions as `<model> @ <package> <version>`, which the
    /// token rule refuses for its spaces and `@`. The `@` and its spaces
    /// become `_` and any other space `-`, so `parakeet-tdt-0.6b-v3-int8 @
    /// FluidAudio 0.15.6` reads `parakeet-tdt-0.6b-v3-int8_FluidAudio-0.15.6`.
    /// What still breaks the rule, a revision past 64 characters among them,
    /// reads `invalid`.
    static func revisionToken(_ revision: String) -> String {
        DiagnosticTokenRule.token(
            revision.replacingOccurrences(of: " @ ", with: "_").replacingOccurrences(of: " ", with: "-")
        )
    }
}

// MARK: - browser add-ons

/// What the browsers section is built from.
public struct DiagnosticBrowserState: Sendable, Equatable {
    /// Each add-on as Pipit last heard from it this launch.
    public var connections: [BrowserKind: BrowserSensorTracker.Connection]
    /// What each add-on said about itself when it connected.
    public var hellos: [BrowserKind: SensorMessage.Hello]
    /// What the Firefox add-on last reported, kept in settings across
    /// launches, for a launch it has not called back in yet.
    public var firefoxLastVersion: String?
    public var firefoxLastProtocol: Int?
    /// Whether Firefox's native messaging host manifest is in place.
    public var firefoxHostManifest: Bool
    /// Each Chromium browser on this Mac by its display name, and whether its
    /// own host manifest is in place. A browser that has never run is left
    /// out.
    public var chromiumHostManifests: [String: Bool]

    public init(
        connections: [BrowserKind: BrowserSensorTracker.Connection] = [:],
        hellos: [BrowserKind: SensorMessage.Hello] = [:], firefoxLastVersion: String? = nil,
        firefoxLastProtocol: Int? = nil, firefoxHostManifest: Bool = false,
        chromiumHostManifests: [String: Bool] = [:]
    ) {
        self.connections = connections
        self.hellos = hellos
        self.firefoxLastVersion = firefoxLastVersion
        self.firefoxLastProtocol = firefoxLastProtocol
        self.firefoxHostManifest = firefoxHostManifest
        self.chromiumHostManifests = chromiumHostManifests
    }
}

extension DiagnosticSnapshot {
    /// One row each for Firefox, Chrome and Safari.
    ///
    /// `state` is `on` while the add-on holds its connection, `off` when it
    /// has not connected this launch, and `disconnected` when it did and the
    /// connection dropped. Versions are the add-on's own, checked against the
    /// version pattern. Safari's extension talks to Pipit without the native
    /// messaging host, so its row has no host fields.
    public static func browserAddOns(_ state: DiagnosticBrowserState) -> [DiagnosticReport.BrowserAddOn] {
        [BrowserKind.firefox, .chrome, .safari].map { browser in
            let hello = state.hellos[browser]
            var row = DiagnosticReport.BrowserAddOn(
                browser: browser.rawValue, state: addOnState(state.connections[browser] ?? .absent)
            )
            var version = hello?.extensionVersion
            var protocolVersion = hello?.protocolVersion
            if browser == .firefox, hello == nil {
                version = state.firefoxLastVersion
                protocolVersion = state.firefoxLastProtocol
            }
            row.addonVersion = version.map { DiagnosticToken.version($0).value }
            row.protocol = protocolVersion
            switch browser {
            case .firefox:
                row.hostVersion = hostVersion(hello)
                row.hostManifest = state.firefoxHostManifest
            case .chrome:
                row.hostVersion = hostVersion(hello)
                row.hostManifest = state.chromiumHostManifests.values.contains(true)
                var manifests: [String: Bool] = [:]
                for (name, present) in state.chromiumHostManifests {
                    manifests[chromiumKey(name)] = present
                }
                row.chromiumHostManifests = manifests
            case .safari, .unknown:
                break
            }
            return row
        }
    }

    static func addOnState(_ connection: BrowserSensorTracker.Connection) -> String {
        switch connection {
        case .fresh, .stale: "on"
        case .absent: "off"
        case .disconnected: "disconnected"
        }
    }

    private static func hostVersion(_ hello: SensorMessage.Hello?) -> String? {
        guard let text = hello?.hostVersion, !text.isEmpty else { return nil }
        return DiagnosticToken.version(text).value
    }

    /// `Chrome Beta` reads `chrome_beta`, `Microsoft Edge` reads
    /// `microsoft_edge`.
    static func chromiumKey(_ name: String) -> String {
        DiagnosticTokenRule.token(name.lowercased().replacingOccurrences(of: " ", with: "_"))
    }
}

// MARK: - storage and failures

extension DiagnosticSnapshot {
    public static func storage(meetings: Int, freeBytes: Int64?) -> DiagnosticReport.Storage {
        DiagnosticReport.Storage(
            meetings: max(0, meetings), freeDisk: DiagnosticDiskSpace(freeBytes: freeBytes).rawValue)
    }

    /// The most recent failures still standing on meetings, newest first.
    ///
    /// A failure's message is never read: it is prose written for the person,
    /// and a few name a file. The code is the one the pipeline recorded with
    /// the failure, or `unknown` for one recorded before codes were kept.
    public static func recentFailures(_ statuses: [ProcessingStatus], limit: Int = 10) -> [DiagnosticReport
        .RecentFailure]
    {
        let failures = statuses.compactMap { status -> DiagnosticReport.RecentFailure? in
            guard let failure = status.lastFailure else { return nil }
            return DiagnosticReport.RecentFailure(
                stage: failure.stage.rawValue,
                code: failure.code?.rawValue ?? "unknown",
                retryable: failure.isRetryable,
                attempts: status.attemptCount(for: failure.stage),
                at: failure.occurredAt
            )
        }
        return Array(
            failures.sorted { lhs, rhs in
                lhs.at != rhs.at ? lhs.at > rhs.at : (lhs.stage, lhs.code) < (rhs.stage, rhs.code)
            }
            .prefix(max(0, limit))
        )
    }
}
