import AppKit
import PipitCore
import PipitLocalAI
import PipitServices
import SwiftUI

/// The body of whichever step the wizard is on.
struct SetupStepContent: View {
    let model: SetupModel

    var body: some View {
        switch model.current {
        case .welcome: WelcomeStep()
        case .backend: BackendStep(model: model)
        case .models: ModelsStep(model: model)
        case .microphone: PermissionStep(model: model, kind: .microphone)
        case .screenRecording: PermissionStep(model: model, kind: .screenRecording)
        case .accessibility: PermissionStep(model: model, kind: .accessibility)
        case .optionalPermissions: OptionalPermissionsStep(model: model)
        case .aiFeatures: AIFeaturesStep(model: model)
        case .firefox: FirefoxStep(model: model)
        case .finish: FinishStep(model: model)
        }
    }
}

/// Title, eyebrow and body, shared by every step so the pages line up.
struct StepHeader: View {
    var eyebrow: String?
    var title: String
    var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let eyebrow {
                Text(eyebrow).font(.caption).foregroundStyle(.tertiary)
            }
            Text(title).font(.title2.weight(.semibold))
            if let message {
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - welcome

struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ApplicationIcon(size: 64)
            StepHeader(
                title: "Pipit records your meetings",
                message: "Each meeting is transcribed, summarized, and saved as files on your Mac."
            )
        }
    }
}

// MARK: - backend

struct BackendStep: View {
    let model: SetupModel
    private var runtime: PipitRuntime { model.runtime }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(eyebrow: "Required", title: "Where transcription runs")

            Picker(
                "",
                selection: Binding(
                    get: { runtime.settings.processing.isFullyLocal ? ProcessingBackendChoice.local : .openAI },
                    set: { model.chooseBackend($0) }
                )
            ) {
                choice(.local, "On this Mac", "Processing runs on this Mac.")
                choice(.openAI, "OpenAI", "Processing runs in the cloud. Needs an OpenAI API key.")
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)

            if !runtime.settings.processing.isFullyLocal {
                Divider()
                OpenAIKeyField(model: model)
            }
        }
        // Covers arriving on this step with the cloud already chosen, which
        // `chooseBackend` does not see.
        .task { await model.lookUpStoredKeyIfNeeded() }
    }

    private func choice(
        _ tag: ProcessingBackendChoice, _ title: String, _ blurb: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(blurb).font(.caption).foregroundStyle(.secondary)
        }
        .tag(tag)
    }
}

