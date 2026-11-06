import PipitCore
import PipitServices
import SwiftUI

/// What starts a recording and how the audio is captured.
///
/// Providers and audio were two pages. Audio held two settings and three
/// read-only readouts, and once the readouts went there was not a page left.
struct RecordingSettingsPane: View {
    let model: SettingsModel
    private var runtime: PipitRuntime { model.runtime }

    var body: some View {
        Form {
            Section("Record automatically") {
                providerRow("Slack Huddles", keyPath: \.slack)
                providerRow("Google Meet", keyPath: \.googleMeet)
                providerRow("Zoom", keyPath: \.zoom)
                providerRow("FaceTime", keyPath: \.faceTime)
                providerRow("Other calls", keyPath: \.unknownCalls)
            }
            Section("Live transcript") {
                Toggle("Transcribe during meetings", isOn: liveBinding(\.isEnabled))
                if LiveTranscriptSettings.engines.count > 1 {
                    Picker("Engine", selection: liveBinding(\.engine)) {
                        ForEach(LiveTranscriptSettings.engines, id: \.self) { engine in
                            Text(LocalModelChoicePicker.title(engine)).tag(engine)
                        }
                    }
                    .disabled(!runtime.settings.live.isEnabled)
                }
                Toggle("Open live window when recording starts", isOn: liveBinding(\.opensWithRecording))
                    .disabled(!runtime.settings.live.isEnabled)
                Toggle("Hide live window when sharing screen", isOn: liveBinding(\.hiddenFromScreenSharing))
            }
            Section("Ending a meeting") {
                waitRow(
                    "Pause after the call ends",
                    choices: Self.endGraceChoices,
                    keyPath: \.meetingEndGraceSeconds
                )
                waitRow(
                    "Wait for rejoin before saving",
                    choices: Self.reconnectWindowChoices,
                    keyPath: \.meetingReconnectWindowSeconds
                )
            }
            Section("Applications") {
                appList(
                    title: "Always record",
                    identifiers: runtime.settings.alwaysRecordApplications,
                    remove: { identifier in
                        var settings = runtime.settings
                        settings.alwaysRecordApplications.removeAll { $0 == identifier }
                        runtime.update(settings: settings)
                    }
                )
                appList(
                    title: "Never record",
                    identifiers: runtime.settings.neverRecordApplications,
                    remove: { identifier in
                        var settings = runtime.settings
                        settings.neverRecordApplications.removeAll { $0 == identifier }
                        runtime.update(settings: settings)
                    }
                )
            }
        }
        .formStyle(.grouped)
    }

    private func liveBinding<Value>(_ keyPath: WritableKeyPath<LiveTranscriptSettings, Value>) -> Binding<Value> {
        Binding(
            get: { runtime.settings.live[keyPath: keyPath] },
            set: { value in
                var settings = runtime.settings
                settings.live[keyPath: keyPath] = value
                runtime.update(settings: settings)
            }
        )
    }

    /// Fixed steps rather than a free field, so the range the session
    /// controller enforces is also the range the user can reach.
    private static let endGraceChoices: [Double] = [2, 4, 6, 10, 20]
    private static let reconnectWindowChoices: [Double] = [10, 30, 60, 90, 180]

    private func waitRow(
        _ title: String, choices: [Double], keyPath: WritableKeyPath<AppSettings, Double>
    ) -> some View {
        LabeledContent(title) {
            Picker(
                "",
                selection: Binding(
                    get: {
                        let stored = runtime.settings[keyPath: keyPath]
                        // A value from a hand-edited file has no row of its own. The
                        // nearest choice is what the picker shows, and choosing
                        // anything writes a value from the list.
                        return choices.min { abs($0 - stored) < abs($1 - stored) } ?? stored
                    },
                    set: { newValue in
                        var settings = runtime.settings
                        settings[keyPath: keyPath] = newValue
                        runtime.update(settings: settings)
                    }
                )
            ) {
                ForEach(choices, id: \.self) { seconds in
                    Text("\(Int(seconds)) seconds").tag(seconds)
                }
            }
            .labelsHidden()
            .frame(width: 160)
        }
    }

    private func providerRow(
        _ title: String, keyPath: WritableKeyPath<ProviderPolicies, ProviderPolicy>
    ) -> some View {
        LabeledContent(title) {
            Picker(
                "",
                selection: Binding(
                    get: { runtime.settings.providers[keyPath: keyPath].autoStart },
                    set: { newValue in
                        var settings = runtime.settings
                        settings.providers[keyPath: keyPath].autoStart = newValue
                        runtime.update(settings: settings)
                    }
                )
            ) {
                Text("Always record").tag(ProviderPolicy.AutoStart.always)
                Text("Ask").tag(ProviderPolicy.AutoStart.ask)
                Text("Never").tag(ProviderPolicy.AutoStart.never)
            }
            .labelsHidden()
            .frame(width: 160)
        }
    }

    @ViewBuilder
    private func appList(
        title: String, identifiers: [String], remove: @escaping (String) -> Void
    ) -> some View {
        if identifiers.isEmpty {
            LabeledContent(title) { Text("None").foregroundStyle(.secondary) }
        } else {
            ForEach(identifiers, id: \.self) { identifier in
                LabeledContent(title) {
                    HStack {
                        Text(identifier).font(.caption)
                        Button("Remove") { remove(identifier) }.buttonStyle(.link)
                    }
                }
            }
        }
    }
}
