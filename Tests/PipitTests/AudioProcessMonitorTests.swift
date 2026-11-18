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
    private var restartHandler: (@Sendable () -> Void)?
    private var processHandlers: [AudioObjectID: @Sendable () -> Void] = [:]
    private(set) var reads: [String: Int] = [:]
    /// Set to drop the next running-state notification, as a lost one would.
    var dropsNotifications = false
    /// Objects whose bundle identifier read fails until cleared.
    var failingBundleReads: Set<AudioObjectID> = []

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
        return lock.withLock { failingBundleReads.contains(object) ? nil : processes[object]?.bundleIdentifier }
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
    func addServiceRestartListener(
        queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void
    ) -> CoreAudioListenerToken? {
        lock.withLock { restartHandler = { queue.sync(execute: handler) } }
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

    /// A process joins without the list notification arriving.
    func addSilently(_ object: AudioObjectID, _ process: Process) {
        lock.withLock { processes[object] = process }
    }

    /// The audio server restarts: every object gets a new ID, and the old
    /// per-process listeners are gone.
    func restart(with fresh: [AudioObjectID: Process]) {
        let handler = lock.withLock {
            processes = fresh
            processHandlers = [:]
            return restartHandler
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
        // The first look waits for the start's read of the list.
        _ = monitor.processes(at: 0)
        #expect(server.readCount("pid") == 44)
        #expect(server.readCount("bundle") == 44)
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
        _ = monitor.processes(at: 0)

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

    @Test("a process that joined without a notification is found by the periodic re-read")
    func aSilentJoinIsFoundByTheReRead() {
        let server = Self.idleServer(count: 2)
        let monitor = CoreAudioProcessMonitor(source: server)
        monitor.start {}
        _ = monitor.processes(at: 0)

        server.addSilently(300, .init(processID: 3000, bundleIdentifier: "com.microsoft.teams2", input: true))

        #expect(!monitor.processes(at: 1).contains { $0.objectID == 300 })
        let later = monitor.processes(at: CoreAudioProcessMonitor.reconcileInterval + 1)
        #expect(later.first { $0.objectID == 300 }?.isRunningInput == true)
    }

    @Test("an audio server restart rebuilds the process list and its listeners")
    func anAudioServerRestartRebuildsTheList() {
        let server = Self.idleServer(count: 3)
        let changes = ChangeCounter()
        let monitor = CoreAudioProcessMonitor(source: server)
        monitor.start { changes.increment() }
        _ = monitor.processes(at: 0)

        server.restart(with: [
            500: .init(processID: 1000, bundleIdentifier: "com.example.app0"),
            501: .init(processID: 4000, bundleIdentifier: "us.zoom.xos"),
        ])

        #expect(changes.count == 1)
        #expect(Set(monitor.processes(at: 1).map(\.objectID)) == [500, 501])
        #expect(server.listenerCount == 2)
        // The new objects' listeners work: Zoom opening the microphone is seen.
        server.set(501, input: true)
        #expect(changes.count == 2)
        #expect(monitor.processes(at: 2).first { $0.objectID == 501 }?.isRunningInput == true)
    }

    @Test("a bundle identifier that failed to read is read again")
    func aFailedIdentityReadIsRetried() {
        let server = Self.idleServer(count: 2)
        server.failingBundleReads = [101]
        let monitor = CoreAudioProcessMonitor(source: server)
        monitor.start {}
        #expect(monitor.processes(at: 0).first { $0.objectID == 101 }?.bundleIdentifier == "")

        server.failingBundleReads = []
        server.resetCounts()
        let later = monitor.processes(at: CoreAudioProcessMonitor.reconcileInterval + 1)

        #expect(later.first { $0.objectID == 101 }?.bundleIdentifier == "com.example.app1")
        #expect(server.readCount("bundle") == 1, "only the one that failed")
    }

    @Test("a process that starts audio with an unread bundle identifier is identified at once")
    func aRunningProcessWithAFailedIdentityIsIdentifiedAtOnce() {
        let server = Self.idleServer(count: 2)
        server.failingBundleReads = [100]
        let monitor = CoreAudioProcessMonitor(source: server)
        monitor.start {}
        _ = monitor.processes(at: 0)
        server.failingBundleReads = []

        server.set(100, input: true)

        // Well before the next re-read.
        let states = monitor.processes(at: 1)
        #expect(states.first { $0.objectID == 100 }?.bundleIdentifier == "com.example.app0")
        #expect(states.first { $0.objectID == 100 }?.isRunningInput == true)
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

    @Test("the timer stays fast while any application plays audio, and slows when none does")
    func theTimerStaysFastWhileAudioPlays() {
        let configuration = DetectionEngine.Configuration()
        #expect(configuration.idlePollInterval > configuration.pollInterval)
        let music = Self.audio(bundle: "com.apple.Music", microphone: false, output: true)
        let silent = Self.audio(bundle: "com.apple.Finder", microphone: false)

        #expect(
            DetectionPollSchedule.tickInterval(quiet: true, audio: [silent], configuration: configuration)
                == configuration.idlePollInterval)
        // A process already playing can open the microphone on the same device
        // without Core Audio saying so, so it is looked at on every fast tick.
        #expect(
            DetectionPollSchedule.tickInterval(quiet: true, audio: [music], configuration: configuration)
                == configuration.pollInterval)
        #expect(
            DetectionPollSchedule.tickInterval(quiet: false, audio: [], configuration: configuration)
                == configuration.pollInterval)
    }

    @Test("an event while idle polls at once with the short leeway, then the idle cadence returns")
    func anEventWhileIdlePollsAtOnce() {
        let configuration = DetectionEngine.Configuration()
        var schedule = DetectionPollSchedule(configuration: configuration)
        let none: [ApplicationAudioState] = []

        let step1 = schedule.beginTick(at: 0, audio: none)
        #expect(step1)
        let slowed = schedule.pollFinished(quiet: true, audio: none)
        #expect(slowed?.interval == configuration.idlePollInterval)
        #expect(slowed?.leewayMilliseconds == 250)

        let soon = schedule.eventArrived(at: 5)
        #expect(soon == .init(delay: 0, interval: configuration.idlePollInterval, leewayMilliseconds: 50))
        let step2 = schedule.eventArrived(at: 5.01)
        #expect(step2 == nil, "a second event joins the poll already on its way")

        let step3 = schedule.beginTick(at: 5.02, audio: none)
        #expect(step3, "the requested tick polls in full")
        let back = schedule.pollFinished(quiet: true, audio: none)
        #expect(back?.interval == configuration.idlePollInterval, "the one-off deadline gives way to the cadence")
        #expect(back?.leewayMilliseconds == 250)
        let step4 = schedule.pollFinished(quiet: true, audio: none)
        #expect(step4 == nil, "and stays there")
    }

    @Test("an event right after a full poll waits out the active interval")
    func anEventRightAfterAPollWaits() {
        let configuration = DetectionEngine.Configuration()
        var schedule = DetectionPollSchedule(configuration: configuration)
        _ = schedule.beginTick(at: 10, audio: [])
        _ = schedule.pollFinished(quiet: true, audio: [])
        let soon = schedule.eventArrived(at: 10.1)
        #expect(abs((soon?.delay ?? 0) - (configuration.pollInterval - 0.1)) < 1e-9)
    }

    @Test("while a ringtone plays, ticks read only audio until the call is answered")
    func ticksReadOnlyAudioUntilTheCallIsAnswered() {
        let configuration = DetectionEngine.Configuration()
        var schedule = DetectionPollSchedule(configuration: configuration)
        let ringing = [Self.audio(bundle: "us.zoom.xos", microphone: false, output: true)]
        let answered = [Self.audio(bundle: "us.zoom.xos", microphone: true, output: true)]

        let step5 = schedule.beginTick(at: 0, audio: ringing)
        #expect(step5)
        let step6 = schedule.pollFinished(quiet: true, audio: ringing)
        #expect(step6 == nil, "the timer stays fast")
        let step7 = schedule.beginTick(at: 0.5, audio: ringing)
        #expect(!step7, "an audio-only tick")
        let step8 = schedule.beginTick(at: 1.0, audio: answered)
        #expect(step8, "the microphone opened: a full poll")
        let fast = schedule.pollFinished(quiet: false, audio: answered)
        #expect(fast == nil, "already fast")
        #expect(!schedule.isQuiet)
        let step9 = schedule.eventArrived(at: 1.1)
        #expect(step9 == nil, "events change nothing while polls are fast")
    }

    @Test("a burst of audio events cannot poll faster than the active poll did")
    func aBurstOfAudioEventsCannotPollFaster() {
        let configuration = DetectionEngine.Configuration()
        func wait(_ since: Double?) -> Double {
            DetectionPollSchedule.delayBeforeRequestedPoll(sinceLastFullPoll: since, configuration: configuration)
        }
        #expect(wait(nil) == 0, "nothing polled yet")
        #expect(wait(configuration.idlePollInterval) == 0, "the last full poll was long ago")
        #expect(abs(wait(0.1) - (configuration.pollInterval - 0.1)) < 1e-9, "a poll just ran")
        #expect(wait(0) == configuration.pollInterval)
    }

    @Test("a quiet tick reads only audio until the idle interval passes or the microphone opens")
    func aQuietTickReadsOnlyAudio() {
        let configuration = DetectionEngine.Configuration()
        let music = Self.audio(bundle: "us.zoom.xos", microphone: false, output: true)
        let answered = Self.audio(bundle: "us.zoom.xos", microphone: true, output: true)
        func full(quiet: Bool = true, requested: Bool = false, _ audio: [ApplicationAudioState], since: Double?)
            -> Bool
        {
            DetectionPollSchedule.needsFullPoll(
                quiet: quiet, requested: requested, audio: audio, sinceLastFullPoll: since,
                configuration: configuration
            )
        }

        #expect(!full([music], since: 0.5), "a ringtone playing, between full polls")
        #expect(full([answered], since: 0.5), "the call is answered on the same device")
        #expect(full([music], since: configuration.idlePollInterval), "the idle interval passed")
        #expect(full(requested: true, [music], since: 0.5), "an event asked for a poll")
        #expect(full(quiet: false, [music], since: 0.5), "something may be a meeting")
        #expect(full([music], since: nil), "the first tick after start")
    }
}
