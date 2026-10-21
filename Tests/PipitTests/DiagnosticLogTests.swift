import Foundation
import PipitCore
import Testing

/// The recorder's file handling: one file a day, parts at the size limit,
/// 14 days and 10 MB in all, merged repeats, counted drops, and a clear that
/// keeps what it must. None of it may throw into the caller.
@Suite("DiagnosticLog")
struct DiagnosticLogTests {
    /// 2026-10-21T12:00:00Z.
    static let noon = Date(timeIntervalSince1970: 1_792_584_000)

    static func makeLog(
        root: URL, clock: ManualClock, configuration: DiagnosticLog.Configuration = .app,
        freeSpace: (@Sendable (URL) -> Int64?)? = { _ in Int64.max }
    ) -> DiagnosticLog {
        DiagnosticLog(
            layout: DiagnosticLayout(root: root), clock: clock, configuration: configuration, freeSpace: freeSpace
        )
    }

    static func names(in root: URL) -> [String] {
        let events = DiagnosticLayout(root: root).events
        return ((try? FileManager.default.contentsOfDirectory(atPath: events.path)) ?? []).sorted()
    }

    static func events(in root: URL, named name: String) throws -> [DiagnosticEvent] {
        let url = DiagnosticLayout(root: root).events.appendingPathComponent(name)
        return DiagnosticCoding.events(in: try Data(contentsOf: url))
    }

    @Test("events go into the day's file, stamped with the launch")
    func eventsGoIntoTheDaysFile() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        let clock = ManualClock(now: Self.noon)
        let log = Self.makeLog(root: root, clock: clock)
        let session = DiagnosticSessionID()
        log.record(.sessionStarted(source: .manual, trigger: .manual, segmentSeconds: 30), session: session)
        log.record(.captureHealth(track: .mic, state: .healthy), session: session)
        #expect(log.flush())

