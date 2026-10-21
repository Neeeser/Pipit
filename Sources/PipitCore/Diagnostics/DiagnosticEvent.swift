import Foundation

/// One line of the diagnostic event log.
///
/// The line is the contract in `docs/DIAGNOSTICS.md`: `v`, `t`, `launch`,
/// `session`, `job`, `kind`, `p` and `n`. Every payload value is an enum's raw
/// value, an integer, a finite double, a boolean, or a `DiagnosticToken`, so
/// free text has no field to arrive through. A new kind goes into the contract
/// first, then into `Kind`, with a test that encodes it.
///
/// `n` says how many identical events the line stands for. The recorder writes
/// the first of a burst at once and the rest as one line carrying `n` when the
/// 60 second window closes, so the count over a file is the sum of `n`, with a
/// line that has none counting once.
public struct DiagnosticEvent: Hashable, Sendable {
    public static let schemaVersion = 1

    public var time: Date
    public var launch: DiagnosticLaunchID
    public var session: DiagnosticSessionID?
    public var job: DiagnosticJobID?
    public var kind: Kind
    /// How many identical events this line stands for.
    public var count: Int

    public init(
        time: Date, launch: DiagnosticLaunchID, session: DiagnosticSessionID? = nil,
        job: DiagnosticJobID? = nil, kind: Kind, count: Int = 1
    ) {
        self.time = time
        self.launch = launch
        self.session = session
        self.job = job
        self.kind = kind
        self.count = max(1, count)
    }
}

// MARK: - kinds

extension DiagnosticEvent {
    /// Every kind in schema 1, with its payload.
    public enum Kind: Hashable, Sendable {
        case appLaunched(AppLaunch)
        case appTerminated
        case appPreviousExit(exitClass: ExitClass, previousLaunch: DiagnosticLaunchID?)
        case permissionState(permission: Permission, state: PermissionGrant)
        case detectionMeeting(source: MeetingSource, evidence: Evidence, browser: BrowserKind?)
        case sessionStarted(source: MeetingSource, trigger: StartTrigger, segmentSeconds: Double)
        case sessionStopped(trigger: StopTrigger, seconds: Double, segments: Int)
        /// `targets` is the number of processes a remote bind tapped, and nil
        /// for the microphone.
        case captureBound(
            track: CaptureTrack, transport: Transport, sampleRate: Double, channels: Int, targets: Int?
        )
        case captureRestarted(track: CaptureTrack, reason: RestartReason, count: Int)
        case captureHealth(track: CaptureTrack, state: CaptureHealthState)
        /// `code` is the warning's `dedupKey`.
        case captureWarning(code: DiagnosticToken)
        case processingStageStarted(stage: ProcessingState, attempt: Int)
        case processingStageFinished(stage: ProcessingState, attempt: Int, seconds: Double)
        case processingStageFailed(stage: ProcessingState, attempt: Int, code: DiagnosticCode, retryable: Bool)
        case modelInstallStarted(unit: LocalModelUnit)
        case modelInstallFinished(unit: LocalModelUnit, bytes: Int64, seconds: Double)
        case modelInstallFailed(unit: LocalModelUnit, code: DiagnosticCode)
        case updateChecked(outcome: UpdateOutcome, code: DiagnosticCode?)
        case browserAddonConnected(
            browser: BrowserKind, addonVersion: DiagnosticToken, hostVersion: DiagnosticToken,
            protocolVersion: Int?
        )
        case browserAddonDisconnected(browser: BrowserKind, reason: DisconnectReason)
        case browserConnectionRejected(browser: BrowserKind?, reason: RejectionReason)
        case browserMessageUnparsable(browser: BrowserKind)
        case nativeHostStarted(browser: BrowserKind)
        case nativeHostAppUnreachable(code: DiagnosticCode)
        case nativeHostExited(reason: HostExitReason, relayed: Int)
        /// Events lost to a full queue or a failed write.
        case diagnosticsDropped(count: Int)
        case reportSent(kind: ReportKind, bytes: Int, outcome: ReportOutcome, status: Int?)

