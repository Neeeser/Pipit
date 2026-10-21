import Foundation

/// Records diagnostic events to `~/Library/Logs/Pipit/events/`.
///
/// `record` is safe from any thread or actor and never waits on the disk: it
/// stamps the event, appends it to a bounded in-memory queue under a lock, and
/// returns. A serial utility queue writes the lines. It is never called from
/// an audio callback; capture events are recorded from the capture control
/// queue, which is where the manifest is written too.
///
/// Nothing here throws to the caller or stops anything else. A full queue, a
/// failed write, or a disk with too little room drops the event and counts it,
/// and the count is written as `diagnostics.dropped` the next time a write
/// succeeds. A recording is never put at risk for a line of diagnostics.
///
/// What is kept, and for how long, is the contract's: 2 MB a file, 14 days and
/// 10 MB in all, oldest first. Lines are appended without an fsync; the file is
/// synced after the events `Kind.isDurabilityPoint` names and by `flush`.
public final class DiagnosticLog: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var family: EventFile.Family
        /// The size at which an app file continues in the next part, or past
        /// which the native host writes nothing more that day.
        public var maximumFileBytes: Int
        public var retention: DiagnosticRetention
        /// Events held in memory before the writer takes them. Past this,
        /// events are dropped and counted.
        public var queueCapacity: Int
        public var coalescingWindow: TimeInterval
        /// Below this much free space on the volume nothing is written. The
        /// space belongs to the recording.
        public var minimumFreeBytes: Int64

        public init(
            family: EventFile.Family, maximumFileBytes: Int, retention: DiagnosticRetention = DiagnosticRetention(),
            queueCapacity: Int = 1_024, coalescingWindow: TimeInterval = 60,
            minimumFreeBytes: Int64 = 200 * 1_024 * 1_024
        ) {
            self.family = family
            self.maximumFileBytes = maximumFileBytes
            self.retention = retention
            self.queueCapacity = queueCapacity
            self.coalescingWindow = coalescingWindow
            self.minimumFreeBytes = minimumFreeBytes
        }

        public static let app = Configuration(family: .app, maximumFileBytes: 2 * 1_024 * 1_024)
        public static let nativeHost = Configuration(family: .nativeHost, maximumFileBytes: 256 * 1_024)
    }

    /// Records nothing. What a test, a tool, or anything built without a place
    /// for diagnostics is given.
    public static let disabled = DiagnosticLog()

    /// This process's launch identifier, stamped on every event.
    public let launch: DiagnosticLaunchID
    /// Nil for `disabled`.
    public let layout: DiagnosticLayout?

    private let clock: any Clock
    private let capacity: Int
    private let writer: DiagnosticWriter?
    private let queue = DispatchQueue(label: "com.pipit.diagnostics", qos: .utility)

    private let lock = NSLock()
    private var pending: [DiagnosticEvent] = []
    private var drainScheduled = false
    private var unreportedDrops = 0
    private var totalDrops = 0
    private var deadlineScheduled: Date?

    /// `freeSpace` reports the free bytes on the volume holding a path, and is
    /// a parameter so a test can stand in a full disk.
    public init(
        layout: DiagnosticLayout,
        launch: DiagnosticLaunchID = DiagnosticLaunchID(),
        clock: any Clock = SystemClock(),
        configuration: Configuration = .app,
        freeSpace: (@Sendable (URL) -> Int64?)? = nil
    ) {
        self.launch = launch
        self.layout = layout
        self.clock = clock
        self.capacity = max(1, configuration.queueCapacity)
        self.writer = DiagnosticWriter(
            layout: layout, configuration: configuration, clock: clock,
            freeSpace: freeSpace ?? DiagnosticWriter.volumeFreeSpace
        )
    }

    private init() {
        self.launch = DiagnosticLaunchID()
        self.layout = nil
        self.clock = SystemClock()
        self.capacity = 0
        self.writer = nil
    }

    public var isEnabled: Bool { writer != nil }

    /// Events dropped since launch.
    public var droppedCount: Int { lock.withLock { totalDrops } }

    /// Queues an event. Returns at once.
    public func record(
        _ kind: DiagnosticEvent.Kind, session: DiagnosticSessionID? = nil, job: DiagnosticJobID? = nil
    ) {
        guard writer != nil else { return }
        let event = DiagnosticEvent(time: clock.now, launch: launch, session: session, job: job, kind: kind)
        let schedule: Bool = lock.withLock {
            guard pending.count < capacity else {
                unreportedDrops += 1
                totalDrops += 1
                return false
            }
            pending.append(event)
            if drainScheduled { return false }
            drainScheduled = true
            return true
        }
        if schedule { queue.async { [self] in drain() } }
    }

    /// Writes everything queued, closes every merge window, and syncs the file.
    ///
    /// Waits at most `timeout` and reports whether the work finished. Called at
    /// a clean exit, after `app.terminated`. Never from this log's own queue.
    @discardableResult
    public func flush(timeout: TimeInterval = 2) -> Bool {
        guard let writer else { return true }
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            drain()
            reportLost(writer.closeAllWindows())
            writer.sync()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// Deletes the event files, crash summaries and outbox, and the state
    /// files of earlier launches. Keeps `sent.json`, which holds what is
    /// needed to delete a sent report, and this launch's state file.
    ///
    /// Events recorded before the call are deleted with the rest; events
    /// recorded after it start the files again.
    public func clear() async {
        guard let writer else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                drain()
                writer.clear()
                lock.withLock {
                    unreportedDrops = 0
                    deadlineScheduled = nil
                }
                continuation.resume()
            }
        }
    }

    // MARK: - the writer queue

    /// Takes the queue and writes it. Runs on `queue`.
    private func drain() {
        guard let writer else { return }
        let (batch, drops) = lock.withLock {
            let batch = pending
            pending = []
            drainScheduled = false
            let drops = unreportedDrops
            unreportedDrops = 0
            return (batch, drops)
        }
        reportLost(writer.write(batch))
        if drops > 0 {
            let report = DiagnosticEvent(
                time: clock.now, launch: launch, kind: .diagnosticsDropped(count: drops)
            )
            // A report that cannot be written either carries its count to the
            // next attempt. Those events are already in the total.
            if writer.write([report]) > 0 {
                lock.withLock { unreportedDrops += drops }
            }
        }
        scheduleWindowDeadline()
    }

    /// Counts lines a write could not land.
    private func reportLost(_ lost: Int) {
        guard lost > 0 else { return }
        lock.withLock {
            unreportedDrops += lost
            totalDrops += lost
        }
    }

    /// Comes back when the earliest merge window holding repeats closes, so
    /// a burst that simply stops is still written within the window.
    private func scheduleWindowDeadline() {
        guard let writer, let deadline = writer.nextWindowDeadline else { return }
        let shouldSchedule: Bool = lock.withLock {
            if let scheduled = deadlineScheduled, scheduled <= deadline { return false }
            deadlineScheduled = deadline
            return true
        }
        guard shouldSchedule else { return }
        let delay = max(0.05, deadline.timeIntervalSince(clock.now))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let writer = self.writer else { return }
            self.lock.withLock { self.deadlineScheduled = nil }
            self.reportLost(writer.expireWindows())
            self.scheduleWindowDeadline()
        }
    }
}

