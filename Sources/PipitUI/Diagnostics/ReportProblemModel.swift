import AppKit
import Foundation
import Observation
import PipitCore
import PipitServices
import UniformTypeIdentifiers

/// The Report a Problem window's state: the report as it would go, the
/// person's note and address, and what became of the last export or send.
///
/// The disk is read once, when the window opens. The report is built again
/// for an export or a send, with the note and address as they stand then, from
/// what was read; the preview shows that report without them, and the two
/// fields beside it.
@MainActor
@Observable
public final class ReportProblemModel {
    public enum Phase: Equatable {
        case loading
        case ready
        case failed
    }

    public private(set) var phase = Phase.loading
    /// The report without a note or address, for the preview.
    public private(set) var preview: DiagnosticBundle?
    /// Held to the server's limits by `holdToLimits`, which the view calls on
    /// every change. Not in a `didSet`: under `@Observable` an assignment
    /// there goes through the setter again.
    public var note = ""
    public var contact = ""
    public private(set) var isWorking = false
    /// One line about the last export or send.
    public private(set) var status: String?

    @ObservationIgnored private let collector: DiagnosticReportCollector
    @ObservationIgnored private let sender: any DiagnosticReportSending
    @ObservationIgnored private var contents: DiagnosticBundleContents?
    @ObservationIgnored private let identity = DiagnosticReportIdentity.provisional()
    @ObservationIgnored private let createdAt = Date()

    /// `collector` is for a test that keeps the real Keychain out of it.
    public init(
        runtime: PipitRuntime, sender: any DiagnosticReportSending, collector: DiagnosticReportCollector? = nil
    ) {
        self.collector = collector ?? DiagnosticReportCollector(runtime: runtime)
        self.sender = sender
    }

    public func load() async {
        phase = .loading
        let read = await collector.contents()
        contents = read
        do {
            preview = try await DiagnosticReportCollector.bundle(
                read, kind: .user, identity: identity, createdAt: createdAt
            )
            phase = .ready
        } catch {
            Log.ui.error("diagnostic report not built: \(String(describing: error), privacy: .public)")
            phase = .failed
        }
    }

    /// Asks where to save the report, and saves it there.
    public func export() async {
        guard let bundle = await finalBundle() else { return }
        do {
            if let url = try await DiagnosticExportPanel.save(bundle) {
                status = "Saved \(url.lastPathComponent)"
            }
        } catch {
            status = "Could not save the report."
        }
    }

    public func send() async {
        guard let bundle = await finalBundle() else { return }
        isWorking = true
        defer { isWorking = false }
        switch await sender.send(bundle.report) {
        case .sent: status = "Sent."
        case .willRetry: status = "Pipit will send the report when it can."
        case .rejected, .failed: status = "Could not send the report. Export it instead."
        case .unavailable: status = "Sending is not available in this version. Export the report instead."
        }
    }

    /// The report with the note and address as they stand.
    private func finalBundle() async -> DiagnosticBundle? {
        guard let contents else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            return try await DiagnosticReportCollector.bundle(
                contents, kind: .user, identity: identity, createdAt: createdAt, note: note, contact: contact
            )
        } catch {
            Log.ui.error("diagnostic report not built: \(String(describing: error), privacy: .public)")
            status = "Could not build the report."
            return nil
        }
    }

    /// Cuts the note and the address to what the server takes.
    public func holdToLimits() {
        let heldNote = Self.limited(note, to: DiagnosticReportLimits.noteLength)
        if heldNote != note { note = heldNote }
        let heldContact = Self.limited(contact, to: DiagnosticReportLimits.contactLength)
        if heldContact != contact { contact = heldContact }
    }

    /// Cut to what the server takes, counted as it counts, in UTF-16.
    static func limited(_ text: String, to limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        var cut = ""
        for character in text {
            guard cut.utf16.count + character.utf16.count <= limit else { break }
            cut.append(character)
        }
        return cut
    }
}

/// The save panel for an exported report.
@MainActor
enum DiagnosticExportPanel {
    /// Asks where to save `bundle` and writes the `.zip` there. Nil when the
    /// person cancelled.
    static func save(_ bundle: DiagnosticBundle) async throws -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DiagnosticExport.fileName(createdAt: bundle.report.createdAt)
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try await Task.detached(priority: .userInitiated) {
            try DiagnosticExport.archive(bundle).write(to: url, options: .atomic)
        }.value
        return url
    }
}
