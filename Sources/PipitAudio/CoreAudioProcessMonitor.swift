import CoreAudio
import Foundation

/// The Core Audio reads and listeners the process monitor needs, so tests can
/// stand in for the audio server. Every call here is a read or a listener;
/// none writes a property.
public protocol CoreAudioProcessSource: Sendable {
    func processObjectIDs() -> [AudioObjectID]
    func processID(_ object: AudioObjectID) -> pid_t?
    func bundleIdentifier(_ object: AudioObjectID) -> String?
    func isRunning(_ object: AudioObjectID) -> Bool
    func isRunningInput(_ object: AudioObjectID) -> Bool
    func isRunningOutput(_ object: AudioObjectID) -> Bool
    /// Calls `handler` on `queue` when the process list changes. Returns a
    /// token for `removeListener`, or nil when the listener was refused.
    func addProcessListListener(
        queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void
    ) -> CoreAudioListenerToken?
    /// Calls `handler` on `queue` when the audio server restarts, after which
    /// every object ID and listener from before is gone.
    func addServiceRestartListener(
        queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void
    ) -> CoreAudioListenerToken?
    /// Calls `handler` on `queue` when the process starts or stops any audio,
    /// or changes the devices it uses.
    func addProcessListener(
        _ object: AudioObjectID, queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void
    ) -> CoreAudioListenerToken?
    func removeListener(_ token: CoreAudioListenerToken)
}

/// A registered listener, kept so it can be removed with the same block.
public struct CoreAudioListenerToken: @unchecked Sendable {
    public let object: AudioObjectID
    let selectors: [AudioObjectPropertySelector]
    let queue: DispatchQueue
    let block: AudioObjectPropertyListenerBlock

    public init(
        object: AudioObjectID, selectors: [AudioObjectPropertySelector], queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        self.object = object
        self.selectors = selectors
        self.queue = queue
        self.block = block
    }
}

/// Which processes are using audio, kept current by Core Audio notifications
/// rather than re-read in full on every detection poll.
///
/// Reading every process object every poll cost five calls into coreaudiod
/// per object: on a Mac with 44 objects and a half-second poll, 440 calls a
/// second, which kept coreaudiod near 13% CPU with no meeting running. Here a
/// process's PID and bundle identifier are read once, since they never change
/// for an object, and its running state arrives as a notification.
///
/// Core Audio (measured on macOS 27.2) notifies a change to a process's
/// overall running flag and its device list, but not to its input or output
/// flags. So the input and output flags are read only for processes that are
/// running audio at all, which is usually a handful. A process already
/// playing audio that opens the microphone on the same device raises no
/// notification, and is caught because running processes are read on every
/// poll.
///
/// The process list itself is read again with the running flags, and from
/// scratch when the audio server restarts, so a lost list notification or a
/// restarted coreaudiod costs at most one re-read interval rather than every
/// process until Pipit relaunches.
public final class CoreAudioProcessMonitor: @unchecked Sendable {
    private struct Entry {
        var processID: pid_t
        var bundleIdentifier: String
        var isRunning: Bool
        var token: CoreAudioListenerToken?
    }

    private let source: any CoreAudioProcessSource
    /// Listener callbacks arrive here, one at a time.
    private let queue = DispatchQueue(label: "com.pipit.audio-processes", qos: .userInitiated)
    private let lock = NSLock()
    private var entries: [AudioObjectID: Entry] = [:]
    private var listToken: CoreAudioListenerToken?
    private var restartToken: CoreAudioListenerToken?
    private var onChange: (@Sendable () -> Void)?
    private var started = false
    private var lastReconcile: Double?
    /// How often every process's running flag is read again, in case a
    /// notification was lost. Thirty seconds of one read per object is a
    /// small fraction of what one poll used to cost.
    public static let reconcileInterval: Double = 30

    public init(source: any CoreAudioProcessSource = SystemCoreAudioProcessSource()) {
        self.source = source
    }

    deinit { stop() }

    /// Reads the process list and starts listening. `onChange` runs on the
    /// monitor's own queue whenever a process starts or stops audio, joins or
    /// leaves the list, or changes devices.
    public func start(onChange: @escaping @Sendable () -> Void) {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        self.onChange = onChange
        lock.unlock()
        let restart = source.addServiceRestartListener(queue: queue) { [weak self] in
            self?.rebuild()
            self?.notify()
        }
        lock.withLock { restartToken = restart }
        queue.sync {
            listenToList()
            refreshList()
        }
    }

    /// Registers the process-list listener if it is not registered. Runs on the
    /// monitor's queue, so a refused registration is tried again on the next
    /// re-read.
    private func listenToList() {
        guard lock.withLock({ started && listToken == nil }) else { return }
        let token = source.addProcessListListener(queue: queue) { [weak self] in
            self?.refreshList()
            self?.notify()
        }
        let kept = lock.withLock { () -> Bool in
            guard started else { return false }
            listToken = token
            return true
        }
        if !kept, let token { source.removeListener(token) }
    }

    /// Starts over after the audio server restarted: the old object IDs and
    /// listeners belong to a server that is gone. Runs on the monitor's queue.
    private func rebuild() {
        let stale = lock.withLock { () -> [CoreAudioListenerToken] in
            let tokens = [listToken].compactMap { $0 } + entries.values.compactMap(\.token)
            listToken = nil
            entries = [:]
            lastReconcile = nil
            return tokens
        }
        for token in stale { source.removeListener(token) }
        listenToList()
        refreshList()
    }