/// The half of `DiagnosticLog` that touches the disk.
///
/// Confined to the log's serial queue, which is the only reason it may hold
/// mutable state without a lock.
final class DiagnosticWriter: @unchecked Sendable {
    private let layout: DiagnosticLayout
    private let configuration: DiagnosticLog.Configuration
    private let clock: any Clock
    private let freeSpace: @Sendable (URL) -> Int64?
    private let encoder = DiagnosticEventCoding.makeEncoder()
    private var coalescer: DiagnosticCoalescer

    private var current: (file: EventFile, handle: FileHandle, bytes: Int)?
    /// The volume is asked at most once a minute.
    private var spaceCheckedAt: Date?
    private var hasSpace = true

    init(
        layout: DiagnosticLayout, configuration: DiagnosticLog.Configuration, clock: any Clock,
        freeSpace: @escaping @Sendable (URL) -> Int64?
    ) {
        self.layout = layout
        self.configuration = configuration
        self.clock = clock
        self.freeSpace = freeSpace
        self.coalescer = DiagnosticCoalescer(window: configuration.coalescingWindow)
    }

    deinit { try? current?.handle.close() }

    var nextWindowDeadline: Date? { coalescer.nextDeadline }

    /// Writes events through the merge windows. Returns how many events were
    /// lost.
    func write(_ events: [DiagnosticEvent]) -> Int {
        var lost = 0
        for event in events {
            for line in coalescer.admit(event) where !append(line) {
                lost += line.count
            }
        }
        return lost
    }

    func expireWindows() -> Int {
        coalescer.expire(at: clock.now).reduce(0) { lost, line in append(line) ? lost : lost + line.count }
    }

    func closeAllWindows() -> Int {
        coalescer.closeAll().reduce(0) { lost, line in append(line) ? lost : lost + line.count }
    }

    func sync() {
        guard let current else { return }
        try? current.handle.synchronize()
    }

