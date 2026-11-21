import PipitCore
import PipitLocalAI
import PipitServices
import SwiftUI

/// Where each stage runs, which model it uses, and what is on disk to run it.
///
/// One page: picking a model that is not installed starts its download here,
/// inline on the row, instead of sending the user to a second page.
struct ProcessingSettingsPane: View {
    let model: SettingsModel
    private var runtime: PipitRuntime { model.runtime }
    /// True from the click on Update until its download ends. Held by the
    /// runtime, so the bar survives switching to another pane and back.
    private var updatingSpeakerSeparation: Bool { runtime.speakerSeparationUpdating }
    private var updateBytes: Int64 { runtime.speakerSeparationUpdateBytes }

    var body: some View {
        Form {
            Section("Transcription") {
                backendPicker(keyPath: \.transcription)
                if runtime.settings.processing.usesLocalTranscription {
                    LocalModelChoicePicker(
                        selected: runtime.settings.processing.localTranscriptionModel,
                        select: { choice in
                            Task { await runtime.chooseLocalTranscriptionModel(choice) }
                        }
                    )
                } else {
                    cloudTranscriptionPicker
                }
            }
            Section("Speaker recognition") {
                speakerToggle("Recognize known voices", keyPath: \.recognizeKnownVoices)
                speakerToggle("Remember unnamed voices", keyPath: \.rememberRecurringVoices)
                speakerToggle("Learn my voice", keyPath: \.learnMyVoice)
                speakerToggle("Learn from corrections", keyPath: \.learnFromCorrections)
            }
            modelsOnDiskSection
        }
        .formStyle(.grouped)
        .task { await runtime.refreshLocalModelState() }
    }

    private func backendPicker(
        keyPath: WritableKeyPath<ProcessingSettings, ProcessingBackendChoice>
    ) -> some View {
        Picker(
            "Runs on",
            selection: Binding(
                get: { runtime.settings.processing[keyPath: keyPath] },
                set: { newValue in
                    var settings = runtime.settings
                    settings.processing[keyPath: keyPath] = newValue
                    runtime.update(settings: settings)
                    Task { await runtime.installLocalModels() }
                }
            )
        ) {
            Text("OpenAI").tag(ProcessingBackendChoice.openAI)
            Text("On this Mac").tag(ProcessingBackendChoice.local)
        }
        .pickerStyle(.radioGroup)
    }

    /// The sentinel the pickers use for a model identifier typed by hand.
    private static let customModelTag = "custom"

    private var cloudTranscriptionPicker: some View {
        let current = runtime.settings.models.transcription
        let isPreset = AIModelSettings.transcriptionChoices.contains(current)
        return VStack(alignment: .leading, spacing: 6) {
            Picker(
                "Model",
                selection: Binding(
                    get: { isPreset ? current : Self.customModelTag },
                    set: { newValue in
                        var settings = runtime.settings
                        settings.models.transcription =
                            newValue == Self.customModelTag ? "" : newValue
                        runtime.update(settings: settings)
                        // gpt-transcribe returns no timings; the aligner that
                        // supplies them is a local download.
                        Task { await runtime.installLocalModels() }
                    }
                )
            ) {
                cloudChoice("gpt-4o-transcribe-diarize", "Includes speakers")
                cloudChoice(
                    "gpt-transcribe",
                    "Takes vocabulary hints. Needs a 600 MB download."
                )
                Text("Custom…").tag(Self.customModelTag)
            }
            .pickerStyle(.radioGroup)
            if !isPreset {
                TextField(
                    "model identifier",
                    text: Binding(
                        get: { runtime.settings.models.transcription },
                        set: { newValue in
                            var settings = runtime.settings
                            settings.models.transcription = newValue
                            runtime.update(settings: settings)
                        }
                    )
                )
                .frame(width: 280)
            }
            if AIModelSettings.transcriptionTiming(for: current) == .text, isPreset {
                TextField(
                    "Vocabulary hints, comma separated",
                    text: Binding(
                        get: { runtime.settings.models.vocabularyHints },
                        set: { newValue in
                            var settings = runtime.settings
                            settings.models.vocabularyHints = newValue
                            runtime.update(settings: settings)
                        }
                    )
                )
            }
        }
    }

