import PipitServices
import SwiftUI

struct GeneralSettingsPane: View {
    let model: SettingsModel
    private var runtime: PipitRuntime { model.runtime }

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: model.binding(\.launchAtLogin))
                Toggle("Show notifications", isOn: model.binding(\.showNotifications))
                Toggle("Show in Dock", isOn: model.binding(\.showsDockIcon))
                Toggle(
                    "Pause automatic detection",
                    isOn: Binding(
                        get: { runtime.settings.providers.detectionPaused },
                        set: { runtime.setDetectionPaused($0) }
                    )
                )
            }
            // The button on the right of the row it belongs to, the way System
            // Settings lays out an action beside what it acts on.
            Section("Updates") {
                LabeledContent(AboutInfo.current.versionLine ?? "Pipit") {
                    Button("Check for Updates…") { model.checkForUpdates() }
                        .disabled(!model.canCheckForUpdates)
                }
                Toggle("Beta updates", isOn: model.binding(\.receivesBetaUpdates))
            }
            // Nothing here says who you are. Naming yourself is a rename and
            // saying an existing row is you is a merge, and People owns both.
            // A second door onto them here renamed the person just picked to
            // the name left in the field. The microphone track never needed
            // the answer. It is labelled deterministically whatever the row
            // ends up called.
            Section("People") {
                LabeledContent("Names and voices") {
                    Button("Manage People…") { model.openPeople() }
                }
            }
        }
        .formStyle(.grouped)
    }
}
