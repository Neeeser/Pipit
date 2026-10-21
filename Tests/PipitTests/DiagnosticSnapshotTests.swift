import Foundation
import Testing

@testable import PipitCore

/// The report's `app`, `system` and `summary` sections, built from values the
/// service layer reads (`docs/DIAGNOSTICS.md`, Settings in a report).
@Suite("Diagnostic snapshot")
struct DiagnosticSnapshotTests {
    static let defaultRoot = URL(fileURLWithPath: "/Users/sample/Pipit", isDirectory: true)

    static func context(volume: DiagnosticStorageVolume = .internal) -> DiagnosticSettingsContext {
        DiagnosticSettingsContext(
            hasOpenAIKey: true, hasOpenRouterKey: false, hasCustomEndpointKey: true, storageVolume: volume,
            defaultStorageRoot: defaultRoot
        )
    }

    /// Settings with a canary in every field a person can type into, and in
    /// every string a field holds that Pipit did not choose.
    static func canarySettings(provider: LanguageModelProvider) -> AppSettings {
        var settings = AppSettings(
            storageRootPath: "/Users/CANARY-sample/Meetings CANARY",
            localUserName: "CANARY Sample Person",
            alwaysRecordApplications: ["com.CANARY.always"],
            neverRecordApplications: ["com.CANARY.never", "com.CANARY.other"],
            setupStepsVisited: ["CANARY-step"],
            firefoxAddOnVersion: "CANARY 1.0",
            lastLaunchedVersion: "CANARY 2.0"
        )
        settings.models.transcription = "CANARY-transcribe"
        settings.models.diarization = "CANARY-diarize"
        settings.models.vocabularyHints = "CANARYword, Sample CANARY\nCANARY Third"
        settings.models.customEndpoint = "https://sample:CANARYsecret@canary-host.example.com:8443/v1?key=CANARY"
        for each in LanguageModelProvider.allCases {
            settings.models.setMetadataModel("CANARY-\(each.rawValue)-model", for: each)
        }
        settings.models.setMetadataModel("ft:gpt-4o:CANARYorg:sample:abc123", for: .openAI)
        settings.models.setMetadataModel("canaryvendor/CANARY-model", for: .openRouter)
        settings.models.metadataProvider = provider
        settings.processing.localUserIdentityID = IdentityID(4_242)
        return settings
    }

    @Test("the settings keys are exactly the documented allowlist")
    func theSettingsKeysAreExactlyTheDocumentedAllowlist() throws {
        let keys = Set(DiagnosticSnapshot.settings(AppSettings(), context: Self.context()).keys)
        let documented: Set<String> = [
            "launchAtLogin", "showNotifications", "showsDockIcon", "receivesBetaUpdates", "hasCompletedOnboarding",
            "transcriptionBackend", "diarizationBackend", "localTranscriptionModel", "cloudTranscriptionModel",
            "recognizeKnownVoices", "rememberRecurringVoices", "learnMyVoice", "learnFromCorrections",
            "hasLocalUserIdentity", "vocabularyHintCount", "metadataProvider", "metadataModel",
            "metadataContextTokens", "hasOpenAIKey", "hasOpenRouterKey", "hasCustomEndpointKey",
            "customEndpointScheme", "customEndpointIsLoopback", "generateTitle", "generateDescription",
            "generateNotes", "generateSummary", "suggestSpeakers", "suggestFolders", "folderReach",
            "filesMatchingMeetings", "noticesRecurringMeetings", "hasLocalUserName", "segmentSeconds",
            "preRollSeconds", "meetingEndGraceSeconds", "meetingReconnectWindowSeconds", "alwaysRecordAppCount",
            "neverRecordAppCount", "detectionPaused", "slackAutoStart", "slackAutoStop", "googleMeetAutoStart",
            "googleMeetAutoStop", "zoomAutoStart", "zoomAutoStop", "faceTimeAutoStart", "faceTimeAutoStop",
            "unknownCallsAutoStart", "unknownCallsAutoStop", "storageRoot", "storageVolume", "firefoxProfileAccess",
            "firefoxSensorHasConnected",
        ]
        #expect(keys == documented)

        // The contract lists the same keys, so the website knows each one.
        let contract = try String(contentsOf: DiagnosticEventTests.contractURL, encoding: .utf8)
        for key in documented {
            #expect(contract.contains("`\(key)`"), "\(key) is missing from docs/DIAGNOSTICS.md")
        }
    }

