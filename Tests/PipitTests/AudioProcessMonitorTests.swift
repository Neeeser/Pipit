import CoreAudio
import Foundation
import PipitAudio
import PipitCore
import Testing

@testable import PipitDetection

/// A stand-in audio server that counts every read, so the tests can see what
/// a detection poll costs coreaudiod.
private final class FakeAudioServer: CoreAudioProcessSource, @unchecked Sendable {
    struct Process {
        var processID: pid_t
        var bundleIdentifier: String
        var input = false
        var output = false
        var isRunning: Bool { input || output }
    }

    private let lock = NSLock()
    private var processes: [AudioObjectID: Process] = [:]
    private var listHandler: (@Sendable () -> Void)?
    private var processHandlers: [AudioObjectID: @Sendable () -> Void] = [:]
    private(set) var reads: [String: Int] = [:]
    /// Set to drop the next running-state notification, as a lost one would.
    var dropsNotifications = false

    init(_ processes: [AudioObjectID: Process]) { self.processes = processes }

    private func count(_ name: String) { lock.withLock { reads[name, default: 0] += 1 } }
    func readCount(_ name: String) -> Int { lock.withLock { reads[name, default: 0] } }
    func resetCounts() { lock.withLock { reads = [:] } }
    var listenerCount: Int { lock.withLock { processHandlers.count } }

    func processObjectIDs() -> [AudioObjectID] {
        count("list")
        return lock.withLock { Array(processes.keys) }
    }
    func processID(_ object: AudioObjectID) -> pid_t? {
        count("pid")
        return lock.withLock { processes[object]?.processID }
    }
    func bundleIdentifier(_ object: AudioObjectID) -> String? {
        count("bundle")
        return lock.withLock { processes[object]?.bundleIdentifier }
    }
    func isRunning(_ object: AudioObjectID) -> Bool {
        count("running")
        return lock.withLock { processes[object]?.isRunning ?? false }
    }
    func isRunningInput(_ object: AudioObjectID) -> Bool {
        count("input")
        return lock.withLock { processes[object]?.input ?? false }
    }
    func isRunningOutput(_ object: AudioObjectID) -> Bool {
        count("output")
        return lock.withLock { processes[object]?.output ?? false }
    }

    func addProcessListListener(
        queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void
    ) -> CoreAudioListenerToken? {
        lock.withLock { listHandler = { queue.sync(execute: handler) } }
        return token(AudioObjectID(kAudioObjectSystemObject))
    }
    func addProcessListener(
        _ object: AudioObjectID, queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void
    ) -> CoreAudioListenerToken? {
        lock.withLock { processHandlers[object] = { queue.sync(execute: handler) } }
        return token(object)
    }
    func removeListener(_ token: CoreAudioListenerToken) {
        lock.withLock { _ = processHandlers.removeValue(forKey: token.object) }
    }
    private func token(_ object: AudioObjectID) -> CoreAudioListenerToken {
        CoreAudioListenerToken(object: object, selectors: [], queue: .main, block: { _, _ in })
    }

    /// Changes a process's audio the way Core Audio does: the running flag
    /// notifies, the input and output flags on their own do not.
    func set(_ object: AudioObjectID, input: Bool? = nil, output: Bool? = nil) {
        let (wasRunning, isRunning, handler) = lock.withLock {
            let wasRunning = processes[object]?.isRunning ?? false
            if let input { processes[object]?.input = input }
            if let output { processes[object]?.output = output }
            return (wasRunning, processes[object]?.isRunning ?? false, processHandlers[object])
        }
        if wasRunning != isRunning, !dropsNotifications { handler?() }
    }

    func add(_ object: AudioObjectID, _ process: Process) {
        let handler = lock.withLock {
            processes[object] = process
            return listHandler
        }
        handler?()
    }

    func remove(_ object: AudioObjectID) {
        let handler = lock.withLock {
            processes[object] = nil
            return listHandler
        }
        handler?()
    }
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

struct AudioProcessMonitorTests {
    private static func idleServer(count: Int) -> FakeAudioServer {
        var processes: [AudioObjectID: FakeAudioServer.Process] = [:]
        for index in 0..<count {
            processes[AudioObjectID(100 + index)] = .init(
                processID: pid_t(1000 + index), bundleIdentifier: "com.example.app\(index)")
        }
        return FakeAudioServer(processes)
    }

    @Test("a poll with nothing playing reads no process from the audio server")
    func aPollWithNothingPlayingReadsNoProcess() {
        let server = Self.idleServer(count: 44)
        let monitor = CoreAudioProcessMonitor(source: server)
        monitor.start {}
        _ = monitor.processes(at: 0)
        server.resetCounts()

        for tick in 1...10 { _ = monitor.processes(at: Double(tick) * 0.5) }

        // The old poll read five properties of every object: 2,200 reads here.
        #expect(server.reads.values.reduce(0, +) == 0)
        #expect(server.listenerCount == 44)
    }

