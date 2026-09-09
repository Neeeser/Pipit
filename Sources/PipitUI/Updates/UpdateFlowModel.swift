import Foundation
import Observation
import PipitCore
import PipitServices

/// What the update window shows, and the answers it owes Sparkle.
///
/// Sparkle drives the update as a sequence of calls on its user driver, each
/// with a reply the driver has to send once the person has decided. This holds
/// that sequence as one state the window draws from, and keeps the pending
/// reply so a button, or the window's close box, can answer it. Nothing here
/// knows Sparkle's types, so the sequence is tested without it.
@MainActor
@Observable
public final class UpdateFlowModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case checking
        /// An update is on offer and waits for a choice.
        case found
        case downloading
        case extracting
        /// Downloaded and unpacked. Installing quits and relaunches Pipit.
        case readyToInstall
        case installing
        /// The launch after an update. Shown only while the add-on still has
        /// to be updated, which is the second step of the same update.
        case installed
        case upToDate
        case failed
    }

    public enum Choice: Equatable, Sendable {
        case install
        case skip
        case later
    }

    public struct Offer: Equatable, Sendable {
        public var version: String
        public var contentLength: UInt64

        public init(version: String, contentLength: UInt64) {
            self.version = version
            self.contentLength = contentLength
        }
    }

    /// The Firefox add-on's part of the update.
    public struct AddOn: Equatable, Sendable {
        public var installedVersion: String?
        public var needsUpdate: Bool

        public init(installedVersion: String? = nil, needsUpdate: Bool = false) {
            self.installedVersion = installedVersion
            self.needsUpdate = needsUpdate
        }
    }

    public private(set) var phase: Phase = .idle
    public private(set) var offer: Offer?
    public private(set) var notes: ReleaseNotes?
    /// The notes could not be fetched. The window says so in one line and
    /// the update goes ahead without them.
    public private(set) var notesUnavailable = false
    /// Download or extraction progress, 0 to 1. Nil while the size is unknown.
    public private(set) var progress: Double?
    public private(set) var errorText: String?
    /// Whether the person asked for this check. A scheduled check that finds
    /// nothing says nothing.
    public private(set) var userInitiated = false
    public var addOn = AddOn()
    /// The version this copy of Pipit runs, for the "you have" line.
    public var runningVersion = ""

    private var choiceReply: ((Choice) -> Void)?
    private var cancelReply: (() -> Void)?
    private var acknowledgeReply: (() -> Void)?
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0

    public init() {}

    /// Whether the window should be on screen for this state.
    public var needsWindow: Bool {
        switch phase {
        case .idle: false
        case .checking: userInitiated
        case .upToDate: userInitiated || addOn.needsUpdate
        case .found, .downloading, .extracting, .readyToInstall, .installing, .failed: true
        case .installed: addOn.needsUpdate
        }
    }

    /// The add-on is the second step of this update, still to do.
    public var addOnStepPending: Bool { addOn.needsUpdate }

    // MARK: - what Sparkle reports

    public func checkStarted(userInitiated: Bool, cancel: @escaping () -> Void) {
        reset()
        self.userInitiated = userInitiated
        cancelReply = cancel
        phase = .checking
    }

    public func updateFound(_ offer: Offer, userInitiated: Bool, reply: @escaping (Choice) -> Void) {
        reset()
        self.userInitiated = userInitiated
        self.offer = offer
        choiceReply = reply
        phase = .found
    }

    public func notesLoaded(_ notes: ReleaseNotes) {
        self.notes = notes
        notesUnavailable = false
    }

    public func notesFailed() {
        notesUnavailable = notes == nil
    }

    public func upToDate(acknowledge: @escaping () -> Void) {
        let wasUserInitiated = userInitiated
        reset()
        userInitiated = wasUserInitiated
        acknowledgeReply = acknowledge
        phase = .upToDate
        if !needsWindow { self.acknowledge() }
    }

    public func failed(_ message: String, acknowledge: @escaping () -> Void) {
        let keptOffer = offer
        reset()
        offer = keptOffer
        errorText = message
        acknowledgeReply = acknowledge
        phase = .failed
    }

    public func downloadStarted(cancel: @escaping () -> Void) {
        choiceReply = nil
        cancelReply = cancel
        expectedBytes = 0
        receivedBytes = 0
        progress = nil
        phase = .downloading
    }

    public func expect(bytes: UInt64) {
        expectedBytes = bytes
        progress = bytes == 0 ? nil : 0
    }

    public func received(bytes: UInt64) {
        receivedBytes += bytes
        guard expectedBytes > 0 else { return }
        progress = min(1, Double(receivedBytes) / Double(expectedBytes))
    }

    public func extracting(progress: Double) {
        cancelReply = nil
        self.progress = min(1, max(0, progress))
        phase = .extracting
    }

    public func readyToInstall(reply: @escaping (Choice) -> Void) {
        cancelReply = nil
        choiceReply = reply
        progress = nil
        phase = .readyToInstall
    }

    public func installing() {
        choiceReply = nil
        cancelReply = nil
        phase = .installing
    }

    /// The launch after an update. Returns whether the window stays to ask
    /// for the add-on; otherwise the acknowledgement is sent at once.
    @discardableResult
    public func installedAndRelaunched(acknowledge: @escaping () -> Void) -> Bool {
        reset()
        acknowledgeReply = acknowledge
        phase = .installed
        guard addOn.needsUpdate else {
            self.acknowledge()
            return false
        }
        return true
    }

    /// Sparkle closed the session: the update was dismissed, skipped, or
    /// installed, or an error was acknowledged.
    public func dismissed() {
        reset()
    }

    /// The add-on state as the runtime sees it now. While the window waits on
    /// the add-on step, this is what ends the wait.
    public func syncAddOn(from status: RuntimeStatus) {
        let current = AddOn(
            installedVersion: status.firefoxAddOnVersion, needsUpdate: status.firefoxAddOnNeedsUpdate
        )
        guard current != addOn else { return }
        addOn = current
        if phase == .installed || phase == .upToDate, !addOn.needsUpdate { acknowledge() }
    }

    // MARK: - what the person decides

    public func install() { answer(.install) }
    public func skip() { answer(.skip) }
    public func later() { answer(.later) }

    public func cancel() {
        let reply = cancelReply
        reset()
        reply?()
    }

    public func acknowledge() {
        let reply = acknowledgeReply
        reset()
        reply?()
    }

    /// The window's close box. Whatever is pending is answered the way
    /// closing a dialog answers it.
    public func windowClosed() {
        if choiceReply != nil { later() } else if cancelReply != nil { cancel() } else { acknowledge() }
    }

    private func answer(_ choice: Choice) {
        guard let reply = choiceReply else { return }
        choiceReply = nil
        if choice == .install, phase == .found {
            // Sparkle reports the download next; until then the button has
            // been pressed and the window waits.
            progress = nil
            phase = .downloading
        }
        reply(choice)
    }

    private func reset() {
        phase = .idle
        offer = nil
        notes = nil
        notesUnavailable = false
        progress = nil
        errorText = nil
        userInitiated = false
        choiceReply = nil
        cancelReply = nil
        acknowledgeReply = nil
        expectedBytes = 0
        receivedBytes = 0
    }
}
