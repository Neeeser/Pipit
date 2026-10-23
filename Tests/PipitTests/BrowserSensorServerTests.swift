import Foundation
import PipitCore
import PipitDetection
import Testing

struct BrowserSensorServerTests {
    @Test("legacy messages without tab numbers remain separate between connections")
    func anonymousTabsStaySeparate() async throws {
        let fixture = try SensorServerFixture()
        let chrome = fixture.connect()
        let brave = fixture.connect()
        #expect(chrome.send(fixture.event(meetingID: "chrome-call", tabID: nil)))
        try await fixture.waitForMessages(1)
        #expect(brave.send(fixture.event(meetingID: nil, tabID: nil, state: .browsing)))
        try await fixture.waitForMessages(2)
        #expect(fixture.readings.currentMeetingID == "chrome-call")
    }

    @Test("Safari meeting state survives its extension process ending between requests")
    func safariTabsSurviveTransientConnections() async throws {
        let fixture = try SensorServerFixture()
        let safari = fixture.connect()
        #expect(safari.send(fixture.event(meetingID: "safari-call", tabID: 1, browser: .safari)))
        try await fixture.waitForMessages(1)
        safari.disconnect()
        try await fixture.waitForConnections(0)
        #expect(fixture.readings.currentMeetingID == "safari-call")
        #expect(fixture.readings.isLoaded)
        let nextRequest = fixture.connect()
        #expect(nextRequest.send(.tabClosed(browser: .safari, tabID: 1)))
        try await fixture.waitForMessages(2)
        #expect(fixture.readings.currentMeetingID == nil)
    }

    @Test("Chromium connections can reuse a tab number without replacing another call")
    func connectionsHaveSeparateTabs() async throws {
        let fixture = try SensorServerFixture()
        let chrome = fixture.connect()
        let brave = fixture.connect()
        #expect(chrome.send(fixture.event(meetingID: "chrome-call", tabID: 1)))
        try await fixture.waitForMessages(1)
        #expect(brave.send(fixture.event(meetingID: nil, tabID: 1, state: .browsing)))
        try await fixture.waitForMessages(2)
        #expect(fixture.readings.currentMeetingID == "chrome-call")

        #expect(brave.send(.tabClosed(browser: .chrome, tabID: 1)))
        try await fixture.waitForMessages(3)
        #expect(fixture.readings.currentMeetingID == "chrome-call")
    }

    @Test("one Chromium connection saying goodbye leaves the other connected")
    func goodbyePreservesOtherConnections() async throws {
        let fixture = try SensorServerFixture()
        let chrome = fixture.connect()
        let brave = fixture.connect()
        #expect(chrome.send(fixture.event(meetingID: "chrome-call", tabID: 1)))
        #expect(brave.send(fixture.event(meetingID: nil, tabID: 2, state: .browsing)))
        try await fixture.waitForMessages(2)
        #expect(brave.send(.goodbye(browser: .chrome)))
        try await fixture.waitForMessages(3)
        #expect(fixture.readings.currentMeetingID == "chrome-call")
        #expect(fixture.readings.isLoaded)
    }

    // Started from the main actor, as the host's top-level code does. A timer
    // handler that inherited that isolation trapped when it fired.
    @Test("the host's watch timer reconnects from a background queue")
    @MainActor
    func watchTimerReconnects() async throws {
        let fixture = try SensorServerFixture()
        let host = fixture.connect()
        #expect(!host.isConnected)
        let timer = host.startWatching(every: .milliseconds(20))
        defer { timer.cancel() }
        try await fixture.waitForConnections(1)
        #expect(host.isConnected)
    }

    @Test("a dropped connection removes only its own meeting tabs")
    func disconnectRemovesOnlyItsOwnTabs() async throws {
        let fixture = try SensorServerFixture()
        let chrome = fixture.connect()
        let brave = fixture.connect()
        #expect(brave.send(fixture.event(meetingID: "brave-call", tabID: 1)))
        try await fixture.waitForMessages(1)
        #expect(chrome.send(fixture.event(meetingID: "chrome-call", tabID: 2)))
        try await fixture.waitForMessages(2)
        #expect(fixture.readings.currentMeetingID == "chrome-call")
        chrome.disconnect()
        try await fixture.waitForMessages(3)
        #expect(fixture.readings.currentMeetingID == "brave-call")
        #expect(fixture.readings.isLoaded)
        brave.disconnect()
        try await fixture.waitForDisconnect()
        #expect(fixture.readings.currentMeetingID == nil)
    }
}

private final class SensorReadings: @unchecked Sendable {
    private let lock = NSLock()
    private var sensor = BrowserSensorTracker()
    private var count = 0

    var messageCount: Int { lock.withLock { count } }
    var isLoaded: Bool { lock.withLock { sensor.connection.isLoaded } }
    var currentMeetingID: String? { lock.withLock { sensor.currentEvent(at: Double(count))?.meetingID } }

    func receive(_ message: SensorMessage) {
        lock.withLock {
            count += 1
            switch message {
            case .hello: sensor.noteConnected(at: Double(count))
            case .event(let event): sensor.receive(event, at: Double(count))
            case .tabClosed(_, let tabID): sensor.closeTab(tabID)
            case .goodbye: sensor.noteDisconnected(at: Double(count))
            }
        }
    }
}

private final class SensorServerFixture {
    let readings = SensorReadings()
    private let root: URL
    private let server: BrowserSensorServer
    private var clients: [SensorAppConnection] = []

    init() throws {
        root = try TestPaths.makeTemporaryDirectory()
        var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(getpid(), &path, UInt32(path.count))
        try #require(length > 0)
        let executable = try #require(String(bytes: path.prefix(Int(length)), encoding: .utf8))
        let readings = readings
        server = BrowserSensorServer(
            socketURL: root.appendingPathComponent("s"),
            verifier: SensorPeerVerifier(allowedHostPaths: [executable], requiresBrowserParent: false),
            onMessage: { readings.receive($0) }
        )
        try server.start()
    }

    deinit {
        for client in clients { client.disconnect() }
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func connect() -> SensorAppConnection {
        let client = SensorAppConnection(socketPath: root.appendingPathComponent("s").path)
        clients.append(client)
        return client
    }

    func event(
        meetingID: String?, tabID: Int?, state: BrowserMeetingState = .inCall, browser: BrowserKind = .chrome
    ) -> SensorMessage {
        .event(
            BrowserMeetingEvent(
                browser: browser, provider: .googleMeet, state: state,
                timestamp: 1, meetingID: meetingID, tabID: tabID
            ))
    }

    func waitForMessages(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while readings.messageCount < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(readings.messageCount >= count)
    }

    func waitForDisconnect() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while readings.isLoaded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!readings.isLoaded)
    }

    func waitForConnections(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while server.currentStatus.connectionCount != count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(server.currentStatus.connectionCount == count)
    }
}