        public var name: String {
            switch self {
            case .appLaunched: "app.launched"
            case .appTerminated: "app.terminated"
            case .appPreviousExit: "app.previous_exit"
            case .permissionState: "permission.state"
            case .detectionMeeting: "detection.meeting"
            case .sessionStarted: "session.started"
            case .sessionStopped: "session.stopped"
            case .captureBound: "capture.bound"
            case .captureRestarted: "capture.restarted"
            case .captureHealth: "capture.health"
            case .captureWarning: "capture.warning"
            case .processingStageStarted: "processing.stage_started"
            case .processingStageFinished: "processing.stage_finished"
            case .processingStageFailed: "processing.stage_failed"
            case .modelInstallStarted: "model.install_started"
            case .modelInstallFinished: "model.install_finished"
            case .modelInstallFailed: "model.install_failed"
            case .updateChecked: "update.checked"
            case .browserAddonConnected: "browser.addon_connected"
            case .browserAddonDisconnected: "browser.addon_disconnected"
            case .browserConnectionRejected: "browser.connection_rejected"
            case .browserMessageUnparsable: "browser.message_unparsable"
            case .nativeHostStarted: "nativehost.started"
            case .nativeHostAppUnreachable: "nativehost.app_unreachable"
            case .nativeHostExited: "nativehost.exited"
            case .diagnosticsDropped: "diagnostics.dropped"
            case .reportSent: "report.sent"
            }
        }

        /// Events after which the file is synced to disk: the two ends of a
        /// recording, a failure, and a clean exit. Everything else is appended
        /// without an fsync and can be lost with the last seconds before a
        /// power cut.
        public var isDurabilityPoint: Bool {
            switch self {
            case .sessionStarted, .sessionStopped, .processingStageFailed, .modelInstallFailed,
                .appTerminated, .nativeHostExited, .appPreviousExit:
                true
            case .updateChecked(let outcome, _):
                outcome == .failed
            case .appLaunched, .permissionState, .detectionMeeting, .captureBound, .captureRestarted,
                .captureHealth, .captureWarning, .processingStageStarted, .processingStageFinished,
                .modelInstallStarted, .modelInstallFinished, .browserAddonConnected,
                .browserAddonDisconnected, .browserConnectionRejected, .browserMessageUnparsable,
                .nativeHostStarted, .nativeHostAppUnreachable, .diagnosticsDropped, .reportSent:
                false
            }
        }
    }

    /// What `app.launched` says about the build and the Mac.
    public struct AppLaunch: Hashable, Sendable {
        public var version: DiagnosticToken
        public var build: DiagnosticToken
        public var commit: DiagnosticToken
        public var os: DiagnosticToken
        public var osBuild: DiagnosticToken
        public var hardware: DiagnosticToken
        public var arch: Architecture

        /// Each string is checked against its pattern here, so whatever the
        /// bundle or the kernel said, only a matching value is kept.
        public init(
            version: String?, build: String?, commit: String?, os: String?, osBuild: String?,
            hardware: String?, arch: Architecture
        ) {
            self.version = .version(version)
            self.build = .version(build)
            self.commit = .commit(commit)
            self.os = .version(os)
            self.osBuild = .version(osBuild)
            self.hardware = .hardware(hardware)
            self.arch = arch
        }
    }

    public enum Architecture: String, Sendable, CaseIterable {
        case appleSilicon = "arm64"
        case intel = "x86_64"
        case other
    }

    /// How the previous launch ended, decided at the next launch.
    /// The classifier's own type, so the event and the classification
    /// cannot name an exit differently.
    public typealias ExitClass = PipitCore.ExitClass

    public enum Permission: String, Sendable, CaseIterable {
        case microphone
        case systemAudio = "system_audio"
        case accessibility
        case calendar
        case notifications

        public init(_ kind: PermissionKind) {
            switch kind {
            case .microphone: self = .microphone
            case .screenRecording: self = .systemAudio
            case .accessibility: self = .accessibility
            case .calendar: self = .calendar
            case .notifications: self = .notifications
            }
        }
    }

    public enum PermissionGrant: String, Sendable, CaseIterable {
        case granted
        case denied
        case notDetermined = "not_determined"
        case restricted