/// The OpenAI key, saved to the keychain and checked with one request.
///
/// Shown by the "Where it runs" page when OpenAI transcribes, and by the AI
/// Features page whatever the backend.
struct OpenAIKeyField: View {
    let model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OpenAI API key").font(.headline)
            SecureField("sk-…", text: Binding(get: { model.apiKey }, set: { model.apiKey = $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 380)
            HStack(spacing: 10) {
                Button(model.hasKeyOnDisk && model.apiKey.isEmpty ? "Check saved key" : "Save and check") {
                    Task { await model.saveAndVerifyKey() }
                }
                .disabled(
                    (model.apiKey.isEmpty && !model.hasKeyOnDisk) || model.keyState == .checking
                )
                keyStateLabel
            }
            if model.mayAcceptUnverifiedKey {
                Button("Continue anyway") { model.acceptUnverifiedKey() }
                    .buttonStyle(.link)
                Text("OpenAI could not be reached. Try again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Stored in the macOS keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var keyStateLabel: some View {
        switch model.keyState {
        case .absent:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .verified:
            Label("The key works", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
        case .rejected(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red).font(.caption)
        case .unreachable(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.caption)
        }
    }
}

// MARK: - models

struct ModelsStep: View {
    let model: SetupModel
    private var runtime: PipitRuntime { model.runtime }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                eyebrow: "Required",
                title: "Speech models",
                message: bodyText
            )

            if runtime.settings.processing.usesLocalTranscription {
                LocalModelChoicePicker(
                    selected: model.localModel,
                    select: { choice in Task { await model.chooseLocalModel(choice) } }
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(units, id: \.rawValue) { unit in
                    HStack {
                        Image(systemName: installed(unit) ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(installed(unit) ? .green : .secondary)
                        Text(ProcessingSettingsPane.unitName(unit))
                        Spacer()
                        Text(status(unit)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            downloadControls
        }
    }

    /// The cloud path is not download-free: the diarizer is required in every
    /// configuration because voice memory embeds a cloud diarizer's intervals
    /// locally, and gpt-transcribe returns no timings, so the aligner computes
    /// them here. The line says so before the download list does.
    private var bodyText: String? {
        if runtime.settings.processing.usesLocalTranscription { return nil }
        return "Speaker recognition and word timing still run on this Mac."
    }

    private var units: [LocalModelUnit] {
        LocalModelUnit.allCases.filter { model.snapshot.requiredUnits.contains($0) }
    }

    private func installed(_ unit: LocalModelUnit) -> Bool {
        runtime.localModelState.present.bytes(for: unit) != nil
    }

    private func status(_ unit: LocalModelUnit) -> String {
        if let bytes = runtime.localModelState.present.bytes(for: unit) {
            return "Installed, \(ProcessingSettingsPane.megabytes(bytes))"
        }
        if runtime.localModelState.isBusy { return "Downloading" }
        return "About \(ProcessingSettingsPane.megabytes(unit.approximateBytes))"
    }

    @ViewBuilder
    private var downloadControls: some View {
        switch runtime.localModelState {
        case .downloading(let fraction, let detail, _):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Text("Models keep downloading in the background.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message, _):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.caption)
            Button("Try again") { Task { await model.startModelDownload() } }
        case .notInstalled:
            Button(downloadLabel) { Task { await model.startModelDownload() } }
                .buttonStyle(.borderedProminent)
        case .installed, .outdated:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        }
    }

    private var downloadLabel: String {
        let missing = model.snapshot.missingUnits.reduce(Int64(0)) { $0 + $1.approximateBytes }
        return "Download about \(ProcessingSettingsPane.megabytes(missing))"
    }
}

// MARK: - one permission

struct PermissionStep: View {
    let model: SetupModel
    let kind: PermissionKind

    private var status: PermissionStatus { model.status(for: kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                eyebrow: kind.isRequired ? "Required" : "Optional",
                title: kind.title,
                message: kind.rationale
            )

            liveState

            if !status.isUsable {
                SettingsPaneIllustration(kind: kind)
                    .frame(maxWidth: 420)

                // Shown for a plain denial too, not only the granted-but-not-
                // effective state. A list pane keeps its old entry when a build is
                // re-signed, and switching that stale row on does nothing for the
                // running binary: it has to be removed with the minus button and
                // added again. Without the advice here that is a dead end the user
                // has to work out alone.
                if let advice = status.advice, status.state != .notDetermined {
                    Label(advice, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 14) {
                    // One call either way. For a prompt permission it raises the
                    // prompt; for a list permission it is what puts Pipit into
                    // the list, and the model opens the pane straight after so the
                    // row the illustration shows is actually there.
                    Button(actionLabel) { Task { await model.request(kind) } }
                        .buttonStyle(.borderedProminent)

                    if kind.acceptsDroppedApplication { AppDragChip() }
                }
            }
        }
    }

    @ViewBuilder
    private var liveState: some View {
        if status.isUsable {
            Label("\(kind.title) is on", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(waitingText).foregroundStyle(.secondary)
            }
        }
    }

    private var waitingText: String {
        kind.isGrantedByPrompt
            ? "Waiting for you to allow it"
            : "Waiting for you to switch \(ApplicationIdentity.name) on"
    }

    private var actionLabel: String {
        if kind.isGrantedByPrompt, status.state == .notDetermined { return "Allow \(kind.title)" }
        // Not the pane name. On macOS 27 that reads "Open Device Control and Data
        // Access settings", which is a button wider than the illustration above
        // it. The picture already says which pane opens.
        return "Open System Settings"
    }
}

// MARK: - the optional pair

struct OptionalPermissionsStep: View {
    let model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(eyebrow: "Optional", title: "Calendar and notifications")
            row(.calendar)
            Divider()
            row(.notifications)
        }
    }

    private func row(_ kind: PermissionKind) -> some View {
        let status = model.status(for: kind)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: status.isUsable ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(status.isUsable ? .green : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title).font(.body.weight(.medium))
                Text(kind.rationale).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !status.isUsable {
                Button("Connect") { Task { await model.request(kind) } }
            }
        }
    }
}

// MARK: - AI features

/// The OpenAI key and what it is used for. Every feature is on by default,
/// and this is where a person switches one off.
struct AIFeaturesStep: View {
    let model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                eyebrow: "Optional",
                title: "AI Features",
                message: "OpenAI writes a title, summary, and notes for each meeting and suggests speaker names."
            )
            OpenAIKeyField(model: model)
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Model").font(.headline)
                MetadataModelPicker(runtime: model.runtime)
            }
            Divider()
            EnrichmentToggles(runtime: model.runtime)
        }
        .task { await model.lookUpStoredKey() }
    }
}

// MARK: - Firefox

struct FirefoxStep: View {
    let model: SetupModel

    private var addOnState: FirefoxAddOnState { model.firefoxAddOnState }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                eyebrow: "Optional",
                title: "Firefox add-on",
                message: "Improves meeting detection in Firefox."
            )

            HStack(spacing: 8) {
                Image(systemName: addOnState.symbol)
                    .foregroundStyle(addOnState.color)
                Text(addOnState.title)
                Spacer()
            }
            Text(addOnState.detail)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if addOnState.offersInstall {
                FirefoxAddOnInstallButton(prepareRelay: { model.installHost() })
            }
            if addOnState.offersUpdate {
                FirefoxAddOnInstallButton(prepareRelay: { model.installHost() }, role: .update)
            }

            FirefoxAddOnCheck(
                access: model.runtime.settings.firefoxProfileAccess,
                state: addOnState,
                check: { model.checkFirefox() }
            )
        }
    }
}

// MARK: - finish

struct FinishStep: View {
    let model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                title: model.canFinish ? "Ready to record" : "Something is still missing",
                message: model.canFinish
                    ? "Pipit starts recording when it notices a meeting."
                    : "Finish the steps marked red on the left."
            )

            if !model.canFinish {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(unfinished) { step in
                        Button {
                            model.jump(to: step.id)
                        } label: {
                            Label(step.id.railTitle, systemImage: "arrow.right.circle")
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show in Dock", isOn: model.setting(\.showsDockIcon))
                Text("Off keeps Pipit in the menu bar only.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Launch at login", isOn: model.setting(\.launchAtLogin))
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Meetings are saved to").font(.body.weight(.medium))
                Text(model.storagePath).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Button("Choose folder…") { model.chooseStorage() }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.open(model.runtime.settings.storageRoot)
                    }
                }
            }

            if model.runtime.localModelState.isBusy {
                Label(
                    "Models are still downloading. Meetings recorded before they arrive are processed after.",
                    systemImage: "arrow.down.circle"
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var unfinished: [SetupStep] {
        model.steps.filter { $0.isRequired && !$0.isSatisfied }
    }
}