    private func cloudChoice(_ id: String, _ blurb: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(id)
            Text(blurb).font(.caption).foregroundStyle(.secondary)
        }
        .tag(id)
    }

    /// Everything installed or needed, with the one control set that changes it.
    private var modelsOnDiskSection: some View {
        Section("Models") {
            ForEach(visibleUnits, id: \.rawValue) { unit in
                if unit == .nemotronDiarizer {
                    speakerSeparationRow
                } else {
                    LabeledContent(Self.unitName(unit)) {
                        HStack(spacing: 8) {
                            Text(unitStatus(unit)).foregroundStyle(.secondary)
                            if installedBytes(unit) != nil {
                                Button("Delete") {
                                    Task { await runtime.removeLocalModel(unit) }
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
            switch runtime.localModelState {
            // The speaker separation update draws its own bar under its row.
            case .downloading(let fraction, let detail, _) where !updatingSpeakerSeparation:
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: fraction)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            case .failed(let message, _):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
                Button("Try Again") { Task { await runtime.installLocalModels() } }
            case .notInstalled:
                if !requiredUnits.isEmpty {
                    Button(downloadLabel) { Task { await runtime.installLocalModels() } }
                }
            case .outdated:
                Label(
                    "Out of date",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.caption).foregroundStyle(.secondary)
                Button("Re-download") { Task { await runtime.reinstallLocalModels() } }
            case .installed, .downloading:
                EmptyView()
            }
            if let path = runtime.models?.locations.root.path {
                Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private var requiredUnits: Set<LocalModelUnit> {
        LocalModelUnit.required(for: runtime.settings)
    }

    /// Required units first, then anything else still on disk. The two speaker
    /// separation units are one row, carried by the Nemotron unit's place in
    /// the list, whenever diarization is local or Nemotron is on disk.
    private var visibleUnits: [LocalModelUnit] {
        let grouped = showsSpeakerSeparationRow
        return LocalModelUnit.allCases.filter { unit in
            if unit == .nemotronDiarizer { return grouped }
            if unit == .diarizer, grouped { return false }
            return requiredUnits.contains(unit) || installedBytes(unit) != nil
        }
    }

    private var showsSpeakerSeparationRow: Bool {
        runtime.settings.processing.usesLocalDiarization || installedBytes(.nemotronDiarizer) != nil
    }

    /// Nemotron 3 Diarization and the speaker models it shares a download
    /// with, as one item with one Update button for whatever is missing.
    private var speakerSeparationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(Self.unitName(.nemotronDiarizer)) {
                HStack(spacing: 8) {
                    Text(speakerSeparationStatus).foregroundStyle(.secondary)
                    if runtime.speakerSeparationUpdateAvailable, !updatingSpeakerSeparation {
                        Button("Update") {
                            Task { await runtime.installSpeakerSeparation() }
                        }
                        .controlSize(.small)
                        .disabled(runtime.localModelState.isBusy)
                    }
                    if runtime.speakerSeparationInstalledBytes != nil, !speakerSeparationInProgress {
                        Button("Delete") {
                            Task { await runtime.removeSpeakerSeparation() }
                        }
                        .controlSize(.small)
                    }
                }
            }
            if speakerSeparationInProgress {
                speakerSeparationProgress
            }
        }
    }

    /// From the click until the model is ready, including the compile that
    /// follows the download, so the row never sits still after Update.
    private var speakerSeparationInProgress: Bool {
        updatingSpeakerSeparation || runtime.preparingSpeakerSeparation
    }

    @ViewBuilder private var speakerSeparationProgress: some View {
        if updatingSpeakerSeparation, case .downloading(let fraction, _, _) = runtime.localModelState {
            ProgressView(value: SpeakerSeparationProgress.downloading(fraction))
            Text(
                "Downloading \(Self.megabytes(Int64(Double(updateBytes) * fraction))) of \(Self.megabytes(updateBytes))"
            )
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        } else if let since = runtime.speakerSeparationPreparingSince {
            TimelineView(.periodic(from: since, by: 1)) { context in
                ProgressView(
                    value: SpeakerSeparationProgress.compiling(elapsed: context.date.timeIntervalSince(since))
                )
            }
            Text("Installing").font(.caption).foregroundStyle(.secondary)
        } else {
            // Clicked, and the download has not reported yet.
            ProgressView(value: 0)
            Text("Downloading").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var speakerSeparationStatus: String {
        if speakerSeparationInProgress {
            return Self.megabytes(
                updatingSpeakerSeparation ? updateBytes : runtime.speakerSeparationInstalledBytes ?? 0)
        }
        if runtime.speakerSeparationUpdateAvailable {
            if runtime.speakerSeparationUpdateFailed { return "Download failed" }
            let missing = runtime.speakerSeparationMissingUnits.reduce(Int64(0)) { $0 + $1.approximateBytes }
            return Self.megabytes(missing)
        }
        return Self.megabytes(runtime.speakerSeparationInstalledBytes ?? 0)
    }

    private func installedBytes(_ unit: LocalModelUnit) -> Int64? {
        runtime.localModelState.present.bytes(for: unit)
    }

    private func unitStatus(_ unit: LocalModelUnit) -> String {
        if let bytes = installedBytes(unit) { return "\(Self.megabytes(bytes))" }
        if case .downloading = runtime.localModelState, requiredUnits.contains(unit) {
            return "Downloading"
        }
        return "Not installed"
    }

    private var downloadLabel: String {
        let missing = requiredUnits.reduce(Int64(0)) { total, unit in
            installedBytes(unit) == nil ? total + unit.approximateBytes : total
        }
        return "Download \(Self.megabytes(missing))"
    }

    static func unitName(_ unit: LocalModelUnit) -> String {
        switch unit {
        case .whisper: "Whisper Large-v3-Turbo"
        case .parakeet: "Parakeet TDT v3"
        case .parakeetUltra: "Parakeet Ultra"
        case .cohere: "Cohere Transcribe"
        case .canary: "Canary 1B v2"
        case .ctcAligner: "Timing aligner"
        case .diarizer: "Speaker models"
        case .nemotronDiarizer: "Nemotron 3 Diarization"
        case .voiceActivity: "Voice detector"
        }
    }

    static func megabytes(_ bytes: Int64) -> String {
        bytes >= 1_024 * 1_024 * 1_024
            ? String(format: "%.1f GB", Double(bytes) / (1_024 * 1_024 * 1_024))
            : "\(max(1, bytes / 1_048_576)) MB"
    }

    private func speakerToggle(
        _ title: String, keyPath: WritableKeyPath<SpeakerRecognitionSettings, Bool>
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { runtime.settings.processing.speakers[keyPath: keyPath] },
                set: { newValue in
                    var settings = runtime.settings
                    settings.processing.speakers[keyPath: keyPath] = newValue
                    runtime.update(settings: settings)
                }
            ))
    }
}

/// The local engine choice, shared between Settings and the setup wizard.
///
/// Picking a model that is not on disk starts its download immediately; the
/// row says what it costs before the click.
struct LocalModelChoicePicker: View {
    let selected: LocalTranscriptionModel
    /// Applied by whoever owns the choice: Settings writes it straight to the
    /// runtime, the wizard routes it through `SetupModel`.
    let select: (LocalTranscriptionModel) -> Void

    var body: some View {
        // The setter is written out rather than passed as `set: select`, so the
        // call is made from this main-actor body instead of handing the binding
        // a function value it could call from anywhere.
        Picker("Model", selection: Binding(get: { selected }, set: { newValue in select(newValue) })) {
            ForEach(LocalTranscriptionModel.pickerRows(selected: selected), id: \.rawValue) { model in
                choice(model)
            }
        }
        .pickerStyle(.radioGroup)
    }

    private func choice(_ model: LocalTranscriptionModel) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Self.title(model))
            Text(Self.blurb(model)).font(.caption).foregroundStyle(.secondary)
        }
        .tag(model)
    }

    static func title(_ model: LocalTranscriptionModel) -> String {
        switch model {
        case .parakeet: "Parakeet TDT v3"
        case .parakeetUltra: "Parakeet Ultra"
        case .cohere: "Cohere Transcribe"
        case .whisper: "Whisper Large-v3-Turbo"
        case .canary: "Canary 1B v2"
        case .apple: "Apple Speech"
        }
    }

    private static func blurb(_ model: LocalTranscriptionModel) -> String {
        switch model {
        case .apple:
            "Built in to your Mac"
        case .parakeet:
            "Most accurate. 25 languages. 460 MB"
        case .cohere:
            // Rendered only on installs that already have it selected.
            "Slower and larger than Parakeet. 2.1 GB plus 600 MB"
        case .whisper:
            "Previous engine. 624 MB"
        case .parakeetUltra, .canary:
            // Never rendered: not offered. Here because the switch is
            // exhaustive.
            "Not offered."
        }
    }
}