        /// A grant System Settings shows as on that the running build cannot
        /// use is `restricted`: present, and not usable.
        public init(_ state: PermissionState) {
            switch state {
            case .granted: self = .granted
            case .denied: self = .denied
            case .notDetermined: self = .notDetermined
            case .grantedButNotEffective: self = .restricted
            }
        }
    }

    /// What told Pipit a meeting had begun.
    public enum Evidence: String, Sendable, CaseIterable {
        case browserAddon = "browser_addon"
        case windowTitle = "window_title"
        case accessibility
        case processAudio = "process_audio"
        case slack
    }

    public enum StartTrigger: String, Sendable, CaseIterable {
        /// Detection started it.
        case auto
        case manual
        case imported = "import"
        /// The call came back inside the reconnect window and the same
        /// recording carried on.
        case reconnect
    }

    public enum StopTrigger: String, Sendable, CaseIterable {
        case auto
        case manual
        case quit
        case error
    }

    /// How the input device is attached, which is what a capture problem
    /// usually turns on. The device's name and UID are never recorded: a name
    /// is often the owner's ("Sample Person's AirPods").
    public enum Transport: String, Sendable, CaseIterable {
        case builtIn = "built_in"
        case usb
        case bluetooth
        case aggregate
        case virtual
        case other

        /// From CoreAudio's `kAudioDevicePropertyTransportType`. The constants
        /// are four-character codes, spelled out so this needs no CoreAudio
        /// import.
        public init(coreAudioTransportType value: UInt32) {
            switch value {
            case Self.fourCC("bltn"): self = .builtIn
            case Self.fourCC("usb "): self = .usb
            case Self.fourCC("blue"), Self.fourCC("blea"): self = .bluetooth
            case Self.fourCC("grup"), Self.fourCC("fgrp"): self = .aggregate
            case Self.fourCC("virt"): self = .virtual
            default: self = .other
            }
        }

        static func fourCC(_ text: String) -> UInt32 {
            text.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
    }

    /// The manifest `capture_restart` reason without its measurements, which
    /// are numbers inside a string.
    public enum RestartReason: String, Sendable, CaseIterable {
        case sessionStart = "session_start"
        case configurationChange = "config_change"
        case watchdog
        case noFirstBuffer = "no_first_buffer"
        case wake
        case manual
        case targetChanged = "target_changed"
        case targetAppeared = "target_appeared"
        case producingWithoutCallbacks = "producing_without_callbacks"
        case silentWhileProducing = "silent_while_producing"

        public init(_ reason: RebuildReason) {
            switch reason {
            case .sessionStart: self = .sessionStart
            case .configurationChange: self = .configurationChange
            case .watchdog: self = .watchdog
            case .noFirstBuffer: self = .noFirstBuffer
            case .wake: self = .wake
            case .manual: self = .manual
            case .targetChanged: self = .targetChanged
            case .targetAppeared: self = .targetAppeared
            case .producingWithoutCallbacks: self = .producingWithoutCallbacks
            case .silentWhileProducing: self = .silentWhileProducing
            }
        }
    }

    public enum UpdateOutcome: String, Sendable, CaseIterable {
        case upToDate = "up_to_date"
        case available
        case failed
    }

    public enum DisconnectReason: String, Sendable, CaseIterable {
        /// Safari's add-on stopped saying hello.
        case silence
        /// The relay said goodbye, or every relay's connection closed.
        case closed
        case error
    }

    public enum RejectionReason: String, Sendable, CaseIterable {
        /// The peer was not Pipit's own relay or Safari extension.
        case peerVerification = "peer_verification"
        case capacity
        /// The peer broke the wire format: a line past the buffer limit, or a
        /// message for a different browser than the connection is for.
        case protocolViolation = "protocol"
    }

    public enum HostExitReason: String, Sendable, CaseIterable {
        case browserClosed = "browser_closed"
        case appClosed = "app_closed"
        case error
    }

    public enum ReportKind: String, Sendable, CaseIterable {
        case user
        case crash
        case automatic
    }

    public enum ReportOutcome: String, Sendable, CaseIterable {
        case accepted
        case replayed
        case rejected
        case failed
    }
}
