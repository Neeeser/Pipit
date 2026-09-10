import AppKit
import PipitCore
import SwiftUI

/// The update window: the app and the add-on as the steps of one update.
struct UpdateWindowView: View {
    let model: UpdateFlowModel
    /// Hands the bundled add-on to Firefox.
    let installAddOn: () -> Void
    /// The notes list's own height, so the scroll view can take that much
    /// up to a cap. A scroll view offered no height takes none.
    @State private var notesHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch model.phase {
            case .checking:
                progressRow(label: "Checking for updates…", fraction: nil)
            case .found, .downloading, .extracting, .readyToInstall, .installing:
                steps
                if model.phase == .found { notes }
                if let label = progressLabel { progressRow(label: label, fraction: model.progress) }
            case .installed, .upToDate:
                steps
            case .failed:
                Text(model.errorText ?? "The update could not be installed.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                EmptyView()
            }
            buttons
        }
        .padding(20)
        .frame(width: 500, alignment: .topLeading)
    }

    // MARK: - header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        switch model.phase {
        case .checking: "Checking for updates"
        case .found, .downloading, .extracting, .readyToInstall:
            "Pipit \(model.offer?.version ?? "") is available"
        case .installing: "Installing Pipit \(model.offer?.version ?? "")"
        case .installed: "Pipit \(model.runningVersion) is installed"
        case .upToDate: "Pipit is up to date"
        case .failed: "The update did not finish"
        case .idle: ""
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .found, .downloading, .extracting, .readyToInstall, .installing:
            model.addOnStepPending
                ? "You have \(model.runningVersion). Two parts update together."
                : "You have \(model.runningVersion)."
        case .installed: "One more step. Update the Firefox add-on."
        case .upToDate:
            model.addOnStepPending
                ? "Pipit \(model.runningVersion) is the newest version. The Firefox add-on is behind it."
                : "Pipit \(model.runningVersion) is the newest version."
        case .checking, .failed, .idle: "Version \(model.runningVersion)"
        }
    }

    // MARK: - steps

    private var steps: some View {
        VStack(spacing: 0) {
            if model.phase != .upToDate {
                stepRow(
                    symbol: model.phase == .installed ? "checkmark.circle.fill" : "macwindow",
                    symbolColor: model.phase == .installed ? .green : .secondary,
                    title: "Pipit app",
                    detail: appStepDetail,
                    trailing: model.addOnStepPending && model.phase != .installed ? "Step 1" : nil
                )
            }
            if model.addOnStepPending {
                if model.phase != .upToDate { Divider().padding(.leading, 44) }
                stepRow(
                    symbol: model.phase == .installed || model.phase == .upToDate
                        ? "exclamationmark.circle" : "globe",
                    symbolColor: .secondary,
                    title: "Firefox add-on",
                    detail: addOnStepDetail,
                    trailing: model.phase == .installed || model.phase == .upToDate ? nil : "Step 2"
                ) {
                    if model.phase == .installed || model.phase == .upToDate {
                        Button("Update in Firefox") { installAddOn() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!FirefoxAddOn.isFirefoxInstalled)
                    }
                }
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }

    private var appStepDetail: String {
        if model.phase == .installed { return "\(model.runningVersion) installed" }
        let version = model.offer?.version ?? ""
        let size = model.offer.map { Self.bytes($0.contentLength) } ?? ""
        return "\(model.runningVersion) to \(version), \(size). Pipit restarts."
    }

    private var addOnStepDetail: String {
        switch model.phase {
        case .installed, .upToDate: "Update the add-on."
        default: "Updated after the restart. Firefox asks you to confirm."
        }
    }

    @ViewBuilder
    private func stepRow(
        symbol: String, symbolColor: Color, title: String, detail: String, trailing: String?,
        @ViewBuilder action: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(symbolColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            action()
            if let trailing {
                Text(trailing).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - notes

    @ViewBuilder
    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What changed").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let notes = model.notes {
                if notes.isEmpty {
                    Text("No notes for this release.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(notes.sections.enumerated()), id: \.offset) { _, section in
                                if let title = section.title {
                                    Text(title).font(.callout.weight(.medium))
                                }
                                ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                                    Text(item).font(.callout)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            notesHeight = $0
                        }
                    }
                    // A short list shows whole; a long one scrolls inside the cap.
                    .frame(height: min(max(notesHeight, 20), 220))
                }
            } else if model.notesUnavailable {
                Text("The notes could not be loaded. They are on the release page.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }

    // MARK: - progress

    private var progressLabel: String? {
        switch model.phase {
        case .downloading: "Downloading…"
        case .extracting: "Unpacking…"
        case .installing: "Installing… Pipit restarts in a moment."
        default: nil
        }
    }

    private func progressRow(label: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            if let fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
        }
    }

    private static func bytes(_ count: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(count))
    }

    // MARK: - buttons

    @ViewBuilder
    private var buttons: some View {
        HStack {
            switch model.phase {
            case .found:
                Spacer()
                Button("Skip This Version") { model.skip() }
                Button("Remind Me Later") { model.later() }
                Button("Install Update") { model.install() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .checking, .downloading:
                Spacer()
                Button("Cancel") { model.cancel() }
            case .extracting, .installing:
                Spacer()
            case .readyToInstall:
                Spacer()
                Button("Remind Me Later") { model.later() }
                Button("Install and Restart") { model.install() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .installed, .upToDate:
                if model.addOnStepPending {
                    Text("This closes on its own once the add-on reconnects.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Button(model.addOnStepPending ? "Later" : "OK") { model.acknowledge() }
                    .keyboardShortcut(model.addOnStepPending ? .cancelAction : .defaultAction)
            case .failed:
                Spacer()
                Button("OK") { model.acknowledge() }
                    .keyboardShortcut(.defaultAction)
            case .idle:
                Spacer()
            }
        }
    }
}
