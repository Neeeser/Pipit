import PipitCore
import PipitIntegrations
import PipitServices
import SwiftUI

/// The providers, one choice. Ollama says when it is running, so a person who
/// has it finds that out without opening it.
struct ProviderChoice: View {
    let model: SettingsModel

    var body: some View {
        Picker(
            "Provider",
            selection: Binding(get: { model.provider }, set: { newValue in model.selectProvider(newValue) })
        ) {
            ForEach(LanguageModelProvider.allCases) { provider in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(provider.displayName)
                        Text(provider.blurb).font(.caption).foregroundStyle(.secondary)
                    }
                    if provider == .ollama, model.ollamaIsRunning {
                        Text("Found").font(.caption).foregroundStyle(.green)
                    }
                }
                .tag(provider)
            }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
    }
}

/// What the chosen provider needs: a key, an address, a model.
struct ProviderSettingsRows: View {
    let model: SettingsModel

    var body: some View {
        switch model.provider {
        case .openAI:
            ProviderKeyRows(model: model)
            LabeledContent("Model") { MetadataModelPicker(runtime: model.runtime) }
        case .openRouter:
            ProviderKeyRows(model: model)
            LabeledContent("Model") { ModelListPicker(model: model) }
        case .ollama:
            OllamaRows(model: model)
        case .custom:
            CustomEndpointRows(model: model)
        }
    }
}

/// The key field and the buttons that go with it, for any provider that takes
/// one.
struct ProviderKeyRows: View {
    let model: SettingsModel

    private var needsKey: Bool { model.provider.keyRequirement == .required }

    var body: some View {
        SecureField("API key", text: model.text(\.apiKey), prompt: Text(model.provider.keyPlaceholder))
        HStack {
            Button("Save") { model.saveKey() }.disabled(model.apiKey.isEmpty)
            Button("Test Connection") { Task { await model.testConnection() } }
                .disabled(needsKey && !model.hasStoredKey && model.apiKey.isEmpty)
            Button("Remove") { model.removeKey() }.disabled(!model.hasStoredKey)
            testStatus
        }
        if needsKey {
            Text("Stored in the macOS keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var testStatus: some View {
        switch model.testState {
        case .idle: EmptyView()
        case .testing: ProgressView().controlSize(.small)
        case .success:
            Label(
                model.provider == .openAI ? "The key works" : "Connected",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green).font(.caption)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red).font(.caption)
        }
    }
}

/// A model chosen from what the server lists, with a search box for the
/// lists that run to hundreds. Falls back to a field to type into when the
/// server lists nothing.
struct ModelListPicker: View {
    let model: SettingsModel

    private var current: String { model.runtime.settings.models.metadata }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if model.typesModelName || model.modelListState == .failed {
                TextField("Model", text: model.binding(\.models.metadata), prompt: Text("model identifier"))
                    .labelsHidden()
                    .frame(width: 280)
            } else if model.modelListState == .loading {
                ProgressView().controlSize(.small)
            } else {
                chooser
            }
            if model.modelListState == .loaded {
                Button(model.typesModelName ? "Choose from the list" : "Type a model name") {
                    model.typesModelName.toggle()
                }
                .buttonStyle(.link).font(.caption)
            }
            if let detail = Self.detail(of: current, in: model.modelList) {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var chooser: some View {
        Button {
            model.isChoosingModel = true
        } label: {
            HStack {
                Text(current.isEmpty ? "Choose a model" : current)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }
            .frame(width: 280)
        }
        .popover(
            isPresented: Binding(get: { model.isChoosingModel }, set: { newValue in model.isChoosingModel = newValue }),
            arrowEdge: .bottom
        ) {
            ModelSearchList(model: model)
        }
    }

    /// What the server says about the chosen model: its window and its price.
    static func detail(of id: String, in options: [LanguageModelOption]) -> String? {
        guard let option = options.first(where: { $0.id == id }) else { return nil }
        var parts: [String] = []
        if let tokens = option.contextTokens {
            parts.append("\(ContextWindow.publishedLabel(tokens)) context")
        }
        if let price = ModelSearchList.price(of: option) { parts.append(price) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The popover behind `ModelListPicker`.
struct ModelSearchList: View {
    let model: SettingsModel

    var body: some View {
        let options = model.visibleModels
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                TextField("Search", text: model.text(\.modelSearch))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("\(options.count) of \(model.modelList.count) models")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.modelList.contains(where: { $0.isFree }) {
                        Toggle(
                            "Free only",
                            isOn: Binding(
                                get: { model.showsFreeModelsOnly },
                                set: { newValue in model.showsFreeModelsOnly = newValue }
                            )
                        )
                        .toggleStyle(.switch).controlSize(.small)
                    }
                }
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(options) { option in row(option) }
                }
            }
        }
        .frame(width: 460, height: 380)
    }