    public func stop() {
        let tokens = lock.withLock { () -> [CoreAudioListenerToken] in
            let tokens = [listToken, restartToken].compactMap { $0 } + entries.values.compactMap(\.token)
            listToken = nil
            restartToken = nil
            entries = [:]
            onChange = nil
            started = false
            return tokens
        }
        for token in tokens { source.removeListener(token) }
    }

    /// Every process Core Audio knows about. Input and output are read live
    /// for the processes running audio, and are false for the rest.
    public func processes(at now: Double) -> [AudioProcessInfo] {
        let needsReconcile = lock.withLock { () -> Bool in
            let due = lastReconcile.map { now - $0 >= Self.reconcileInterval } ?? true
            if due { lastReconcile = now }
            return due
        }
        if needsReconcile {
            // One read of the list and of every running flag, for a
            // notification that never came. On the monitor's queue, where the
            // listeners write too, so a notification cannot land between a
            // read here and its write and be overwritten by the older value.
            queue.sync {
                listenToList()
                refreshList()
                for objectID in lock.withLock({ Array(entries.keys) }) { refreshRunning(objectID) }
            }
        }
        let snapshot = lock.withLock { entries }

        return snapshot.map { objectID, entry in
            let isRunning = entry.isRunning
            return AudioProcessInfo(
                objectID: objectID,
                processID: entry.processID,
                bundleIdentifier: entry.bundleIdentifier,
                isRunning: isRunning,
                isRunningInput: isRunning && source.isRunningInput(objectID),
                isRunningOutput: isRunning && source.isRunningOutput(objectID)
            )
        }
        .sorted { $0.objectID < $1.objectID }
    }

    /// Adds listeners for new objects and drops the ones that left. Runs on
    /// the monitor's queue.
    private func refreshList() {
        let current = Set(source.processObjectIDs())
        let known = lock.withLock { Set(entries.keys) }
        var removed: [CoreAudioListenerToken] = []
        lock.withLock {
            for objectID in known.subtracting(current) {
                if let token = entries.removeValue(forKey: objectID)?.token { removed.append(token) }
            }
        }
        for token in removed { source.removeListener(token) }

        for objectID in current.subtracting(known) {
            let token = source.addProcessListener(objectID, queue: queue) { [weak self] in
                self?.refreshRunning(objectID)
                self?.notify()
            }
            let entry = Entry(
                processID: source.processID(objectID) ?? -1,
                bundleIdentifier: source.bundleIdentifier(objectID) ?? "",
                isRunning: source.isRunning(objectID),
                token: token
            )
            let stillWanted = lock.withLock { () -> Bool in
                guard started else { return false }
                entries[objectID] = entry
                return true
            }
            if !stillWanted, let token { source.removeListener(token) }
        }
    }

    private func refreshRunning(_ objectID: AudioObjectID) {
        let isRunning = source.isRunning(objectID)
        lock.withLock { entries[objectID]?.isRunning = isRunning }
    }

    private func notify() {
        let handler = lock.withLock { onChange }
        handler?()
    }
}

/// The real audio server.
public struct SystemCoreAudioProcessSource: CoreAudioProcessSource {
    public init() {}

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    public func processObjectIDs() -> [AudioObjectID] {
        CoreAudioSystem.objectIDs(Self.system, CoreAudioSystem.address(kAudioHardwarePropertyProcessObjectList))
    }

    public func processID(_ object: AudioObjectID) -> pid_t? { CoreAudioSystem.processID(object) }

    public func bundleIdentifier(_ object: AudioObjectID) -> String? {
        CoreAudioSystem.string(object, CoreAudioSystem.address(kAudioProcessPropertyBundleID))
    }

    public func isRunning(_ object: AudioObjectID) -> Bool { flag(object, kAudioProcessPropertyIsRunning) }
    public func isRunningInput(_ object: AudioObjectID) -> Bool { flag(object, kAudioProcessPropertyIsRunningInput) }
    public func isRunningOutput(_ object: AudioObjectID) -> Bool {
        flag(object, kAudioProcessPropertyIsRunningOutput)
    }

    private func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        (CoreAudioSystem.uint32(object, CoreAudioSystem.address(selector)) ?? 0) != 0
    }

    public func addProcessListListener(
        queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void
    ) -> CoreAudioListenerToken? {
        add(Self.system, selectors: [kAudioHardwarePropertyProcessObjectList], queue: queue, handler)
    }

    public func addServiceRestartListener(
        queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void
    ) -> CoreAudioListenerToken? {
        add(Self.system, selectors: [kAudioHardwarePropertyServiceRestarted], queue: queue, handler)
    }

    public func addProcessListener(
        _ object: AudioObjectID, queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void
    ) -> CoreAudioListenerToken? {
        add(object, selectors: [kAudioProcessPropertyIsRunning, kAudioProcessPropertyDevices], queue: queue, handler)
    }

    private func add(
        _ object: AudioObjectID, selectors: [AudioObjectPropertySelector], queue: DispatchQueue,
        _ handler: @escaping @Sendable () -> Void
    ) -> CoreAudioListenerToken? {
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        var added: [AudioObjectPropertySelector] = []
        for selector in selectors {
            var address = CoreAudioSystem.address(selector)
            if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr { added.append(selector) }
        }
        guard !added.isEmpty else { return nil }
        return CoreAudioListenerToken(object: object, selectors: added, queue: queue, block: block)
    }

    public func removeListener(_ token: CoreAudioListenerToken) {
        for selector in token.selectors {
            var address = CoreAudioSystem.address(selector)
            AudioObjectRemovePropertyListenerBlock(token.object, &address, token.queue, token.block)
        }
    }
}
