import Foundation

/// What both browser relays do with a message from the add-on.
///
/// Firefox and the Chromium browsers reach Pipit through `pipit-nativehost`,
/// a process the browser starts. Safari reaches it through the app extension
/// inside Pipit.app, which Safari hands one message at a time. The add-on is
/// the same in all of them, so the translation lives here and both relays
/// call it.
public enum SensorRelay {
    /// Which browser started the host, from the arguments it was given.
    ///
    /// Firefox passes the path of the host manifest and the add-on's
    /// identifier. Chrome and every Chromium browser pass the calling origin,
    /// `chrome-extension://<id>/`, and nothing that names the browser. Reading
    /// only for "Chrome" in a path took every Chromium browser for Firefox.
    public static func browser(forArguments arguments: [String]) -> BrowserKind {
        let chromium = arguments.dropFirst().contains { argument in
            argument.hasPrefix("chrome-extension://")
                || argument.contains("Chrome")
                || argument.contains("chromium")
        }
        return chromium ? .chrome : .firefox
    }

    /// Translates one extension message into the app's wire format.
    public static func message(
        from raw: [String: Any], browser: BrowserKind, hostVersion: String
    ) -> SensorMessage? {
        switch raw["type"] as? String {
        case "hello":
            return .hello(
                SensorMessage.Hello(
                    browser: browser,
                    extensionVersion: raw["extensionVersion"] as? String,
                    hostVersion: hostVersion,
                    protocolVersion: raw["protocol"] as? Int
                ))
        case "tab_removed":
            guard let tabID = raw["tabId"] as? Int else { return nil }
            return .tabClosed(browser: browser, tabID: tabID)
        case "state":
            let provider: MeetingProvider =
                switch raw["provider"] as? String {
                case "meet": .googleMeet
                case "zoom": .zoom
                default: .unknown
                }
            let state = BrowserMeetingState(rawValue: (raw["state"] as? String) ?? "unknown") ?? .unknown
            let timestamp = (raw["sentAt"] as? Double).map { $0 / 1_000 } ?? Date().timeIntervalSince1970
            return .event(
                BrowserMeetingEvent(
                    browser: browser,
                    provider: provider,
                    state: state,
                    timestamp: timestamp,
                    url: raw["url"] as? String,
                    meetingID: raw["meetingId"] as? String,
                    title: raw["title"] as? String,
                    muted: raw["muted"] as? Bool,
                    tabID: raw["tabId"] as? Int,
                    participants: raw["participants"] as? [String],
                    people: people(from: raw["people"]),
                    activeSpeaker: raw["activeSpeaker"] as? String,
                    otherAudibleTabs: raw["otherAudibleTabs"] as? Int
                ))
        default:
            return nil
        }
    }

    /// The roster a page reported. Anything without an identifier is dropped
    /// rather than given a made-up one: an identifier is what ties a person to a
    /// voice, and a placeholder would tie them to the wrong one.
    static func people(from value: Any?) -> [BrowserParticipant]? {
        guard let rows = value as? [[String: Any]] else { return nil }
        let parsed = rows.compactMap { row -> BrowserParticipant? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            let name = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return BrowserParticipant(
                id: String(id.prefix(200)),
                displayName: name.map { String($0.prefix(80)) },
                isSelf: (row["isSelf"] as? Bool) ?? false,
                isMuted: row["muted"] as? Bool
            )
        }
        return parsed.isEmpty ? nil : Array(parsed.prefix(50))
    }
}

