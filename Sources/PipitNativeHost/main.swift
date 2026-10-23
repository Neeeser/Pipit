import Foundation
import PipitCore

// Pipit's native messaging host for Firefox and the Chromium browsers.
//
// A compiled binary on purpose. Browsers spawn hosts with a minimal PATH, so an
// interpreter shebang resolves to nothing and the host silently never starts:
// connectNative appears to succeed and onDisconnect fires with a null error.
//
// The host does nothing but relay. Browser stdin speaks the 4-byte
// length-prefixed protocol; the app side is newline-delimited JSON over a Unix
// socket in Application Support. If the app is not running, messages are dropped
// and the browser side is told so, which is exactly the behaviour that lets
// Pipit fall back to native detection.

let hostVersion = "1.2.1"

/// Reads the browser's length-prefixed messages from standard input.
struct BrowserMessageReader {
    /// Why reading stopped: the browser closed the pipe, or sent something
    /// that is not a message.
    private(set) var endedOnError = false

    /// Reads exactly `count` bytes, or nil once the stream ends.
    private func readExactly(_ count: Int) -> Data? {
        var data = Data()
        while data.count < count {
            let chunk = FileHandle.standardInput.readData(ofLength: count - data.count)
            if chunk.isEmpty { return nil }
            data.append(chunk)
        }
        return data
    }

    mutating func next() -> [String: Any]? {
        guard let header = readExactly(4) else { return nil }
        let length =
            Int(header[header.startIndex])
            | Int(header[header.startIndex + 1]) << 8
            | Int(header[header.startIndex + 2]) << 16
            | Int(header[header.startIndex + 3]) << 24
        // A hostile or confused peer must not be able to make the host allocate
        // without bound; browsers cap messages far below this.
        guard length > 0, length <= 1_048_576 else {
            endedOnError = true
            return nil
        }
        guard let payload = readExactly(length) else { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            endedOnError = true
            return nil
        }
        return object
    }
}

/// Writes a length-prefixed reply back to the browser.
func replyToBrowser(_ object: [String: Any]) {
    guard let payload = try? JSONSerialization.data(withJSONObject: object) else { return }
    var length = UInt32(payload.count).littleEndian
    var frame = Data(bytes: &length, count: 4)
    frame.append(payload)
    FileHandle.standardOutput.write(frame)
}

// Firefox passes the manifest path and the add-on's identifier; the Chromium
// browsers pass the calling extension's origin.
let browser = SensorRelay.browser(forArguments: CommandLine.arguments)

// The host's own events, in `nativehost-YYYY-MM-DD.ndjson` beside the app's.
// Nothing the browser sends is recorded: only that the host ran, whether
// Pipit answered, and how it ended.
let diagnostics = DiagnosticLog(layout: .standard, configuration: .nativeHost)
diagnostics.record(.nativeHostStarted(browser: browser))

/// Pipit did not answer: `nativehost.connect.<errno>` where connecting
/// failed, `nativehost.write` where an open socket refused the message.
func recordUnreachable(_ connection: SensorAppConnection) {
    let failure = connection.lastConnectError
    let code =
        failure == 0
        ? DiagnosticCode("nativehost", "write") : DiagnosticCode("nativehost", "connect", number: Int(failure))
    diagnostics.record(.nativeHostAppUnreachable(code: code))
}

let socketPath = SensorTransport.socketURL(
    applicationSupport: SensorTransport.defaultApplicationSupport
).path
// Watches the socket and reconnects when Pipit restarts. Not unit tested
// beyond its parts: the test target cannot hold a live browser on the other
// end.
let connection = SensorAppConnection(socketPath: socketPath)

if !connection.connect() { recordUnreachable(connection) }
replyToBrowser(["type": "ready", "connected": connection.isConnected, "hostVersion": hostVersion])

// Notices a Pipit restart on its own. Two seconds is well inside the add-on's
// own reconnect backoff and costs one poll of a socket.
let watchdog = connection.startWatching(every: .seconds(2))

/// Relays until the browser closes the pipe. Returns how many messages reached
/// Pipit, and whether the input ended on something that was not a message.
func relayMessages() -> (relayed: Int, endedOnError: Bool) {
    var reader = BrowserMessageReader()
    var relayed = 0
    while let raw = reader.next() {
        guard let message = SensorRelay.message(from: raw, browser: browser, hostVersion: hostVersion) else {
            continue
        }
        let delivered = connection.deliver(message)
        if delivered {
            relayed += 1
        } else {
            // Merged by the log while Pipit stays away.
            recordUnreachable(connection)
        }
        if raw["type"] as? String == "hello" || !delivered {
            replyToBrowser(["type": "ack", "connected": delivered])
        }
    }
    return (relayed, reader.endedOnError)
}

let outcome = relayMessages()
connection.send(.goodbye(browser: browser))
connection.disconnect()
diagnostics.record(
    .nativeHostExited(reason: outcome.endedOnError ? .error : .browserClosed, relayed: outcome.relayed)
)
diagnostics.flush(timeout: 1)
