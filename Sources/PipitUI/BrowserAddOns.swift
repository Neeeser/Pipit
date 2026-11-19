import AppKit
import PipitCore
import PipitDetection
import SafariServices
import SwiftUI

/// Getting the sensor add-on into Safari.
///
/// Safari loads web extensions only from an app extension inside an
/// application, so the add-on ships inside Pipit.app and Safari lists it as
/// soon as Pipit has run. The person still turns it on in Safari's own
/// settings and allows it on the meeting sites; Pipit can open that page and
/// nothing more.
public enum SafariAddOn {
    /// Whether this build carries the extension. Only the bundle
    /// scripts/bundle-app.sh assembles does.
    static var isBundled: Bool { SensorPeerVerifier.safariExtension() != nil }

    /// Opens Safari's Extensions settings with Pipit's extension selected.
    static func openSettings() {
        SFSafariApplication.showPreferencesForExtension(
            withIdentifier: SensorTransport.safariExtensionBundleIdentifier
        ) { _ in }
    }

    /// Whether Safari has the extension switched on, which holds with Safari
    /// closed. The sensor connection cannot say: Safari starts the extension
    /// only while it has a page open. Nil when this build carries no extension
    /// or Safari gave no answer.
    static func isEnabled() async -> Bool? {
        guard isBundled else { return nil }
        return await enabledState(identifier: SensorTransport.safariExtensionBundleIdentifier)
    }

    /// Safari's answer for one extension identifier.
    ///
    /// Uses the async form. The SDK marks the completion-handler form's reply
    /// as main-actor, but Safari delivers it on its own queue, so a Swift
    /// closure passed there made the runtime trap the app.
    public static func enabledState(identifier: String) async -> Bool? {
        try? await SFSafariExtensionManager.stateOfSafariExtension(withIdentifier: identifier).isEnabled
    }
}

/// What the Safari and Chrome cards report.
///
/// Simpler than Firefox's: Chrome keeps no add-on list Pipit could read, so the
/// add-on talking to Pipit is the whole answer. Safari adds one fact, whether it
/// has the extension switched on, because the extension only talks while Safari
/// has a page open.
public enum BrowserAddOnState: Equatable {
    /// Talking to Pipit.
    case on
    /// Switched on in the browser and not talking, because the browser is
    /// closed or has no page open yet.
    case installed
    /// Not talking to Pipit, and this build can set it up.
    case off
    /// This build carries no add-on for the browser.
    case unavailable

    /// - Parameters:
    ///   - isEnabled: What the browser says about the add-on being switched
    ///     on, when it can say. It outranks `hasConnectedBefore`.
    ///   - hasConnectedBefore: The add-on has reported on this machine
    ///     before, which stands for it being there when the browser gives no
    ///     answer.
    public init(
        connection: BrowserSensorTracker.Connection, isBundled: Bool, isEnabled: Bool? = nil,
        hasConnectedBefore: Bool = false
    ) {
        if connection.isLoaded {
            self = .on
        } else if isBundled, isEnabled ?? hasConnectedBefore {
            self = .installed
        } else {
            self = isBundled ? .off : .unavailable
        }
    }

    /// Whether the set-up button is worth showing.
    public var offersSetUp: Bool { self == .off }

    var title: String {
        switch self {
        case .on, .installed: "Add-on installed"
        case .off: "Add-on not connected"
        case .unavailable: "Add-on not installed"
        }
    }

    var symbol: String? {
        switch self {
        case .on, .installed: "checkmark.circle.fill"
        case .off: "questionmark.circle"
        case .unavailable: "circle.slash"
        }
    }

    var color: Color {
        self == .on || self == .installed ? .green : .secondary
    }

    /// The line under the title, naming the browsers the card covers.
    func detail(browsers: String) -> String {
        switch self {
        case .on, .installed: "Meeting detection in \(browsers) is on"
        case .off: "Improves meeting detection in \(browsers)"
        case .unavailable: "No add-on in this build"
        }
    }
}