/// A relay's connection to Pipit's socket, reconnecting when the app restarts.
///
/// Firefox keeps the host process alive for as long as the add-on's port is
/// open, which is the life of the browser. Pipit restarts underneath it, on
/// every update among other things, and the socket it connected to goes away.
/// The extension only speaks when a meeting page changes, so a reconnect that
/// waited for the next message left the add-on looking absent for hours, and
/// the hello, which the extension sends once per port, never reached the
/// restarted app. The connection watches the socket itself and greets the app
/// again each time it comes back.
///
/// The Safari extension holds one of these across the requests Safari hands
/// it, for as long as the system keeps that process.
public final class SensorAppConnection: @unchecked Sendable {
    private let socketPath: String
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    /// The last hello the extension sent, replayed on every reconnect.
    private var greeting: SensorMessage?
    private var lastConnectErrno: Int32 = 0

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return descriptor >= 0
    }

    /// The `errno` of the last connect that failed, or 0. `ENOENT` is Pipit
    /// not running, `ECONNREFUSED` a socket left behind by one that quit.
    public var lastConnectError: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return lastConnectErrno
    }

    /// Connects, and greets the app with the last hello if there is one.
    @discardableResult
    public func connect() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard open() else { return false }
        if let greeting { _ = write(greeting) }
        return true
    }

    /// Reconnects when the socket has gone away. The host calls this from a
    /// timer, so a Pipit restart is noticed within seconds rather than at the
    /// next meeting page.
    public func watch() {
        lock.lock()
        defer { lock.unlock() }
        if descriptor >= 0 {
            var pollable = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let ready = poll(&pollable, 1, 0)
            let gone =
                ready > 0
                && (pollable.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0
                    || (pollable.revents & Int16(POLLIN) != 0 && peekIsEOF()))
            if !gone { return }
            closeDescriptor()
        }
        if open(), let greeting { _ = write(greeting) }
    }

    /// Calls `watch()` on a background queue every `interval` until the
    /// returned timer is cancelled.
    ///
    /// The timer is built here rather than in the host's `main.swift` because
    /// top-level code there runs on the main actor. A handler closure written
    /// there inherits that isolation, and the Swift 6 runtime traps when the
    /// timer fires it off the main thread. The host died two seconds after
    /// every launch, and the add-on reconnected in a loop.
    public func startWatching(every interval: DispatchTimeInterval) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.pipit.sensor-host.watch"))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.watch() }
        timer.resume()
        return timer
    }

    /// A readable socket with nothing to read is the peer having closed it.
    private func peekIsEOF() -> Bool {
        var byte: UInt8 = 0
        let count = recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return count == 0
    }

    /// Opens the socket without greeting. The caller holds the lock.
    private func open() -> Bool {
        closeDescriptor()
        guard var address = UnixSocketAddress.make(path: socketPath) else {
            lastConnectErrno = ENAMETOOLONG
            return false
        }
        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else {
            lastConnectErrno = errno
            return false
        }
        // A write to a socket the app has closed raises SIGPIPE, which ends the
        // process. The write's own error is the signal this code acts on.
        var noSignal: Int32 = 1
        _ = setsockopt(handle, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(handle, $0, UnixSocketAddress.size)
            }
        }
        guard result == 0 else {
            lastConnectErrno = errno
            close(handle)
            return false
        }
        lastConnectErrno = 0
        descriptor = handle
        return true
    }

    public func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        closeDescriptor()
    }

    /// The caller holds the lock.
    private func closeDescriptor() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    @discardableResult
    public func send(_ message: SensorMessage) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .hello = message { greeting = message }
        if descriptor < 0, !open() { return false }
        return write(message)
    }

    /// Sends, and on a failed write reconnects once and sends again. The app
    /// may have restarted since the last message, and the reconnect greets it
    /// with the last hello, so this message follows one.
    public func deliver(_ message: SensorMessage) -> Bool {
        send(message) || (connect() && send(message))
    }

    /// Writes one message on the open socket. The caller holds the lock.
    private func write(_ message: SensorMessage) -> Bool {
        guard let line = try? SensorTransport.encodeLine(message) else { return false }
        return line.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written <= 0 {
                    if errno == EINTR { continue }
                    closeDescriptor()
                    return false
                }
                offset += written
            }
            return true
        }
    }
}