    @Test("identity is read once per process, and only running processes are read each poll")
    func identityIsReadOnceAndOnlyRunningProcessesAreRead() {
        let server = Self.idleServer(count: 44)
        server.set(100, output: true)
        let monitor = CoreAudioProcessMonitor(source: server)
        monitor.start {}
        #expect(server.readCount("pid") == 44)
        #expect(server.readCount("bundle") == 44)
        _ = monitor.processes(at: 0)
        server.resetCounts()

        let states = monitor.processes(at: 1)

        #expect(server.readCount("pid") == 0)
        #expect(server.readCount("bundle") == 0)
        #expect(server.readCount("input") == 1)
        #expect(server.readCount("output") == 1)
        #expect(states.first { $0.objectID == 100 }?.isRunningOutput == true)
        #expect(states.first { $0.objectID == 100 }?.processID == 1000)
    }

    @Test("an application opening the microphone is seen and reported at once")
    func anApplicationOpeningTheMicrophoneIsSeenAndReported() {
        let server = Self.idleServer(count: 3)
        let changes = ChangeCounter()
        let monitor = CoreAudioProcessMonitor(source: server)
        monitor.start { changes.increment() }
        #expect(monitor.processes(at: 0).allSatisfy { !$0.isRunningInput })

        server.set(101, input: true)

        #expect(changes.count == 1)
        #expect(monitor.processes(at: 1).first { $0.objectID == 101 }?.isRunningInput == true)
    }

    @Test("a process already playing that opens the microphone is seen without a notification")
    func aProcessAlreadyPlayingThatOpensTheMicrophoneIsSeen() {
        let server = Self.idleServer(count: 3)
        server.set(102, output: true)
        let monitor = CoreAudioProcessMonitor(source: server)
        monitor.start {}
        _ = monitor.processes(at: 0)

        // Running already, so the running flag does not change and Core
        // Audio says nothing.
        server.set(102, input: true)

        #expect(monitor.processes(at: 0.5).first { $0.objectID == 102 }?.isRunningInput == true)
    }

    @Test("processes joining and leaving the list are picked up and their listeners removed")
    func processesJoiningAndLeavingAreTracked() {
        let server = Self.idleServer(count: 2)
        let changes = ChangeCounter()
        let monitor = CoreAudioProcessMonitor(source: server)
        monitor.start { changes.increment() }

        server.add(200, .init(processID: 2000, bundleIdentifier: "us.zoom.xos", input: true))
        let afterJoin = monitor.processes(at: 0)
        #expect(afterJoin.first { $0.objectID == 200 }?.bundleIdentifier == "us.zoom.xos")
        #expect(afterJoin.first { $0.objectID == 200 }?.isRunningInput == true)

        server.remove(200)
        #expect(!monitor.processes(at: 1).contains { $0.objectID == 200 })
        #expect(server.listenerCount == 2)
        #expect(changes.count == 2)
    }

    @Test("a lost notification is corrected by the periodic re-read")
    func aLostNotificationIsCorrected() {
        let server = Self.idleServer(count: 3)
        let monitor = CoreAudioProcessMonitor(source: server)
        monitor.start {}
        _ = monitor.processes(at: 0)
        server.dropsNotifications = true
        server.set(100, input: true)

        #expect(monitor.processes(at: 1).first { $0.objectID == 100 }?.isRunningInput == false)
        let later = monitor.processes(at: CoreAudioProcessMonitor.reconcileInterval + 1)
        #expect(later.first { $0.objectID == 100 }?.isRunningInput == true)
    }

    @Test("stopping removes every listener")
    func stoppingRemovesEveryListener() {
        let server = Self.idleServer(count: 5)
        let monitor = CoreAudioProcessMonitor(source: server)
        monitor.start {}
        monitor.stop()
        #expect(server.listenerCount == 0)
        #expect(monitor.processes(at: 0).isEmpty)
    }
}

struct DetectionCadenceTests {
    private static func audio(bundle: String, microphone: Bool, output: Bool = false) -> ApplicationAudioState {
        ApplicationAudioState(
            bundleIdentifier: bundle, processID: 1, holdsMicrophone: microphone, producesOutput: output,
            isFrontmost: false, windowTitle: nil
        )
    }

    @Test("detection slows down only when nothing could be a meeting")
    func detectionSlowsDownOnlyWhenNothingCouldBeAMeeting() {
        let music = Self.audio(bundle: "com.apple.Music", microphone: false, output: true)
        #expect(DetectionEngine.isQuiet(audio: [music], evidence: [], slackState: .idle))

        let zoom = Self.audio(bundle: "us.zoom.xos", microphone: true)
        #expect(!DetectionEngine.isQuiet(audio: [music, zoom], evidence: [], slackState: .idle))

        let candidate = ProviderEvidence(provider: .googleMeet, confidence: .candidate, source: .browserSensor)
        #expect(!DetectionEngine.isQuiet(audio: [], evidence: [candidate], slackState: .idle))

        #expect(!DetectionEngine.isQuiet(audio: [], evidence: [], slackState: .candidate))
    }

    @Test("the idle poll is slower than the active one")
    func theIdlePollIsSlowerThanTheActiveOne() {
        let configuration = DetectionEngine.Configuration()
        #expect(configuration.idlePollInterval > configuration.pollInterval)
    }
}