    private func row(_ option: LanguageModelOption) -> some View {
        let chosen = option.id == model.runtime.settings.models.metadata
        return Button {
            model.chooseOption(option)
            model.isChoosingModel = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark").opacity(chosen ? 1 : 0).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.name).lineLimit(1)
                    Text(option.id)
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    if let tokens = option.contextTokens {
                        Text(ContextWindow.publishedLabel(tokens)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let price = Self.price(of: option) {
                        Text(price).font(.caption).foregroundStyle(option.isFree ? Color.green : Color.secondary)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(chosen ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    /// "Free", or the price in and out per million tokens.
    static func price(of option: LanguageModelOption) -> String? {
        if option.isFree { return "Free" }
        guard let prompt = option.promptPrice, let completion = option.completionPrice else { return nil }
        return "\(dollars(prompt)) in, \(dollars(completion)) out per million tokens"
    }

    private static func dollars(_ amount: Double) -> String {
        var text = String(format: "%.3f", amount)
        // Cents, unless the price needs the third digit.
        if text.hasSuffix("0") { text.removeLast() }
        return "$\(text)"
    }
}

/// Ollama on this Mac: whether it is there, and which of its models to use.
struct OllamaRows: View {
    let model: SettingsModel

    private static let downloadURL = URL(string: "https://ollama.com/download")

    var body: some View {
        if let status = model.ollamaStatus {
            switch status {
            case .notInstalled:
                statusRow("Ollama isn't installed on this Mac", color: .secondary) {
                    if let url = Self.downloadURL { Link("Get Ollama", destination: url) }
                    checkAgain
                }
            case .installedNotRunning:
                statusRow("Ollama isn't running", color: .orange) {
                    if model.canOpenOllama { Button("Open Ollama") { model.openOllama() } }
                    checkAgain
                }
            case .running(let models):
                statusRow("Ollama is running", color: .green) { checkAgain }
                modelChoice(models)
                ContextWindowRow(model: model)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for Ollama…")
            }
        }
    }

    private var checkAgain: some View {
        Button("Check Again") { Task { await model.probeOllama() } }
    }

    private func statusRow<Actions: View>(
        _ title: String, color: Color, @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
            Spacer()
            actions()
        }
    }

    @ViewBuilder
    private func modelChoice(_ models: [OllamaModel]) -> some View {
        if models.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No models installed").fontWeight(.medium)
                Text("Run this in Terminal, then check again:")
                    .font(.caption).foregroundStyle(.secondary)
                Text("ollama pull llama3.1:8b")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        } else {
            Picker(
                "Model",
                selection: Binding(
                    get: { model.runtime.settings.models.metadata },
                    set: { newValue in model.chooseModel(newValue) }
                )
            ) {
                ForEach(models) { installed in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(installed.name)
                        Text(Self.detail(of: installed)).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(installed.name)
                }
            }
            .pickerStyle(.radioGroup)
            Text("Install more with `ollama pull <name>`")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private static func detail(of installed: OllamaModel) -> String {
        let parts: [String?] = [
            installed.parameterSize.map { "\($0) parameters" },
            installed.quantization,
            installed.sizeBytes > 0
                ? ByteCountFormatter.string(fromByteCount: installed.sizeBytes, countStyle: .file) : nil,
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

/// An address the person typed, for a server this app has no preset for.
struct CustomEndpointRows: View {
    let model: SettingsModel

    var body: some View {
        TextField(
            "Server address", text: model.binding(\.models.customEndpoint),
            prompt: Text("http://localhost:1234/v1")
        )
        .onSubmit { Task { await model.loadModelList() } }
        ProviderKeyRows(model: model)
        modelRows
        ContextWindowRow(model: model)
    }

    @ViewBuilder
    private var modelRows: some View {
        if model.modelListState == .loaded, !model.typesModelName, model.modelList.count <= 6 {
            Picker(
                "Model",
                selection: Binding(
                    get: { model.runtime.settings.models.metadata },
                    set: { newValue in model.chooseModel(newValue) }
                )
            ) {
                ForEach(model.modelList) { option in
                    Text(option.id).font(.system(.body, design: .monospaced)).tag(option.id)
                }
            }
            .pickerStyle(.radioGroup)
            Button("Type a model name instead") { model.typesModelName = true }
                .buttonStyle(.link).font(.caption)
        } else {
            LabeledContent("Model") { ModelListPicker(model: model) }
        }
    }
}

/// How much of a transcript one request can carry, and so how long a meeting
/// is read in one piece. Longer ones are read in parts.
struct ContextWindowRow: View {
    let model: SettingsModel

    var body: some View {
        let sizes = model.contextSizes
        let current = ContextWindow.nearest(model.contextTokens, in: sizes)
        let index = sizes.firstIndex(of: current) ?? 0
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Context window")
                Spacer()
                Text("\(ContextWindow.label(current)) tokens").fontWeight(.semibold)
            }
            Slider(
                value: Binding(
                    get: { Double(index) },
                    set: { newValue in
                        let chosen = min(max(Int(newValue.rounded()), 0), sizes.count - 1)
                        model.setContext(sizes[chosen])
                    }
                ),
                in: 0...Double(max(sizes.count - 1, 1)),
                step: 1
            ) {
                EmptyView()
            } minimumValueLabel: {
                Text(ContextWindow.label(sizes.first ?? current)).font(.caption)
            } maximumValueLabel: {
                Text(ContextWindow.label(sizes.last ?? current)).font(.caption)
            }
            .disabled(sizes.count < 2)
            Text(
                "Fits \(ContextWindow.fitDescription(context: current)) of meeting. "
                    + "Longer meetings are processed in parts."
            )
            .font(.caption).foregroundStyle(.secondary)
            Text(model.provider == .custom ? "Match what the server is set to." : "A larger window uses more memory.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