    func clear() {
        closeCurrent()
        coalescer.reset()
        let fileManager = FileManager.default
        for directory in [layout.events, layout.crashes, layout.outbox] {
            try? fileManager.removeItem(at: directory)
        }
        let keep = layout.launchState.lastPathComponent
        let states = (try? fileManager.contentsOfDirectory(atPath: layout.state.path)) ?? []
        for name in states where name != keep {
            try? fileManager.removeItem(at: layout.state.appendingPathComponent(name))
        }
    }

    // MARK: - lines

    private func append(_ event: DiagnosticEvent) -> Bool {
        guard let line = DiagnosticEventCoding.line(event, encoder: encoder), volumeHasSpace() else { return false }
        guard let handle = handle(for: event, adding: line.count) else { return false }
        do {
            try handle.write(contentsOf: line)
        } catch {
            closeCurrent()
            return false
        }
        current?.bytes += line.count
        if event.kind.isDurabilityPoint { try? handle.synchronize() }
        return true
    }

    /// The open file for the event's day, rotated or opened as needed. Nil
    /// when the day's native host file is full or nothing could be opened.
    private func handle(for event: DiagnosticEvent, adding size: Int) -> FileHandle? {
        let day = DiagnosticLayout.day(of: event.time)
        let limit = configuration.maximumFileBytes
        if let current, current.file.day == day {
            if current.bytes == 0 || current.bytes + size <= limit { return current.handle }
            guard configuration.family == .app else { return nil }
            return openFile(EventFile(family: .app, day: day, part: current.file.part + 1))
        }
        closeCurrent()
        // The latest part already on disk for the day, which a relaunch on the
        // same day carries on in.
        let existing = eventFiles().filter { $0.file.family == configuration.family && $0.file.day == day }
        guard let latest = existing.max(by: { $0.file.part < $1.file.part }) else {
            return openFile(EventFile(family: configuration.family, day: day, part: 0))
        }
        if latest.bytes + Int64(size) <= Int64(limit) || latest.bytes == 0 { return openFile(latest.file) }
        guard configuration.family == .app else { return nil }
        return openFile(EventFile(family: .app, day: day, part: latest.file.part + 1))
    }

    private func openFile(_ file: EventFile) -> FileHandle? {
        closeCurrent()
        let url = layout.events.appendingPathComponent(file.name)
        try? FileManager.default.createDirectory(at: layout.events, withIntermediateDirectories: true)
        // Appending, so two native hosts running at once interleave whole
        // lines rather than overwrite each other.
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let bytes = (try? handle.seekToEnd()).map(Int.init) ?? 0
        current = (file, handle, bytes)
        // Pruned whenever a file is opened, which is at the first write of a
        // launch and whenever the total can have grown past the cap.
        prune(active: file)
        return handle
    }

    private func closeCurrent() {
        guard let current else { return }
        try? current.handle.close()
        self.current = nil
    }

    private func prune(active: EventFile) {
        let doomed = configuration.retention.filesToDelete(eventFiles(), now: clock.now, active: active)
        for file in doomed {
            try? FileManager.default.removeItem(at: layout.events.appendingPathComponent(file.name))
        }
    }

    private func eventFiles() -> [DiagnosticRetention.Candidate] {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: layout.events.path)) ?? []
        return names.compactMap { name in
            guard let file = EventFile(name: name) else { return nil }
            let path = layout.events.appendingPathComponent(name).path
            let size = (try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            return DiagnosticRetention.Candidate(file: file, bytes: size)
        }
    }

    // MARK: - free space

    private func volumeHasSpace() -> Bool {
        let now = clock.now
        if let checked = spaceCheckedAt, abs(now.timeIntervalSince(checked)) < 60 { return hasSpace }
        spaceCheckedAt = now
        if let free = freeSpace(layout.root) {
            hasSpace = free >= configuration.minimumFreeBytes
        } else {
            hasSpace = true
        }
        return hasSpace
    }

    /// Free bytes on the volume holding `url`, asked of the nearest folder
    /// that exists. Nil when the volume will not say, which is read as room.
    static let volumeFreeSpace: @Sendable (URL) -> Int64? = { url in
        var probe = url
        let fileManager = FileManager.default
        while !fileManager.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let attributes = try? fileManager.attributesOfFileSystem(forPath: probe.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }
}

extension DiagnosticLayout {
    /// What everything under the root takes on disk.
    public func usedBytes() -> Int64 {
        let fileManager = FileManager.default
        guard let walker = fileManager.enumerator(atPath: root.path) else { return 0 }
        var total: Int64 = 0
        while let relative = walker.nextObject() as? String {
            let path = root.appendingPathComponent(relative).path
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                attributes[.type] as? FileAttributeType == .typeRegular
            else { continue }
            total += (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        return total
    }
}
