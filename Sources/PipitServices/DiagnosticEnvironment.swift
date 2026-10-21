import Foundation
import PipitCore

/// What `app.launched` says about the build and the Mac.
///
/// Read from the bundle, `ProcessInfo` and two sysctl names. Each value is
/// checked against its pattern by `DiagnosticEvent.AppLaunch`, so a bundle
/// that carries something unexpected reads `invalid` rather than passing it on.
/// Nothing here names the person: the hardware is a model identifier such as
/// `Mac15,3`, never the computer's name.
enum DiagnosticEnvironment {
    static func current(bundle: Bundle = .main) -> DiagnosticEvent.AppLaunch {
        let info = bundle.infoDictionary ?? [:]
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var os = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { os += ".\(version.patchVersion)" }
        return DiagnosticEvent.AppLaunch(
            version: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String,
            commit: info["PipitGitCommit"] as? String,
            os: os,
            osBuild: sysctlString("kern.osversion"),
            hardware: sysctlString("hw.model"),
            arch: architecture
        )
    }

    /// The architecture this process runs as, which under Rosetta is not the
    /// Mac's.
    static var architecture: DiagnosticEvent.Architecture {
        #if arch(arm64)
            return .appleSilicon
        #elseif arch(x86_64)
            return .intel
        #else
            return .other
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
