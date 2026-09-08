import AppKit
import PipitCore
import PipitDetection
import SwiftUI

/// Getting the sensor add-on into Firefox, and saying whether it is there.
///
/// A release build carries an add-on signed by Mozilla, which Firefox installs
/// permanently from the file. A local build carries none: release Firefox
/// refuses an unsigned add-on, so there is nothing to offer and the page says
/// so. Loading one temporarily from `about:debugging` is how the extension is
/// developed, and it lives in the docs rather than in the app.
///
/// The file goes to Firefox's executable as an argument. A running Firefox
/// forwards the argument to itself and the launched process exits.
enum FirefoxAddOn {
    /// The first installed Firefox build, release before developer builds.
    static func installedApplication() -> URL? {
        BrowserKind.firefox.bundleIdentifiers.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
    }

    static var isFirefoxInstalled: Bool { installedApplication() != nil }

    /// The signed add-on this build ships, if it ships one.
    static var bundledAddOn: URL? { NativeMessagingInstaller.bundledFirefoxAddOnURL() }

    /// Hands the signed add-on to Firefox, which raises its own install prompt.
    @discardableResult
    static func install() -> Bool {
        guard
            let addOn = bundledAddOn,
            let application = installedApplication(),
            let executable = Bundle(url: application)?.executableURL
        else { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = [addOn.path]
        do {
            try process.run()
        } catch {
            return false
        }
        return true
    }
}

/// What the Firefox card reports, from the facts that decide it.
public enum FirefoxAddOnState: Equatable {
    /// Installed and holding a connection, with no meeting on screen.
    case installed
    /// Installed and reporting a meeting right now.
    case reporting
    /// In a Firefox profile, but not talking to Pipit yet. Restarting Pipit
    /// drops the connection, and the add-on waits out a backoff before calling
    /// in again, so this is an ordinary state rather than a fault.
    case connecting
    /// Not connected, not in a profile, and this build has one to install.
    case missing
    /// The same, except this build carries no signed add-on to offer.
    case unavailable

    public init(
        connection: BrowserSensorTracker.Connection,
        isInProfile: Bool,
        hasBundledAddOn: Bool
    ) {
        switch (connection, isInProfile, hasBundledAddOn) {
        case (.fresh, _, _): self = .reporting
        case (.stale, _, _): self = .installed
        case (_, true, _): self = .connecting
        case (_, false, true): self = .missing
        case (_, false, false): self = .unavailable
        }
    }

    public var isInstalled: Bool {
        self == .installed || self == .reporting || self == .connecting
    }

    var title: String {
        isInstalled ? "Add-on installed" : "Add-on not installed"
    }

    var symbol: String {
        switch self {
        case .installed, .reporting: "checkmark.circle.fill"
        case .connecting: "clock.fill"
        case .missing: "exclamationmark.circle.fill"
        case .unavailable: "circle.slash"
        }
    }

    var color: Color {
        switch self {
        case .installed, .reporting: .green
        case .connecting, .unavailable: .secondary
        case .missing: .orange
        }
    }

    /// The line under the title. What the person gets from the state, not
    /// what the transport is doing.
    var detail: String {
        switch self {
        case .reporting, .installed: "Meeting detection in Firefox is on."
        case .connecting: "Waiting for Firefox to connect."
        case .missing: "Improves meeting detection in Firefox."
        case .unavailable: "This build has no add-on to install."
        }
    }
}

/// The install button, and what it says after Firefox has been asked.
///
/// Shown by both the settings page and setup, so one wording covers both.
struct FirefoxAddOnInstallButton: View {
    /// Writes the relay and its manifest first. Firefox needs both to reach
    /// Pipit, and nobody installing an add-on should have to know that, so one
    /// button does both and neither is a step of its own.
    let prepareRelay: () -> Void
    /// A second install over one already there, which needs no urgency.
    var isReinstall = false
    @State private var launchFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if isReinstall {
                    Button("Reinstall add-on") { install() }
                        .disabled(!FirefoxAddOn.isFirefoxInstalled)
                } else {
                    Button("Install the Firefox add-on") { install() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!FirefoxAddOn.isFirefoxInstalled)
                    Text("Firefox asks you to confirm")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            if launchFailed {
                Text("Firefox did not open. Open it and try again.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func install() {
        prepareRelay()
        launchFailed = !FirefoxAddOn.install()
    }
}
