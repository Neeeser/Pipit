import PipitCore
import PipitServices
import SwiftUI

/// The OpenAI key and what it is used for.
struct AIFeaturesSettingsPane: View {
    let model: SettingsModel
    private var runtime: PipitRuntime { model.runtime }

    var body: some View {
        Form {
            Section("API key") {
                SecureField("sk-…", text: model.text(\.apiKey))
                HStack {
                    Button("Save") { model.saveKey() }.disabled(model.apiKey.isEmpty)
                    Button("Test Connection") { Task { await model.testConnection() } }
                        .disabled(!model.hasStoredKey && model.apiKey.isEmpty)
                    Button("Remove") { model.removeKey() }.disabled(!model.hasStoredKey)
                    switch model.testState {
                    case .idle: EmptyView()
                    case .testing: ProgressView().controlSize(.small)
                    case .success:
                        Label("The key works", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.caption)
                    case .failure(let message):
                        Label(message, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red).font(.caption)
                    }
                }
                Text("Stored in the macOS keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Model") {
                LabeledContent("Model") { MetadataModelPicker(runtime: runtime) }
            }
            Section("Features") {
                EnrichmentToggles(runtime: runtime)
            }
        }
        .formStyle(.grouped)
        // Reads the keychain, which can block on an authorisation prompt.
        .task { await model.refresh() }
    }
}

/// A dropdown of known metadata models, with a text field for any other
/// identifier. Whether the field shows is derived from the stored value, so
/// no view-local state is needed. Shared by Settings and the setup wizard.
struct MetadataModelPicker: View {
    let runtime: PipitRuntime

    /// The sentinel the picker uses for a model identifier typed by hand.
    private static let customModelTag = "custom"

    var body: some View {
        let current = runtime.settings.models.metadata
        let isPreset = AIModelSettings.metadataChoices.contains(current)
        VStack(alignment: .leading, spacing: 2) {
            Picker(
                "",
                selection: Binding(
                    get: { isPreset ? current : Self.customModelTag },
                    set: { newValue in
                        var settings = runtime.settings
                        settings.models.metadata = newValue == Self.customModelTag ? "" : newValue
                        runtime.update(settings: settings)
                    }
                )
            ) {
                ForEach(AIModelSettings.metadataChoices, id: \.self) { choice in
                    Text(choice).tag(choice)
                }
                Text("Other…").tag(Self.customModelTag)
            }
            .labelsHidden()
            .frame(width: 240)
            if !isPreset {
                TextField(
                    "model identifier",
                    text: Binding(
                        get: { runtime.settings.models.metadata },
                        set: { newValue in
                            var settings = runtime.settings
                            settings.models.metadata = newValue
                            runtime.update(settings: settings)
                        }
                    )
                )
                .frame(width: 240)
            }
        }
    }
}

/// The five switches for what OpenAI writes. Shared by Settings and the setup
/// wizard so both offer the same list.
struct EnrichmentToggles: View {
    let runtime: PipitRuntime

    var body: some View {
        toggle("Generate a title", keyPath: \.generateTitle)
        toggle("Generate a description", keyPath: \.generateDescription)
        toggle("Generate notes", keyPath: \.generateNotes)
        toggle("Generate a summary", keyPath: \.generateSummary)
        toggle("Suggest speaker names", keyPath: \.suggestSpeakers)
    }

    private func toggle(
        _ title: String, keyPath: WritableKeyPath<EnrichmentSettings, Bool>
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { runtime.settings.enrichment[keyPath: keyPath] },
                set: { newValue in
                    var settings = runtime.settings
                    settings.enrichment[keyPath: keyPath] = newValue
                    runtime.update(settings: settings)
                }
            ))
    }
}
