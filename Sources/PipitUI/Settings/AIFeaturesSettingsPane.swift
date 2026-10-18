import PipitCore
import PipitServices
import SwiftUI

/// Which model writes titles, summaries and notes, and what it writes.
struct AIFeaturesSettingsPane: View {
    let model: SettingsModel
    private var runtime: PipitRuntime { model.runtime }

    var body: some View {
        Form {
            Section("Provider") { ProviderChoice(model: model) }
            Section(model.provider.displayName) { ProviderSettingsRows(model: model) }
            Section("Features") {
                EnrichmentToggles(runtime: runtime)
            }
        }
        .formStyle(.grouped)
        // Reads the keychain, which can block on an authorisation prompt.
        .task { await model.refresh() }
        // Ollama is looked for whichever provider is chosen, so the list can
        // say it is there.
        .task { await model.probeOllama() }
        .task(id: model.provider) { await model.refreshProvider() }
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

/// The five switches for what the model writes. Shared by Settings and the setup
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