    @Test("no free text from settings reaches the report, whichever provider is chosen")
    func noFreeTextFromSettingsReachesTheReportWhicheverProviderIsChosen() throws {
        for provider in LanguageModelProvider.allCases {
            let settings = Self.canarySettings(provider: provider)
            let values = DiagnosticSnapshot.settings(settings, context: Self.context())
            let encoded = try #require(
                String(data: try DiagnosticCoding.makeReportEncoder().encode(values), encoding: .utf8)
            )
            #expect(!encoded.lowercased().contains("canary"), "\(provider.rawValue): \(encoded)")
            #expect(!encoded.contains("sample"))

            // What each free-text field became.
            #expect(values["hasLocalUserName"] == .bool(true))
            #expect(values["vocabularyHintCount"] == .integer(3))
            #expect(values["customEndpointScheme"] == .string("https"))
            #expect(values["customEndpointIsLoopback"] == .bool(false))
            #expect(values["storageRoot"] == .string("custom"))
            #expect(values["metadataModel"] == .string("custom"))
            #expect(values["cloudTranscriptionModel"] == .string("custom"))
            #expect(values["alwaysRecordAppCount"] == .integer(1))
            #expect(values["neverRecordAppCount"] == .integer(2))
            #expect(values["hasLocalUserIdentity"] == .bool(true))

            // And the whole report built around them passes the token rule.
            var report = try DiagnosticReport.decode(try Data(contentsOf: DiagnosticsFixtures.report))
            report.summary.settings = values
            #expect(DiagnosticReportValidator.violations(in: report).isEmpty)
        }
    }

    @Test("a model is named only when Pipit offered it")
    func aModelIsNamedOnlyWhenPipitOfferedIt() {
        func model(_ name: String, _ provider: LanguageModelProvider) -> String {
            DiagnosticSnapshot.metadataModel(name, provider: provider)
        }
        #expect(model("gpt-5.1-mini", .openAI) == "gpt-5.1-mini")
        #expect(model("gpt-4o-2024-08-06", .openAI) == "custom")
        #expect(model("", .openAI) == "none")
        #expect(model("openai/gpt-5.1", .openRouter) == "openai:gpt-5.1")
        #expect(
            model("meta-llama/llama-3.3-70b-instruct:free", .openRouter) == "meta-llama:llama-3.3-70b-instruct:free")
        #expect(model("Sample Model", .openRouter) == "custom")
        #expect(model("a/b/c", .openRouter) == "custom")
        #expect(model("llama3.1:8b", .ollama) == "custom")
        #expect(model("gpt-5.1", .custom) == "custom")

        var settings = AppSettings()
        settings.models.transcription = AIModelSettings.transcriptionChoices[1]
        let values = DiagnosticSnapshot.settings(settings, context: Self.context())
        #expect(values["cloudTranscriptionModel"] == .string(AIModelSettings.transcriptionChoices[1]))
        #expect(values["metadataModel"] == .string(AIModelSettings.defaultMetadataModel))
    }

    @Test("the custom endpoint is its scheme and whether it is this Mac")
    func theCustomEndpointIsItsSchemeAndWhetherItIsThisMac() {
        let cases: [(String, String, Bool)] = [
            ("", "none", false),
            ("   ", "none", false),
            ("not an address", "other", false),
            ("http://localhost:1234/v1", "http", true),
            ("http://127.0.0.1:8080", "http", true),
            ("http://[::1]:8080/v1/chat/completions", "http", true),
            ("https://gateway.example.com/v1", "https", false),
            ("http://192.168.1.20:11434", "http", false),
        ]
        for (text, scheme, loopback) in cases {
            let shape = DiagnosticSnapshot.endpointShape(text)
            #expect(shape.scheme == scheme, "\(text)")
            #expect(shape.isLoopback == loopback, "\(text)")
        }
    }

    @Test("defaults read as defaults")
    func defaultsReadAsDefaults() {
        var settings = AppSettings()
        settings.storageRootPath = Self.defaultRoot.path
        let values = DiagnosticSnapshot.settings(settings, context: Self.context(volume: .cloudSynced))
        #expect(values["storageRoot"] == .string("default"))
        #expect(values["storageVolume"] == .string("cloud_synced"))
        #expect(values["hasLocalUserName"] == .bool(false))
        #expect(values["segmentSeconds"] == .integer(30))
        #expect(values["faceTimeAutoStart"] == .string("ask"))
        #expect(values["slackAutoStop"] == .bool(true))
        #expect(values["customEndpointScheme"] == .string("none"))
        #expect(values["hasOpenAIKey"] == .bool(true))
        #expect(values["hasOpenRouterKey"] == .bool(false))
        #expect(DiagnosticSnapshot.number(2.5) == .double(2.5))
        #expect(DiagnosticSnapshot.number(.infinity) == .integer(0))
    }

    @Test("free disk is a bucket")
    func freeDiskIsABucket() {
        let gigabyte: Int64 = 1_000_000_000
        #expect(DiagnosticDiskSpace(freeBytes: nil) == .unknown)
        #expect(DiagnosticDiskSpace(freeBytes: 0).rawValue == "lt5GB")
        #expect(DiagnosticDiskSpace(freeBytes: 5 * gigabyte - 1).rawValue == "lt5GB")
        #expect(DiagnosticDiskSpace(freeBytes: 5 * gigabyte).rawValue == "5-20GB")
        #expect(DiagnosticDiskSpace(freeBytes: 20 * gigabyte).rawValue == "20-100GB")
        #expect(DiagnosticDiskSpace(freeBytes: 100 * gigabyte).rawValue == "gt100GB")
        for bucket in DiagnosticDiskSpace.allCases {
            #expect(DiagnosticTokenRule.accepts(bucket.rawValue))
        }
    }

    @Test("the meetings folder's volume is classified without its path")
    func theMeetingsFoldersVolumeIsClassifiedWithoutItsPath() {
        let home = URL(fileURLWithPath: "/Users/sample", isDirectory: true)
        func classify(
            _ path: String, ubiquitous: Bool? = false, local: Bool? = true, isInternal: Bool? = true
        ) -> DiagnosticStorageVolume {
            DiagnosticStorageVolume.classify(
                folder: URL(fileURLWithPath: path), home: home, isUbiquitous: ubiquitous, isLocal: local,
                isInternal: isInternal
            )
        }
        #expect(classify("/Users/sample/Pipit") == .internal)
        #expect(classify("/Users/sample/Library/Mobile Documents/com~apple~CloudDocs/Pipit") == .cloudSynced)
        #expect(classify("/Users/sample/Library/CloudStorage/Dropbox/Pipit") == .cloudSynced)
        #expect(classify("/Users/sample/Library/CloudStorageOther/Pipit") == .internal)
        #expect(classify("/Users/sample/Documents/Pipit", ubiquitous: true) == .cloudSynced)
        #expect(classify("/Volumes/Share/Pipit", local: false, isInternal: false) == .network)
        #expect(classify("/Volumes/Disk/Pipit", isInternal: false) == .external)
        #expect(classify("/Volumes/Disk/Pipit", ubiquitous: nil, local: nil, isInternal: nil) == .unknown)
    }

    @Test("app and system come from the launch's own tokens")
    func appAndSystemComeFromTheLaunchsOwnTokens() {
        let launch = DiagnosticEvent.AppLaunch(
            version: "0.1.9-dev.abc1234", build: "815", commit: "9e8e301640b62399dfabc104e5252138a5f09925",
            os: "15.6.1", osBuild: "24G90", hardware: "Mac15,3", arch: .appleSilicon
        )
        let app = DiagnosticSnapshot.app(launch, isDebugBuild: true)
        #expect(
            app
                == .init(
                    version: "0.1.9-dev.abc1234", build: 815, commit: launch.commit.value, channel: "dev",
                    configuration: "debug"))
        let release = DiagnosticEvent.AppLaunch(
            version: "0.1.8", build: nil, commit: nil, os: nil, osBuild: nil, hardware: "Sample Mac", arch: .intel
        )
        #expect(DiagnosticSnapshot.app(release, isDebugBuild: false).channel == "release")
        #expect(DiagnosticSnapshot.app(release, isDebugBuild: false).build == 0)
        let beta = DiagnosticEvent.AppLaunch(
            version: "0.2.0-beta.1", build: "9", commit: nil, os: nil, osBuild: nil, hardware: nil, arch: .other
        )
        #expect(DiagnosticSnapshot.app(beta, isDebugBuild: false).channel == "prerelease")

        let system = DiagnosticSnapshot.system(
            launch, physicalMemory: 17_179_869_184, cpuCores: 8, freeBytes: 42_000_000_000,
            preferredLanguage: "en-GB"
        )
        #expect(
            system
                == .init(
                    os: "15.6.1", osBuild: "24G90", hardware: "Mac15,3", arch: "arm64", memoryGB: 16, cpuCores: 8,
                    freeDisk: "20-100GB", language: "en"
                )
        )
        #expect(
            DiagnosticSnapshot.system(release, physicalMemory: 0, cpuCores: 4, freeBytes: nil, preferredLanguage: nil)
                .hardware == "invalid")
        #expect(DiagnosticSnapshot.languageCode("zh-Hant-TW") == "zh")
        #expect(DiagnosticSnapshot.languageCode("pt_BR") == "pt")
        #expect(DiagnosticSnapshot.languageCode("Sample Person") == "unknown")
        #expect(DiagnosticSnapshot.languageCode("") == "unknown")
    }

    @Test("permissions use the event's names")
    func permissionsUseTheEventsNames() {
        let statuses = [
            PermissionStatus(kind: .microphone, state: .granted),
            PermissionStatus(kind: .screenRecording, state: .grantedButNotEffective),
            PermissionStatus(kind: .accessibility, state: .denied),
            PermissionStatus(kind: .calendar, state: .notDetermined),
        ]
        #expect(
            DiagnosticSnapshot.permissions(statuses) == [
                "microphone": "granted", "system_audio": "restricted", "accessibility": "denied",
                "calendar": "not_determined",
            ]
        )
    }

    @Test("models carry their state, a checked revision and their size")
    func modelsCarryTheirStateACheckedRevisionAndTheirSize() {
        let receipts: [LocalModelUnit: DiagnosticModelReceipt] = [
            .parakeet: .init(revision: LocalSpeechStack.revision(for: .parakeet), bytes: 482_345_678),
            .diarizer: .init(revision: "FluidAudio 0.14.0", bytes: 32_145_678),
            .whisper: .init(revision: "/Users/sample/Library/model @ Sample Package", bytes: 10),
        ]
        let rows = DiagnosticSnapshot.models(
            receipts: receipts, required: [.parakeet, .diarizer, .voiceActivity], activity: .installing
        )
        #expect(
            rows == [
                .init(unit: "whisper", state: "outdated", revision: "invalid", bytes: 10),
                .init(
                    unit: "parakeet", state: "installed", revision: "parakeet-tdt-0.6b-v3-int8_FluidAudio-0.15.6",
                    bytes: 482_345_678
                ),
                .init(unit: "diarizer", state: "outdated", revision: "FluidAudio-0.14.0", bytes: 32_145_678),
                .init(unit: "voice-activity", state: "installing"),
            ]
        )
        #expect(
            DiagnosticSnapshot.models(receipts: [:], required: [.diarizer], activity: .idle) == [
                .init(unit: "diarizer", state: "missing")
            ]
        )
        #expect(DiagnosticSnapshot.models(receipts: [:], required: [.diarizer], activity: .failed)[0].state == "failed")
        // Every revision this build writes survives, whisper's without the
        // prefix that took it past the token rule's length.
        for unit in LocalModelUnit.allCases {
            #expect(DiagnosticSnapshot.revisionToken(LocalSpeechStack.revision(for: unit)) != "invalid", "\(unit)")
        }
        #expect(
            DiagnosticSnapshot.revisionToken(LocalSpeechStack.revision(for: .whisper))
                == "large-v3-v20240930_turbo_632MB_argmax-oss-swift-1.1.0"
        )
        #expect(
            DiagnosticSnapshot.revisionToken("openai_whisper-small @ argmax-oss-swift 0.9.0")
                == "small_argmax-oss-swift-0.9.0"
        )
    }

    @Test("each browser's add-on is on, off or disconnected, with its own versions")
    func eachBrowsersAddOnIsOnOffOrDisconnectedWithItsOwnVersions() {
        let state = DiagnosticBrowserState(
            connections: [.firefox: .fresh, .chrome: .disconnected, .safari: .stale],
            hellos: [
                .chrome: .init(browser: .chrome, extensionVersion: "1.0.1", hostVersion: "1.1.0", protocolVersion: 2),
                .safari: .init(browser: .safari, extensionVersion: "Sample Person's build", hostVersion: ""),
            ],
            firefoxLastVersion: "1.0.0", firefoxLastProtocol: 1, firefoxHostManifest: true,
            chromiumHostManifests: ["Chrome": true, "Microsoft Edge": false, "Chrome Beta": false]
        )
        let rows = DiagnosticSnapshot.browserAddOns(state)
        #expect(
            rows == [
                .init(browser: "firefox", state: "on", addonVersion: "1.0.0", protocol: 1, hostManifest: true),
                .init(
                    browser: "chrome", state: "disconnected", addonVersion: "1.0.1", hostVersion: "1.1.0", protocol: 2,
                    hostManifest: true,
                    chromiumHostManifests: ["chrome": true, "microsoft_edge": false, "chrome_beta": false]
                ),
                .init(browser: "safari", state: "on", addonVersion: "invalid"),
            ]
        )
        let none = DiagnosticSnapshot.browserAddOns(DiagnosticBrowserState())
        #expect(none.map(\.state) == ["off", "off", "off"])
        #expect(none[1].hostManifest == false)
        #expect(none[1].chromiumHostManifests == [:])
    }

    @Test("recent failures carry the code, never the message")
    func recentFailuresCarryTheCodeNeverTheMessage() throws {
        let older = Date(timeIntervalSince1970: 1_792_500_000)
        let newer = older.addingTimeInterval(600)
        var first = ProcessingStatus()
        first.recordAttempt(for: .enriching)
        first.recordAttempt(for: .enriching)
        first.recordFailure(
            ProcessingFailure(
                stage: .enriching, message: "CANARY could not reach /Users/sample/server", isRetryable: true,
                occurredAt: newer, code: DiagnosticCode("language_model", "unreachable")
            ),
            at: newer
        )
        var second = ProcessingStatus()
        second.recordFailure(
            ProcessingFailure(stage: .finalizing, message: "CANARY", isRetryable: false, occurredAt: older),
            at: older
        )
        let rows = DiagnosticSnapshot.recentFailures([second, ProcessingStatus(), first])
        #expect(
            rows == [
                .init(stage: "enriching", code: "language_model.unreachable", retryable: true, attempts: 2, at: newer),
                .init(stage: "finalizing", code: "unknown", retryable: false, attempts: 0, at: older),
            ]
        )
        #expect(DiagnosticSnapshot.recentFailures([first, second], limit: 1).count == 1)
        let encoded = try DiagnosticCoding.makeReportEncoder().encode(rows)
        #expect(!(String(data: encoded, encoding: .utf8) ?? "").contains("CANARY"))

        // A failure written by an older build, with no code, still decodes.
        let legacy = #"{"stage":"transcribing","message":"x","isRetryable":true,"occurredAt":"2026-10-21T03:18:16Z"}"#
        let decoded = try DiagnosticCoding.makeDecoder().decode(ProcessingFailure.self, from: Data(legacy.utf8))
        #expect(decoded.code == nil)
    }
}
