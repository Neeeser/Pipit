import Foundation
import PipitCore
import SafariServices
import Security

/// Safari's half of the browser sensor.
///
/// Firefox and Chrome start `pipit-nativehost` and hold it open. Safari starts
/// nothing: it hands each message the add-on sends to this app extension,
/// bundled inside Pipit.app, and may stop the process between messages. The
/// extension relays what it is given to the app's socket and answers whether
/// it got there.
///
/// Safari runs app extensions in a sandbox, so the socket in Application
/// Support is out of reach. The app listens on a second socket inside the app
/// group the two share, and this connects there.
@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let groupContainer: URL? = {
        guard let group = SensorTransport.safariAppGroup(in: entitledAppGroups()) else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }()

    /// Reuse a connection while Safari keeps this relay process alive.
    private static let connection = groupContainer.map {
        SensorAppConnection(socketPath: SensorTransport.safariSocketURL(groupContainer: $0).path)
    }

    private static let diagnostics: DiagnosticLog = {
        guard let groupContainer else { return .disabled }
        let log = DiagnosticLog(
            layout: .safariExtension(groupContainer: groupContainer), configuration: .safariExtension
        )
        log.record(.nativeHostStarted(browser: .safari))
        return log
    }()

    private static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let raw = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        var delivered = false
        if let raw, let connection = Self.connection,
            let message = SensorRelay.message(from: raw, browser: .safari, hostVersion: Self.version)
        {
            // Pipit may have restarted since the last request. Watching first
            // drops a socket the app has closed, and reconnecting greets the
            // app with the add-on's last hello.
            connection.watch()
            delivered = connection.deliver(message)
            if !delivered {
                Self.diagnostics.record(
                    .nativeHostAppUnreachable(
                        code: .error(domain: NSPOSIXErrorDomain, code: Int(connection.lastConnectError))
                    )
                )
            }
        } else if raw != nil {
            Self.diagnostics.record(.browserMessageUnparsable(browser: .safari))
        }
        // Safari may stop this relay as soon as the request completes. Bound
        // the wait so a diagnostic write cannot hold the message indefinitely.
        Self.diagnostics.flush(timeout: 0.1)
        let reply = NSExtensionItem()
        reply.userInfo = [SFExtensionMessageKey: ["type": "ack", "connected": delivered]]
        context.completeRequest(returningItems: [reply], completionHandler: nil)
    }

    /// The app groups this process is signed into, read from its own
    /// entitlements so the team identifier in front of the group never has to
    /// be written into the source.
    private static func entitledAppGroups() -> [String] {
        guard let task = SecTaskCreateFromSelf(nil) else { return [] }
        let key = "com.apple.security.application-groups" as CFString
        return SecTaskCopyValueForEntitlement(task, key, nil) as? [String] ?? []
    }
}
