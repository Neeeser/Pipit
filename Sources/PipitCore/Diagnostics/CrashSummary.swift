import Foundation

/// A crash, reduced to what a diagnostic report may carry
/// (`docs/DIAGNOSTICS.md`, Crash summaries).
///
/// The faulting thread's frames as image and offset, and the images those
/// frames name. That is enough to symbolicate with the release dSYMs and
/// nothing more: no symbol names, thread names, paths, exception reasons,
/// register state, or the per-device `crashReporterKey`. Every string passes
/// `DiagnosticTokenRule`.
public struct CrashSummary: Codable, Sendable, Equatable {
    /// The contract's `class`. Only `crash` is produced today: see
    /// `CrashReportReducer` for why hang reports are not read.
    public enum Kind: String, Codable, Sendable {
        case crash
        case hang
    }

    public struct App: Codable, Sendable, Equatable {
        public var version: String
        /// The bundle's `CFBundleVersion`, which Pipit always stamps as a
        /// whole number. 0 when the report gave none.
        public var build: Int

        public init(version: String, build: Int) {
            self.version = version
            self.build = build
        }
    }

    /// One frame of the faulting thread. `image` indexes `images` of the same
    /// summary, not the report's own image list.
    public struct Frame: Codable, Sendable, Equatable {
        public var image: Int
        public var offset: Int

        public init(image: Int, offset: Int) {
            self.image = image
            self.offset = offset
        }
    }

    public struct Image: Codable, Sendable, Equatable {
        /// The binary's own name for an image in Pipit's bundle, `/System/`,
        /// or `/usr/lib/`, and `other` for everything else.
        public var name: String
        /// The build UUID, lowercase. Left out for an `other` image: no dSYM
        /// of ours resolves it, and the UUID of someone's audio plug-in or
        /// input method says what they have installed.
        public var uuid: String?
        public var arch: String
        public var base: Int

        public init(name: String, uuid: String?, arch: String, base: Int) {
            self.name = name
            self.uuid = uuid
            self.arch = arch
            self.base = base
        }
    }

    /// The name an image outside Pipit's bundle and the system takes.
    public static let otherImage = "other"
    /// The most frames a summary keeps, counted from the top of the stack.
    public static let maximumFrames = 128

    /// The report's incident identifier, lowercase.
    public var incident: String
    public var kind: Kind
    /// Which of Pipit's executables crashed.
    public var process: PipitProcess
    public var occurredAt: Date
    public var app: App
    public var os: String
    public var osBuild: String
    /// The Mach exception, such as `EXC_BAD_ACCESS`. Left out when the
    /// report names none.
    public var exceptionType: String?
    /// The BSD signal, such as `SIGSEGV`.
    public var signal: String?
    /// `<namespace>.<code>`, such as `SIGNAL.11`.
    public var termination: String?
    /// The faulting thread's index among the report's threads.
    public var faultingThread: Int?
    public var frames: [Frame]
    public var images: [Image]

    public init(
        incident: String, kind: Kind, process: PipitProcess, occurredAt: Date, app: App, os: String, osBuild: String,
        exceptionType: String?, signal: String?, termination: String?, faultingThread: Int?,
        frames: [Frame], images: [Image]
    ) {
        self.incident = incident
        self.kind = kind
        self.process = process
        self.occurredAt = occurredAt
        self.app = app
        self.os = os
        self.osBuild = osBuild
        self.exceptionType = exceptionType
        self.signal = signal
        self.termination = termination
        self.faultingThread = faultingThread
        self.frames = frames
        self.images = images
    }

    private enum CodingKeys: String, CodingKey {
        case incident
        case kind = "class"
        case process, occurredAt, app, os, osBuild, exceptionType, signal, termination, faultingThread, frames, images
    }
}

/// The executables Pipit ships, which are the only processes whose crash
/// reports it reads.
public enum PipitProcess: String, Codable, Sendable, CaseIterable {
    case app
    case nativeHost = "nativehost"
    case commandLine = "cli"
    case safariExtension = "safari_extension"

    /// The executable's file name, which is also how ReportCrash names the
    /// report: `<name>-<date>.ips`.
    public var executableName: String {
        switch self {
        case .app: "Pipit"
        case .nativeHost: "pipit-nativehost"
        case .commandLine: "pipit-cli"
        case .safariExtension: "PipitSafariExtension"
        }
    }

    /// The bundle or code-signing identifier, from `App/Info.plist`,
    /// `App/SafariExtension/Info.plist`, `project.yml`, and
    /// `scripts/bundle-app.sh`.
    public var identifier: String {
        switch self {
        case .app: "com.pipit.app"
        case .nativeHost: "com.pipit.nativehost"
        case .commandLine: "com.pipit.cli"
        case .safariExtension: "com.pipit.app.safari-extension"
        }
    }

    /// The process a crash report belongs to. A report that names a bundle
    /// identifier is Pipit's only when the identifier is; a report without
    /// one, from a build run straight out of `.build`, is matched by name.
    static func matching(name: String?, identifier: String?) -> PipitProcess? {
        if let identifier, !identifier.isEmpty {
            return allCases.first { $0.identifier == identifier }
        }
        guard let name else { return nil }
        return allCases.first { $0.executableName == name }
    }
}

/// A reduced crash as Pipit keeps it in `crashes/<incident>.json`: the summary
/// a report carries, and the pid, launch time, and executable UUID that match
/// it to a launch record on this Mac. The bundle builder sends only `summary`.
public struct CrashRecord: Codable, Sendable, Equatable {
    public var pid: Int32
    /// When the crashed process started, from the report's `procLaunch`.
    public var launchedAt: Date?
    /// The UUID of the crashed process's own executable, lowercase.
    public var binaryUUID: String?
    public var summary: CrashSummary

    public init(
        pid: Int32, launchedAt: Date?, binaryUUID: String?, summary: CrashSummary
    ) {
        self.pid = pid
        self.launchedAt = launchedAt
        self.binaryUUID = binaryUUID
        self.summary = summary
    }

    public var incident: String { summary.incident }
    public var process: PipitProcess { summary.process }
}
