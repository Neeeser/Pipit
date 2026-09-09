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
    /// Not connected, and Firefox's add-on list has not been read, so whether
    /// it is installed is not known. Reading it raises a macOS prompt, which
    /// the person triggers from the check button rather than Pipit on its own.
    case unknown
    /// Not connected, read as absent from every profile, and this build has
    /// one to install.
    case missing
    /// Not connected or in a profile, and this build carries no signed add-on
    /// to offer.
    case unavailable
    /// Installed, and older than this build needs. The one state that asks
    /// for something: the add-on has to be updated in Firefox.
    case outdated
    /// Installed, and newer than this build. Nothing is lost, and an app
    /// update is what would use what it added.
    case newer

    public init(
        connection: BrowserSensorTracker.Connection,
        isInProfile: Bool,
        profileRead: Bool,
        hasBundledAddOn: Bool,
        compatibility: SensorProtocol.Compatibility? = nil
    ) {
        // The number the add-on last reported outranks the connection: it is
        // known before the add-on calls back after a restart, and an add-on
        // that is there and behind needs updating whether it is talking or not.
        switch (compatibility, connection.isLoaded || isInProfile) {
        case (.behind, true):
            self = .outdated
            return
        case (.ahead, true) where connection.isLoaded:
            self = .newer
            return
        default: break
        }
        switch (connection, isInProfile, profileRead, hasBundledAddOn) {
        case (.fresh, _, _, _): self = .reporting
        case (.stale, _, _, _): self = .installed
        case (_, true, _, _): self = .connecting
        case (_, false, _, false): self = .unavailable
        case (_, false, false, true): self = .unknown
        case (_, false, true, true): self = .missing
        }
    }

    public var isInstalled: Bool {
        self == .installed || self == .reporting || self == .connecting || self == .outdated
            || self == .newer
    }

    var title: String {
        switch self {
        case .installed, .reporting, .connecting, .newer: "Add-on installed"
        case .outdated: "Add-on needs updating"
        case .unknown: "Add-on not connected"
        case .missing, .unavailable: "Add-on not installed"
        }
    }

    var symbol: String {
        switch self {
        case .installed, .reporting, .newer: "checkmark.circle.fill"
        case .connecting: "clock.fill"
        case .unknown: "questionmark.circle"
        case .missing, .outdated: "exclamationmark.circle.fill"
        case .unavailable: "circle.slash"
        }
    }

    var color: Color {
        switch self {
        case .installed, .reporting, .newer: .green
        case .connecting, .unknown, .unavailable: .secondary
        case .missing, .outdated: .orange
        }
    }

    /// The line under the title. What the person gets from the state, not
    /// what the transport is doing.
    var detail: String {
        switch self {
        case .reporting, .installed: "Meeting detection in Firefox is on."
        case .newer: "Meeting detection in Firefox is on. The add-on is newer than this Pipit."
        case .outdated: "This version of Pipit needs a newer add-on."
        case .connecting: "Waiting for Firefox to connect."
        case .unknown, .missing: "Improves meeting detection in Firefox."
        case .unavailable: "This build has no add-on to install."
        }
    }

    /// Whether the install button is worth showing.
    public var offersInstall: Bool { self == .unknown || self == .missing }

    /// Whether the update button is worth showing. The same file goes to
    /// Firefox as on first install; only the label changes.
    public var offersUpdate: Bool { self == .outdated }

    /// Whether an app update is the thing to offer.
    public var suggestsAppUpdate: Bool { self == .newer }
}

/// The button that reads Firefox's add-on list, and what macOS said last time.
///
/// Shown by setup and by the Browsers page. The read raises the macOS
/// "access data from other apps" prompt once, and a refusal has no switch in
/// System Settings, so the read runs only from here until it has been allowed.
struct FirefoxAddOnCheck: View {
    let access: FirefoxProfileAccess
    let state: FirefoxAddOnState
    let check: () -> Void

    var body: some View {
        // Nothing to ask while the add-on is talking, once the read is allowed
        // and runs on its own, or on a Mac with no Firefox to read.
        if state == .unknown, FirefoxAddOn.isFirefoxInstalled {
            VStack(alignment: .leading, spacing: 6) {
                switch access {
                case .notAsked, .allowed:
                    Button("Check Firefox for the add-on") { check() }
                    Text("macOS asks once to let Pipit read Firefox's add-on list.")
                        .font(.caption).foregroundStyle(.secondary)
                case .blocked:
                    Label("macOS blocked the check.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Try again") { check() }
                        .buttonStyle(.link)
                }
            }
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
    enum Role {
        case install
        /// A second install over one already there, which needs no urgency.
        case reinstall
        /// The add-on is behind this build. Same file, same Firefox prompt.
        case update
    }
    var role: Role = .install
    @State private var launchFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                switch role {
                case .reinstall:
                    Button("Reinstall add-on") { install() }
                        .disabled(!FirefoxAddOn.isFirefoxInstalled)
                case .install, .update:
                    Button(role == .update ? "Update the Firefox add-on" : "Install the Firefox add-on") {
                        install()
                    }
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
