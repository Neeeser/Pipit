import AppKit
import PipitCore
import PipitDetection
import PipitServices
import SwiftUI

/// Whether each browser can tell Pipit what it sees of a call.
///
/// One card per browser, leading with the add-on rather than with the plumbing
/// underneath it: a person reads this page to find out whether the add-on is in
/// their browser, and the host and its manifest only matter when it is not
/// working. Those live in the details below, closed.
struct BrowsersSettingsPane: View {
    let model: SettingsModel
    private var runtime: PipitRuntime { model.runtime }

    private var safariState: BrowserAddOnState {
        BrowserAddOnState(
            connection: runtime.status.browserSensors[.safari] ?? .absent,
            isBundled: SafariAddOn.isBundled
        )
    }

    private var chromeState: BrowserAddOnState {
        BrowserAddOnState(
            connection: runtime.status.browserSensors[.chrome] ?? .absent,
            isBundled: NativeMessagingInstaller.bundledChromeAddOnURL() != nil
        )
    }

    private var addOnState: FirefoxAddOnState {
        FirefoxAddOnState(
            connection: runtime.status.sensorConnection,
            isInProfile: runtime.status.firefoxAddOnInProfile,
            profileRead: runtime.settings.firefoxProfileAccess == .allowed,
            hasBundledAddOn: FirefoxAddOn.bundledAddOn != nil,
            compatibility: runtime.status.firefoxAddOnCompatibility
        )
    }

    var body: some View {
        Form {
            Section("Safari") {
                BrowserAddOnRow(
                    symbol: "safari",
                    title: safariState.title,
                    detail: safariState.detail(browsers: "Safari"),
                    statusSymbol: safariState.symbol,
                    statusColor: safariState.color
                )
                if safariState.offersSetUp {
                    HStack(spacing: 10) {
                        Button("Turn on in Safari") { SafariAddOn.openSettings() }
                            .buttonStyle(.borderedProminent)
                        Text("Then allow it on your meeting sites")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }

            Section("Firefox") {
                BrowserAddOnRow(
                    symbol: "globe",
                    title: addOnState.title,
                    detail: addOnState.detail,
                    statusSymbol: addOnState.symbol,
                    statusColor: addOnState.color
                )
                if addOnState.offersInstall {
                    FirefoxAddOnInstallButton(prepareRelay: { model.installHost() })
                }
                if addOnState.offersUpdate {
                    if let version = runtime.status.firefoxAddOnVersion {
                        Text("Firefox has add-on \(version).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    FirefoxAddOnInstallButton(prepareRelay: { model.installHost() }, role: .update)
                }
                if addOnState.suggestsAppUpdate, model.canCheckForUpdates {
                    Button("Check for Updates…") { model.checkForUpdates() }
                }
                FirefoxAddOnCheck(
                    access: runtime.settings.firefoxProfileAccess,
                    state: addOnState,
                    check: { model.checkFirefox() }
                )
            }

            Section("Chrome, Brave, Edge and Arc") {
                BrowserAddOnRow(
                    symbol: "globe",
                    title: chromeState.title,
                    detail: chromeState.detail(browsers: "Chrome, Brave, Edge and Arc"),
                    statusSymbol: chromeState.symbol,
                    statusColor: chromeState.color
                )
                if chromeState.offersSetUp {
                    Button("Set up the add-on") { model.setUpChromeAddOn() }
                        .buttonStyle(.borderedProminent)
                    Text(
                        "Open the browser's Extensions page, turn on Developer mode, "
                            + "choose Load unpacked, and pick the folder Pipit shows."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                DisclosureGroup("Connection details") {
                    connectionDetails
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await model.refresh()
            await model.pollSensor()
        }
    }

    @ViewBuilder
    private var connectionDetails: some View {
        if let version = model.sensorStatus?.lastHello?.extensionVersion {
            LabeledContent("Add-on version") { Text(version) }
        }
        if let lastMessage = model.sensorStatus?.lastMessageAt {
            LabeledContent("Last reported") {
                Text(lastMessage, style: .relative) + Text(" ago")
            }
        }
        HStack {
            Button("Repair connection") { model.installHost() }
            if addOnState.isInstalled, FirefoxAddOn.bundledAddOn != nil {
                FirefoxAddOnInstallButton(
                    prepareRelay: { model.installHost() }, role: .reinstall
                )
            }
        }
        if let rejected = model.sensorStatus?.rejectedConnections, rejected > 0 {
            Label(
                "\(rejected) connection\(rejected == 1 ? "" : "s") refused.",
                systemImage: "shield.lefthalf.filled"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }
}

/// One browser's headline: what its add-on is doing, and what follows from it.
private struct BrowserAddOnRow: View {
    let symbol: String
    let title: String
    let detail: String
    let statusSymbol: String?
    let statusColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let statusSymbol {
                        Image(systemName: statusSymbol).foregroundStyle(statusColor)
                    }
                    Text(title).fontWeight(.medium)
                        .foregroundStyle(statusSymbol == nil ? .secondary : .primary)
                }
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}