        #expect(Self.names(in: root) == ["events-2026-10-21.ndjson"])
        let written = try Self.events(in: root, named: "events-2026-10-21.ndjson")
        #expect(written.map(\.kind.name) == ["session.started", "capture.health"])
        #expect(written.allSatisfy { $0.launch == log.launch && $0.session == session })
        #expect(written.first?.time == Self.noon)
    }

    @Test("an event after midnight UTC starts the next day's file")
    func anEventAfterMidnightStartsTheNextDaysFile() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        let clock = ManualClock(now: Self.noon.addingTimeInterval(12 * 3_600 - 1))
        let log = Self.makeLog(root: root, clock: clock)
        log.record(.appTerminated)
        clock.advance(2)
        log.record(.diagnosticsDropped(count: 1))
        #expect(log.flush())
        #expect(Self.names(in: root) == ["events-2026-10-21.ndjson", "events-2026-10-22.ndjson"])
    }

    @Test("identical events within a minute are one line, and the repeats one more carrying n")
    func identicalEventsWithinAMinuteAreMerged() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        let clock = ManualClock(now: Self.noon)
        let log = Self.makeLog(root: root, clock: clock)
        let warning = DiagnosticEvent.Kind.captureHealth(track: .remote, state: .degraded)
        for _ in 0..<5 {
            log.record(warning)
            clock.advance(1)
        }
        log.record(.captureHealth(track: .remote, state: .healthy))
        #expect(log.flush())

        let written = try Self.events(in: root, named: "events-2026-10-21.ndjson")
        #expect(written.map(\.count) == [1, 1, 4])
        #expect(written[0].kind == warning)
        #expect(written[2].kind == warning)
        // The merged line is stamped when the last repeat happened.
        #expect(written[2].time == Self.noon.addingTimeInterval(4))
    }

    @Test("a window that has closed is written when the next event arrives")
    func aClosedWindowIsWrittenWhenTheNextEventArrives() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        let clock = ManualClock(now: Self.noon)
        let log = Self.makeLog(root: root, clock: clock)
        let restart = DiagnosticEvent.Kind.captureRestarted(track: .mic, reason: .watchdog, count: 1)
        log.record(restart)
        log.record(restart)
        log.record(restart)
        #expect(log.flush(timeout: 5))
        clock.advance(61)
        log.record(restart)
        #expect(log.flush())

        let written = try Self.events(in: root, named: "events-2026-10-21.ndjson")
        // The flush closed the first window, so the event after it opens a
        // new one and is written at once.
        #expect(written.map(\.count) == [1, 2, 1])
    }

    @Test("a day's file continues in numbered parts at the size limit")
    func aDaysFileContinuesInNumberedParts() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        let clock = ManualClock(now: Self.noon)
        var configuration = DiagnosticLog.Configuration.app
        configuration.maximumFileBytes = 600
        let log = Self.makeLog(root: root, clock: clock, configuration: configuration)
        for attempt in 1...12 {
            log.record(.processingStageStarted(stage: .transcribing, attempt: attempt), job: DiagnosticJobID())
        }
        #expect(log.flush())

        let names = Self.names(in: root)
        #expect(names.contains("events-2026-10-21.ndjson"))
        #expect(names.contains("events-2026-10-21.1.ndjson"))
        #expect(names.contains("events-2026-10-21.2.ndjson"))
        let events = DiagnosticLayout(root: root).events
        for name in names {
            let size = try FileManager.default.attributesOfItem(atPath: events.appendingPathComponent(name).path)[.size]
            #expect(((size as? NSNumber)?.intValue ?? .max) <= 600)
        }
        // Read in name order, the parts hold the events in the order recorded.
        let ordered = ["events-2026-10-21.ndjson"] + (1..<names.count).map { "events-2026-10-21.\($0).ndjson" }
        let attempts = try ordered.flatMap { try Self.events(in: root, named: $0) }.compactMap { event -> Int? in
            if case .processingStageStarted(_, let attempt) = event.kind { return attempt }
            return nil
        }
        #expect(attempts == Array(1...12))
    }

    @Test("a relaunch on the same day carries on in the day's latest part")
    func aRelaunchCarriesOnInTheLatestPart() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        let clock = ManualClock(now: Self.noon)
        let first = Self.makeLog(root: root, clock: clock)
        first.record(.appTerminated)
        #expect(first.flush())
        let second = Self.makeLog(root: root, clock: clock)
        second.record(
            .appLaunched(
                .init(version: "1", build: "1", commit: nil, os: nil, osBuild: nil, hardware: nil, arch: .other)))
        #expect(second.flush())
        let written = try Self.events(in: root, named: "events-2026-10-21.ndjson")
        #expect(written.map(\.launch) == [first.launch, second.launch])
    }

    @Test("files older than 14 days are deleted, and the 13 days before today are kept")
    func filesOlderThanFourteenDaysAreDeleted() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        let events = DiagnosticLayout(root: root).events
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        for name in [
            "events-2026-10-07.ndjson", "events-2026-10-07.1.ndjson", "events-2026-10-08.ndjson",
            "nativehost-2026-10-01.ndjson", "nativehost-2026-10-20.ndjson", "notes.txt",
        ] {
            try Data("{}\n".utf8).write(to: events.appendingPathComponent(name))
        }
        let log = Self.makeLog(root: root, clock: ManualClock(now: Self.noon))
        log.record(.appTerminated)
        #expect(log.flush())
        #expect(
            Self.names(in: root) == [
                "events-2026-10-08.ndjson", "events-2026-10-21.ndjson", "nativehost-2026-10-20.ndjson", "notes.txt",
            ])
    }

    @Test("past 10 MB the oldest app files go first, never the one being written")
    func pastTheCapTheOldestFilesGoFirst() {
        let policy = DiagnosticRetention()
        let megabyte: Int64 = 1_024 * 1_024
        func file(_ day: String, _ part: Int = 0, _ family: EventFile.Family = .app) -> EventFile {
            EventFile(family: family, day: day, part: part)
        }
        let candidates: [DiagnosticRetention.Candidate] = [
            .init(file: file("2026-10-20", 1), bytes: 2 * megabyte),
            .init(file: file("2026-10-19"), bytes: 3 * megabyte),
            .init(file: file("2026-10-20"), bytes: 2 * megabyte),
            .init(file: file("2026-10-21"), bytes: 2 * megabyte),
            .init(file: file("2026-10-21", 1), bytes: 2 * megabyte),
            .init(file: file("2026-10-18"), bytes: megabyte / 2),
            .init(file: file("2026-10-18", 0, .nativeHost), bytes: 5 * megabyte),
        ]
        let doomed = policy.filesToDelete(candidates, now: Self.noon, active: file("2026-10-21", 1))
        #expect(doomed == [file("2026-10-18"), file("2026-10-19")])

        // The file being written survives even when it alone is over the cap.
        let alone = policy.filesToDelete(
            [.init(file: file("2026-10-21"), bytes: 11 * megabyte)], now: Self.noon, active: file("2026-10-21")
        )
        #expect(alone.isEmpty)
    }

    @Test("the size cap holds while writing")
    func theSizeCapHoldsWhileWriting() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        var configuration = DiagnosticLog.Configuration.app
        configuration.maximumFileBytes = 400
        configuration.retention = DiagnosticRetention(maximumDays: 14, maximumAppBytes: 1_000)
        let log = Self.makeLog(root: root, clock: ManualClock(now: Self.noon), configuration: configuration)
        for count in 1...40 { log.record(.diagnosticsDropped(count: count)) }
        #expect(log.flush())
        #expect(DiagnosticLayout(root: root).usedBytes() <= 1_000 + 400)
        // The newest events are the ones kept.
        let names = Self.names(in: root)
        let last = try #require(names.max { (EventFile(name: $0)?.part ?? 0) < (EventFile(name: $1)?.part ?? 0) })
        #expect(try Self.events(in: root, named: last).last?.kind == .diagnosticsDropped(count: 40))
    }

    @Test("events past a full queue are counted and reported once the writer catches up")
    func eventsPastAFullQueueAreCountedAndReported() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        var configuration = DiagnosticLog.Configuration.app
        configuration.queueCapacity = 3
        // The first question about free space holds the writer, which is the
        // one way to keep it from draining the queue while the test fills it.
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let asked = LockedFlag()
        let log = Self.makeLog(
            root: root, clock: ManualClock(now: Self.noon), configuration: configuration,
            freeSpace: { _ in
                if asked.setOnce() {
                    entered.signal()
                    release.wait()
                }
                return Int64.max
            })
        log.record(.appTerminated)
        entered.wait()
        for count in 1...8 { log.record(.diagnosticsDropped(count: 100 + count)) }
        release.signal()
        #expect(log.flush())

        #expect(log.droppedCount == 5)
        let written = try Self.events(in: root, named: "events-2026-10-21.ndjson")
        #expect(written.contains { $0.kind == .diagnosticsDropped(count: 5) })
        #expect(written.count == 1 + 3 + 1)
    }

    @Test("nothing is written while the disk is nearly full, and the loss is reported after")
    func nothingIsWrittenWhileTheDiskIsNearlyFull() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        let clock = ManualClock(now: Self.noon)
        let free = LockedValue<Int64>(10 * 1_024 * 1_024)
        let log = Self.makeLog(root: root, clock: clock, freeSpace: { _ in free.value })
        log.record(.appTerminated)
        log.record(.captureHealth(track: .mic, state: .failed))
        #expect(log.flush())
        #expect(Self.names(in: root).isEmpty)
        #expect(log.droppedCount == 2)

        free.value = 50 * 1_024 * 1_024 * 1_024
        clock.advance(61)
        log.record(.captureHealth(track: .mic, state: .healthy))
        #expect(log.flush())
        let written = try Self.events(in: root, named: "events-2026-10-21.ndjson")
        #expect(written.map(\.kind) == [.captureHealth(track: .mic, state: .healthy), .diagnosticsDropped(count: 2)])
    }

    @Test("a log whose folder cannot be written counts its losses and never throws")
    func anUnwritableFolderNeverThrows() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        // A file where the folder should be, which fails as root too.
        let blocker = root.appendingPathComponent("blocked")
        try Data("x".utf8).write(to: blocker)
        let log = Self.makeLog(root: blocker.appendingPathComponent("Logs"), clock: ManualClock(now: Self.noon))
        for _ in 0..<3 { log.record(.appTerminated) }
        log.record(.sessionStopped(trigger: .error, seconds: 1, segments: 0))
        #expect(log.flush())
        #expect(log.droppedCount >= 2)
        await log.clear()
    }

    @Test("clearing keeps the sent receipts and this launch's state, and deletes the rest")
    func clearingKeepsReceiptsAndThisLaunchsState() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        let layout = DiagnosticLayout(root: root)
        let clock = ManualClock(now: Self.noon)
        let log = Self.makeLog(root: root, clock: clock)
        log.record(.appTerminated)
        #expect(log.flush())
        let fileManager = FileManager.default
        for directory in [layout.crashes, layout.outbox, layout.state] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: layout.crashes.appendingPathComponent("incident.json"))
        try Data("{}".utf8).write(to: layout.outbox.appendingPathComponent("report.json.gz"))
        try Data("{}".utf8).write(to: layout.launchState)
        try Data("{}".utf8).write(to: layout.state.appendingPathComponent("launch-previous.json"))
        try Data("[]".utf8).write(to: layout.sentReceipts)

        await log.clear()

        #expect(!fileManager.fileExists(atPath: layout.events.path))
        #expect(!fileManager.fileExists(atPath: layout.crashes.path))
        #expect(!fileManager.fileExists(atPath: layout.outbox.path))
        #expect(fileManager.fileExists(atPath: layout.launchState.path))
        #expect(!fileManager.fileExists(atPath: layout.state.appendingPathComponent("launch-previous.json").path))
        #expect(fileManager.fileExists(atPath: layout.sentReceipts.path))

        log.record(.captureHealth(track: .mic, state: .healthy))
        #expect(log.flush())
        #expect(try Self.events(in: root, named: "events-2026-10-21.ndjson").count == 1)
    }

    @Test("the native host stops writing at its daily limit")
    func theNativeHostStopsAtItsDailyLimit() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        var configuration = DiagnosticLog.Configuration.nativeHost
        configuration.maximumFileBytes = 500
        let log = Self.makeLog(root: root, clock: ManualClock(now: Self.noon), configuration: configuration)
        for relayed in 1...20 { log.record(.nativeHostExited(reason: .browserClosed, relayed: relayed)) }
        #expect(log.flush())
        #expect(Self.names(in: root) == ["nativehost-2026-10-21.ndjson"])
        let size = DiagnosticLayout(root: root).usedBytes()
        #expect(size <= 500)
        #expect(log.droppedCount > 0)
    }

    @Test("the disabled log writes nothing")
    func theDisabledLogWritesNothing() {
        DiagnosticLog.disabled.record(.appTerminated)
        #expect(DiagnosticLog.disabled.flush())
        #expect(DiagnosticLog.disabled.layout == nil)
        #expect(!DiagnosticLog.disabled.isEnabled)
    }

    @Test("an events file name is read back, and anything else is ignored")
    func anEventsFileNameIsReadBack() {
        #expect(EventFile(name: "events-2026-10-21.ndjson") == EventFile(family: .app, day: "2026-10-21", part: 0))
        #expect(EventFile(name: "events-2026-10-21.3.ndjson") == EventFile(family: .app, day: "2026-10-21", part: 3))
        #expect(
            EventFile(name: "nativehost-2026-10-21.ndjson")
                == EventFile(family: .nativeHost, day: "2026-10-21", part: 0))
        #expect(EventFile(name: "events-2026-10-21.0.ndjson") == nil)
        #expect(EventFile(name: "events-today.ndjson") == nil)
        #expect(EventFile(name: "safari-extension.ndjson") == nil)
        #expect(EventFile(name: "events-2026-10-21.ndjson.tmp") == nil)
    }
}

/// True the first time it is asked, from any thread.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    func setOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if set { return false }
        set = true
        return true
    }
}

/// A value a closure on another queue reads.
final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
