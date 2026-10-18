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
enum SafariAddOn {
    /// Whether this build carries the extension. Only the bundle
    /// scripts/bundle-app.sh assembles does.
    static var isBundled: Bool { SensorPeerVerifier.safariExtension() != nil }

    /// Opens Safari's Extensions settings with Pipit's extension selected.
    static func openSettings() {
        SFSafariApplication.showPreferencesForExtension(
            withIdentifier: SensorTransport.safariExtensionBundleIdentifier
        ) { _ in }
    }
}

/// What the Safari and Chrome cards report.
///
/// Simpler than Firefox's: neither browser keeps an add-on list Pipit could
/// read, so the add-on talking to Pipit is the whole answer.
public enum BrowserAddOnState: Equatable {
    /// Talking to Pipit.
    case on
    /// Not talking to Pipit, and this build can set it up.
    case off
    /// This build carries no add-on for the browser.
    case unavailable

    public init(connection: BrowserSensorTracker.Connection, isBundled: Bool) {
        if connection.isLoaded {
            self = .on
        } else {
            self = isBundled ? .off : .unavailable
        }
    }

    /// Whether the set-up button is worth showing.
    public var offersSetUp: Bool { self == .off }

    var title: String {
        switch self {
        case .on: "Add-on installed"
        case .off: "Add-on not connected"
        case .unavailable: "Add-on not installed"
        }
    }

    var symbol: String? {
        switch self {
        case .on: "checkmark.circle.fill"
        case .off: "questionmark.circle"
        case .unavailable: "circle.slash"
        }
    }

    var color: Color {
        self == .on ? .green : .secondary
    }

    /// The line under the title, naming the browsers the card covers.
    func detail(browsers: String) -> String {
        switch self {
        case .on: "Meeting detection in \(browsers) is on."
        case .off: "Improves meeting detection in \(browsers)."
        case .unavailable: "This build has no add-on to install."
        }
    }
}
