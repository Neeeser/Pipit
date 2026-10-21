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
///
/// With a sender that sends, the report's ID and deletion secret come from
/// it before the preview is built, so the ID the preview shows is the one
/// sent. They are given back when the window closes without the report
/// having been sent or queued.
@MainActor
@Observable
public final class ReportProblemModel {
    public enum Phase: Equatable {
        case loading
        case ready
        case failed
    }

    /// `user` from the menus, `crash` from the crash prompt.
    public let kind: DiagnosticReport.Kind
    public private(set) var phase = Phase.loading
    /// The report without a note or address, for the preview.
    public private(set) var preview: DiagnosticBundle?
    /// Held to the server's limits by `holdToLimits`, which the view calls on
    /// every change. Not in a `didSet`: under `@Observable` an assignment
    /// there goes through the setter again.
    public var note = ""
    public var contact = ""
    public private(set) var isWorking = false
    /// Sent or queued. Sending again would only resend the queued body.
    public private(set) var isSent = false
    /// One line about the last export or send.
    public private(set) var status: String?

    /// Only a `user` report carries a note and an address.
    public var takesNote: Bool { kind == .user }

    @ObservationIgnored private let collector: DiagnosticReportCollector
    @ObservationIgnored private let sender: any DiagnosticReportSending
    @ObservationIgnored private let since: Date?
    @ObservationIgnored private var contents: DiagnosticBundleContents?
    @ObservationIgnored private var identity: DiagnosticReportIdentity?
    /// Whether the sender keeps a secret for `identity` that is given back
    /// when the window closes.
    @ObservationIgnored private var holdsIdentity = false
    @ObservationIgnored private var isClosed = false
    /// A send under way. A close in the meantime leaves the identity to it.
    @ObservationIgnored private var isSending = false
    @ObservationIgnored private let createdAt = Date()

    /// `since` starts a `crash` report at the crashed launch. `collector` is
    /// for a test that keeps the real Keychain out of it.
    public init(
        runtime: PipitRuntime, sender: any DiagnosticReportSending, kind: DiagnosticReport.Kind = .user,
        since: Date? = nil, collector: DiagnosticReportCollector? = nil
    ) {
        self.collector = collector ?? DiagnosticReportCollector(runtime: runtime)
        self.sender = sender
        self.kind = kind
        self.since = since
    }

    public func load() async {
        phase = .loading
        if identity == nil { await takeIdentity() }
        let read = await collector.contents()
        contents = read
        await rebuildPreview()
    }

    /// The window closed. An identity the report was not sent under is given
    /// back, off the main actor, since that writes the Keychain.
    public func windowClosed() {
        isClosed = true
        if !isSending { releaseIdentity() }
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
        guard !isSent, !isSending else { return }
        // From before the report is built: a close while it is built or sent
        // leaves the identity to this, which gives back whatever it still
        // holds once it is done.
        isSending = true
        defer {
            isSending = false
            if isClosed { releaseIdentity() }
        }
        guard let bundle = await finalBundle() else { return }
        isWorking = true
        defer { isWorking = false }
        switch await sender.send(bundle.report) {
        case .sent:
            isSent = true
            holdsIdentity = false
            status = "Sent."
        case .willRetry:
            isSent = true
            holdsIdentity = false
            status = "Pipit will send the report when it can."
        case .rejected, .failed:
            // The sender dropped the secret with the report. Another try
            // goes under a new identity, which the preview shows.
            holdsIdentity = false
            status = "Could not send the report. Export it instead."
            guard !isClosed else { return }
            await takeIdentity()
            await rebuildPreview()
        case .unavailable:
            status = "Sending is not available in this version. Export the report instead."
        }
    }

    /// The report with the note and address as they stand.
    private func finalBundle() async -> DiagnosticBundle? {
        guard let contents, let identity else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            return try await DiagnosticReportCollector.bundle(
                contents, kind: kind, identity: identity, createdAt: createdAt, since: since,
                note: takesNote ? note : nil, contact: takesNote ? contact : nil
            )
        } catch {
            Log.ui.error("diagnostic report not built: \(String(describing: error), privacy: .public)")
            status = "Could not build the report."
            return nil
        }
    }

    private func rebuildPreview() async {
        guard let contents, let identity else { return }
        do {
            preview = try await DiagnosticReportCollector.bundle(
                contents, kind: kind, identity: identity, createdAt: createdAt, since: since
            )
            phase = .ready
        } catch {
            Log.ui.error("diagnostic report not built: \(String(describing: error), privacy: .public)")
            phase = .failed
        }
    }

    /// An identity from the sender, asked off the main actor because it
    /// writes the Keychain, or a provisional one when the sender sends
    /// nothing. One that arrives after the window closed goes straight back.
    private func takeIdentity() async {
        let sender = self.sender
        let held = await Task.detached(priority: .userInitiated) { sender.prepareReportIdentity() }.value
        identity = held ?? .provisional()
        holdsIdentity = held != nil
        if isClosed, !isSending { releaseIdentity() }
    }

    private func releaseIdentity() {
        guard holdsIdentity, let identity else { return }
        holdsIdentity = false
        let sender = self.sender
        Task.detached(priority: .utility) { sender.discardReportIdentity(identity) }
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
