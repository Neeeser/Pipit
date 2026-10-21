import Foundation
import PipitCore
import Security

/// Where the app listens for its Safari extension.
///
/// The extension runs in Safari's sandbox and can reach only the container of
/// the app group the two are signed into, so the socket lives there rather
/// than beside the one the native messaging host uses.
public enum SafariSensorSocket {
    /// Nil for a build signed without the group, which carries no Safari
    /// extension either: an Xcode run, or a build with signing switched off.
    public static func url() -> URL? {
        groupContainer().map(SensorTransport.safariSocketURL(groupContainer:))
    }

    /// The Safari extension's own diagnostic events,
    /// in the shared container. Only event filenames are read into a report.
    public static func diagnosticsFiles() -> [URL] {
        guard let container = groupContainer() else { return [] }
        let directory = DiagnosticLayout.safariExtension(groupContainer: container).events
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { EventFile(name: $0)?.family == .nativeHost }.sorted()
            .map { directory.appendingPathComponent($0) }
    }

    private static func groupContainer() -> URL? {
        guard let group = SensorTransport.safariAppGroup(in: entitledAppGroups()) else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    /// The groups in this process's own entitlements. Read rather than written
    /// into the source, because a Developer ID build prefixes the group with
    /// the signing team and an ad-hoc build cannot.
    private static func entitledAppGroups() -> [String] {
        guard let task = SecTaskCreateFromSelf(nil) else { return [] }
        let key = "com.apple.security.application-groups" as CFString
        return SecTaskCopyValueForEntitlement(task, key, nil) as? [String] ?? []
    }
}
