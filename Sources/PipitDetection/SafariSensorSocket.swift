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
        guard let group = SensorTransport.safariAppGroup(in: entitledAppGroups()),
            let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return SensorTransport.safariSocketURL(groupContainer: container)
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
