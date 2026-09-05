import AVFoundation
import Foundation
import PipitAudio
import PipitCore
import PipitDetection
import PipitServices
import Testing

// Regressions for defects found by adversarial review. Each one failed against
// the code as it was.

// MARK: - fakes that emit audio

private final class EmittingMicrophone: MicrophoneEngineController, @unchecked Sendable {
    private let lock = NSLock()
    private var sinkHandler: AudioBufferSink?
    var format = AudioFormatDescriptor(sampleRate: 48_000, channelCount: 1)
    /// Reported by every build, as `MicrophoneSource` reports a device the
    /// input unit refused to open. A build that carries one still succeeds.
    var deviceSelectionStatus: Int32?

    init(sink: @escaping AudioBufferSink) { self.sinkHandler = sink }

    func currentInputFormat() -> AudioFormatDescriptor? { format }
    func currentInputDeviceUID() -> String? { "emitting" }
    func currentInputDevice() -> MicrophoneDeviceDescription? {
        MicrophoneDeviceDescription(
            uid: "emitting", name: "Emitting input",
            sampleRate: format.sampleRate, channelCount: format.channelCount
        )
    }
    func teardown() {}
    @discardableResult
    func buildAndStart(preferred: AudioFormatDescriptor) throws -> MicrophoneBuild {
        MicrophoneBuild(format: format, deviceSelectionStatus: deviceSelectionStatus)
    }
    var isRunning: Bool { true }

    func emit(seconds: Double, hostTime: Double) {
        lock.lock()
        let handler = sinkHandler
        lock.unlock()
        let buffer = AudioFixtures.makeTone(seconds: seconds, sampleRate: format.sampleRate)
        handler?(AudioBufferPacket(buffer: buffer, hostTime: hostTime))
    }
}

private final class EmittingTap: ProcessTapController, @unchecked Sendable {
    private let lock = NSLock()
    private var sinkHandler: AudioBufferSink?
    private var targets: [RemoteAudioTarget] = []
    private var reading: TapCallbackReading?
    var format = AudioFormatDescriptor(sampleRate: 48_000, channelCount: 1)
    private(set) var bindCount = 0

    init(sink: @escaping AudioBufferSink) { self.sinkHandler = sink }

    func setTargets(_ targets: [RemoteAudioTarget]) {
        lock.lock()
        self.targets = targets
        lock.unlock()
    }

    func resolveTargets(bundlePrefixes: [String]) -> [RemoteAudioTarget] {
        lock.lock()
        defer { lock.unlock() }
        return targets.filter { target in
            bundlePrefixes.contains { target.bundleIdentifier.hasPrefix($0) }
        }
    }

    func teardown() {}

    func bind(to targets: [RemoteAudioTarget]) throws -> RemoteTapBinding {
        lock.lock()
        bindCount += 1
        reading = nil
        lock.unlock()
        return RemoteTapBinding(format: format, streamCount: 2, tapStreamIndex: 1)
    }

    func firstCallback() -> TapCallbackReading? {
        lock.lock()
        defer { lock.unlock() }
        return reading
    }

    /// `amplitude: 0` is the digital zero a tap reads when it is pointed at
    /// the wrong stream of the aggregate device. `toneChannel` leaves every
    /// other channel at zero, which is a far end sitting on one side of the
    /// tap's stereo mixdown.
    func emit(
        seconds: Double, hostTime: Double, amplitude: Float = 0.5, toneChannel: Int? = nil
    ) {
        let buffer = AudioFixtures.makeTone(
            seconds: seconds, sampleRate: format.sampleRate,
            channels: AVAudioChannelCount(format.channelCount),
            amplitude: amplitude, toneChannel: toneChannel
        )
        lock.lock()
        let handler = sinkHandler
        if reading == nil {
            // One interleaved stream, which is the tap's own buffer in an
            // aggregate device's list.
            reading = TapCallbackReading(
                streams: [.init(
                    channelCount: format.channelCount,
                    byteCount: Int(buffer.frameLength) * format.channelCount
                        * MemoryLayout<Float>.size
                )],
                usedFallback: false
            )
        }
        lock.unlock()
        handler?(AudioBufferPacket(buffer: buffer, hostTime: hostTime))
    }
}

private final class SilentDelegate: CaptureEngineDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var snapshots: [CaptureHealthSnapshot] = []
    private(set) var warnings: [CaptureWarning] = []

    func captureEngineDidUpdateHealth(_ snapshot: CaptureHealthSnapshot) {
        lock.lock()
        snapshots.append(snapshot)
        lock.unlock()
    }

    func captureEngineDidRaiseWarning(_ warning: CaptureWarning) {
        lock.lock()
        warnings.append(warning)
        lock.unlock()
    }
}

@Suite("CaptureEngineHardening")
struct CaptureEngineHardeningTests {
    /// Records half a second of tap audio at one amplitude and returns what the
    /// engine told its delegate.
    ///
    /// The thresholds are wall clock, because the engine polls on a real timer
    /// rather than an injected one, so they are scaled down to keep the test
    /// under a second.
    ///
    /// `channels` and `toneChannel` shape the buffer the peak is read from. A
    /// real tap is always stereo and deinterleaved, so two channels with the
    /// tone on one of them is the production shape.
    private static func recordTapAudio(
        amplitude: Float, channels: Int = 1, toneChannel: Int? = nil
    ) async throws -> (delegate: SilentDelegate, lines: [ManifestLine]) {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MeetingLayout(root: root)
        try FileManager.default.createDirectory(at: layout.segments, withIntermediateDirectories: true)

        let tap = LockedBox<EmittingTap?>(nil)
        let delegate = SilentDelegate()
        let engine = CaptureEngine(
            thresholds: CaptureThresholds(remoteSilenceTimeout: 0.1, pollInterval: 0.02),
            segmentSeconds: 60,
            makeMicrophone: { sink, _ in EmittingMicrophone(sink: sink) },
            makeTap: { sink, _ in
                let source = EmittingTap(sink: sink)
                tap.withLock { $0 = source }
                return source
            },
            delegate: delegate
        )
        tap.withLock {
            $0?.format = AudioFormatDescriptor(sampleRate: 48_000, channelCount: channels)
        }
        await engine.arm(bundlePrefixes: ["com.example.app"], capturesRemote: true)
        try await engine.commit(layout: layout, meetingID: "m", source: .googleMeet)
        tap.withLock {
            $0?.setTargets([makeTarget(pid: 42, bundle: "com.example.app", producing: true)])
        }

        // Real host times, because the poll measures the callback gap against
        // the same mach clock the audio stack stamps buffers with.
        for _ in 0..<25 {
            tap.withLock {
                $0?.emit(
                    seconds: 0.02, hostTime: HostTime.now, amplitude: amplitude,
                    toneChannel: toneChannel
                )
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        _ = await engine.stop(reason: "test")
        return (delegate, try ManifestReader.read(contentsOf: layout.manifest).lines)
    }

    @Test("a microphone whose device could not be set still records")
    func aMicrophoneWhoseDeviceCouldNotBeSetStillRecords() async throws {
        // Pointing the input unit at the default input device can fail.
        // `kAudioUnitErr_Initialized` is reachable wherever
        // AVAudioEngine has already initialised the unit by the time it
        // hands it over. Treating that as a build failure would leave
        // the meeting with no microphone track at all, retried on
        // backoff until it ended. The build keeps the device the unit
        // holds, and the manifest carries the status so the record does
        // not claim a device the audio is not from.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MeetingLayout(root: root)
        try FileManager.default.createDirectory(at: layout.segments, withIntermediateDirectories: true)

        let microphone = LockedBox<EmittingMicrophone?>(nil)
        let engine = CaptureEngine(
            segmentSeconds: 60,
            makeMicrophone: { sink, _ in
                let source = EmittingMicrophone(sink: sink)
                microphone.withLock { $0 = source }
                return source
            },
            makeTap: { sink, _ in EmittingTap(sink: sink) },
            delegate: SilentDelegate()
        )
        // 'init', which is `kAudioUnitErr_Initialized`.
        microphone.withLock { $0?.deviceSelectionStatus = 1_768_843_636 }

        await engine.arm(bundlePrefixes: [], capturesRemote: false)
        try await engine.commit(layout: layout, meetingID: "m", source: .googleMeet)
        microphone.withLock { $0?.emit(seconds: 1, hostTime: 100) }
        _ = await engine.stop(reason: "test")

        let timeline = try ManifestReader.timeline(contentsOf: layout.manifest)
        #expect(
            timeline.duration(track: .mic) > 0.5,
            "a device that could not be set must not cost the meeting its microphone"
        )

        let lines = try ManifestReader.read(contentsOf: layout.manifest).lines
        let binds = lines.compactMap { line -> ManifestEvent.MicBind? in
            guard case .micBind(let bind) = line.event else { return nil }
            return bind
        }
        #expect(binds.count == 1)
        #expect(
            binds.first?.deviceSelectionStatus == 1_768_843_636,
            "the manifest says the device named here was not the one opened"
        )
    }

    @Test("remote audio that starts after commit is still written")
    func remoteAudioThatStartsAfterCommitIsStillWritten() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MeetingLayout(root: root)
        try FileManager.default.createDirectory(at: layout.segments, withIntermediateDirectories: true)

        let microphone = LockedBox<EmittingMicrophone?>(nil)
        let tap = LockedBox<EmittingTap?>(nil)
        let engine = CaptureEngine(
            segmentSeconds: 60,
            makeMicrophone: { sink, _ in
                let source = EmittingMicrophone(sink: sink)
                microphone.withLock { $0 = source }
                return source
            },
            makeTap: { sink, _ in
                let source = EmittingTap(sink: sink)
                tap.withLock { $0 = source }
                return source
            },
            delegate: SilentDelegate()
        )

        // The provider's audio process does not exist yet, which is the
        // normal state the instant a huddle or a call is joined.
        await engine.arm(bundlePrefixes: ["com.example.app"], capturesRemote: true)
        try await engine.commit(layout: layout, meetingID: "m", source: .googleMeet)

        // It appears a moment later and starts producing audio.
        tap.withLock { $0?.setTargets([makeTarget(pid: 42, bundle: "com.example.app")]) }
        tap.withLock { $0?.emit(seconds: 1, hostTime: 100) }
        microphone.withLock { $0?.emit(seconds: 1, hostTime: 100) }
        _ = await engine.stop(reason: "test")

        let timeline = try ManifestReader.timeline(contentsOf: layout.manifest)
        #expect(
            timeline.duration(track: .remote) > 0.5,
            "remote audio arriving after commit was dropped"
        )
        #expect(timeline.duration(track: .mic) > 0.5)
    }

    @Test("a remote writer that cannot open its file does not hang capture")
    func aRemoteWriterThatCannotOpenItsFileDoesNotHangCapture() async throws {
        // Storage disappearing mid-meeting, an unmounted volume or a full
        // disk: the writer's open fails and reports it, and that report
        // needs the engine's own lock. Building the writer while holding
        // that lock deadlocked the audio thread and froze the recording.
        let root = try TestPaths.makeTemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("segments").path
            )
            try? FileManager.default.removeItem(at: root)
        }
        let layout = MeetingLayout(root: root)
        try FileManager.default.createDirectory(at: layout.segments, withIntermediateDirectories: true)

        let microphone = LockedBox<EmittingMicrophone?>(nil)
        let tap = LockedBox<EmittingTap?>(nil)
        let delegate = SilentDelegate()
        let engine = CaptureEngine(
            segmentSeconds: 60,
            makeMicrophone: { sink, _ in
                let source = EmittingMicrophone(sink: sink)
                microphone.withLock { $0 = source }
                return source
            },
            makeTap: { sink, _ in
                let source = EmittingTap(sink: sink)
                tap.withLock { $0 = source }
                return source
            },
            delegate: delegate
        )
        await engine.arm(bundlePrefixes: ["com.example.app"], capturesRemote: true)
        try await engine.commit(layout: layout, meetingID: "m", source: .googleMeet)

        // Nothing can be created in the segments directory any more.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: layout.segments.path
        )
        tap.withLock { $0?.setTargets([makeTarget(pid: 42, bundle: "com.example.app")]) }
        tap.withLock { $0?.emit(seconds: 1, hostTime: 100) }
        microphone.withLock { $0?.emit(seconds: 1, hostTime: 101) }

        // Reaching here at all is the assertion: a deadlock would never
        // return. Stopping must still work.
        let snapshot = await engine.stop(reason: "test")
        #expect(snapshot.remoteSeconds == 0, "nothing could be written")
        #expect(
            delegate.warnings.contains { $0.dedupKey.contains("segment") },
            "the user is told the recording could not be written: \(delegate.warnings)"
        )
    }

    @Test("a tap handing over digital zero is reported to the user")
    func aTapHandingOverDigitalZeroIsReportedToTheUser() async throws {
        // The engine is the only thing that reads buffer content. A
        // coordinator test can hand the policy any peak it likes, so
        // this is where a peak read from the wrong pointers, or not read
        // at all, shows up.
        let (delegate, lines) = try await Self.recordTapAudio(amplitude: 0)

        #expect(
            delegate.warnings.contains { $0.dedupKey == "remote_silent_while_producing" },
            "the user is told the far side may be missing: \(delegate.warnings)"
        )
        #expect(
            delegate.snapshots.contains { $0.remote.isLosingAudio },
            "a track of digital zero must not read as nominal in the menu bar"
        )
        // And the folder says what was read, not only that it was
        // silent. `remote_bind` carries the index the bind chose; this
        // is the line that says the choice held and what the aggregate
        // handed over.
        let streams = lines.compactMap { line -> ManifestEvent.RemoteStream? in
            guard case .remoteStream(let payload) = line.event else { return nil }
            return payload
        }
        #expect(streams.count >= 1, "the manifest records what the tap's first callback read")
        #expect(streams.first?.streams.count == 1)
        #expect(streams.first?.usedFallback == false)
    }

    @Test("audio the tap really carries raises nothing")
    func audioTheTapReallyCarriesRaisesNothing() async throws {
        let (delegate, _) = try await Self.recordTapAudio(amplitude: 0.5)

        #expect(
            !(delegate.warnings.contains { $0.dedupKey == "remote_silent_while_producing" }),
            "a tap carrying the meeting must not be called silent: \(delegate.warnings)"
        )
    }

    @Test("a far end on one channel of a stereo tap raises nothing")
    func aFarEndOnOneChannelOfAStereoTapRaisesNothing() async throws {
        // The production shape. A tap's format is always
        // `standardFormatWithSampleRate:channels:2`, so every real
        // remote buffer is deinterleaved with two channel pointers, and
        // a peak read from the first pointer alone calls a far end that
        // sits on the second one digital zero. That reads as silence
        // for as long as the far end stays there, rebinding the tap and
        // warning the user through a meeting that is being recorded
        // correctly.
        let (delegate, _) = try await Self.recordTapAudio(
            amplitude: 0.5, channels: 2, toneChannel: 1
        )

        #expect(
            !(delegate.warnings.contains { $0.dedupKey == "remote_silent_while_producing" }),
            "audio on the second channel is still audio: \(delegate.warnings)"
        )
    }

    @Test("the pre-roll reaches disk before the audio that follows it")
    func thePreRollReachesDiskBeforeTheAudioThatFollowsIt() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MeetingLayout(root: root)
        try FileManager.default.createDirectory(at: layout.segments, withIntermediateDirectories: true)

        let microphone = LockedBox<EmittingMicrophone?>(nil)
        let engine = CaptureEngine(
            segmentSeconds: 60,
            makeMicrophone: { sink, _ in
                let source = EmittingMicrophone(sink: sink)
                microphone.withLock { $0 = source }
                return source
            },
            makeTap: { sink, _ in EmittingTap(sink: sink) },
            delegate: SilentDelegate()
        )

        await engine.arm(bundlePrefixes: [], capturesRemote: false)
        // Three seconds of candidate audio, held only in memory.
        for index in 0..<3 {
            microphone.withLock { $0?.emit(seconds: 1, hostTime: Double(index)) }
        }
        try await engine.commit(layout: layout, meetingID: "m", source: .googleMeet)
        microphone.withLock { $0?.emit(seconds: 1, hostTime: 3) }
        _ = await engine.stop(reason: "test")

        let timeline = try ManifestReader.timeline(contentsOf: layout.manifest)
        #expect(
            abs(timeline.duration(track: .mic) - 4.0) <= 0.2,
            "expected \(4.0) ± \(0.2), got \(timeline.duration(track: .mic)) — the ring should be written along with the live audio"
        )
        #expect(timeline.preRollFlushes.count == 1)
        #expect(
            abs(timeline.preRollFlushes[0].seconds - 3.0) <= 0.1,
            "expected \(3.0) ± \(0.1), got \(timeline.preRollFlushes[0].seconds)"
        )
    }

    @Test("a mic-only recording is not judged by the remote source")
    func aMicOnlyRecordingIsNotJudgedByTheRemoteSource() async throws {
        var snapshot = CaptureHealthSnapshot(
            mic: .healthy, remote: .failed, capturesRemote: false
        )
        #expect(snapshot.overall == .healthy, "in-person capture has no remote track")

        snapshot = CaptureHealthSnapshot(mic: .healthy, remote: .failed, capturesRemote: true)
        #expect(snapshot.overall == .failed, "a failed required source is never healthy")

        snapshot = CaptureHealthSnapshot(mic: .healthy, remote: .idleButBound)
        #expect(snapshot.overall == .healthy, "a quiet meeting app is normal")

        snapshot = CaptureHealthSnapshot(mic: .recovering, remote: .healthy)
        #expect(snapshot.overall == .recovering)

        snapshot = CaptureHealthSnapshot(mic: .degraded, remote: .healthy)
        #expect(snapshot.overall == .degraded)
    }

    @Test("a segment that cannot be opened is retried, not abandoned")
    func aSegmentThatCannotBeOpenedIsRetriedNotAbandoned() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MeetingLayout(root: root)
        try FileManager.default.createDirectory(at: layout.segments, withIntermediateDirectories: true)
        let manifest = try ManifestWriter(url: layout.manifest)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

        // The segments directory disappears, so the first open fails.
        try FileManager.default.removeItem(at: layout.segments)
        let clock = ManualClock()
        let writer = SegmentWriter(
            track: .mic, layout: layout, manifest: manifest, format: format,
            segmentSeconds: 60, clock: clock
        )
        writer.enqueueSynchronously(AudioBufferPacket(
            buffer: AudioFixtures.makeTone(seconds: 1, sampleRate: 48_000), hostTime: 0
        ))
        #expect(writer.stats.writeFailures > 0, "the failure should be recorded")

        // The volume comes back; the next buffer after the retry delay must
        // land on disk.
        try FileManager.default.createDirectory(at: layout.segments, withIntermediateDirectories: true)
        clock.advance(2)
        writer.enqueueSynchronously(AudioBufferPacket(
            buffer: AudioFixtures.makeTone(seconds: 1, sampleRate: 48_000), hostTime: 1
        ))
        writer.finish(reason: "test")
        manifest.close()

        #expect(
            abs(writer.stats.totalSeconds - 1.0) <= 0.05,
            "expected \(1.0) ± \(0.05), got \(writer.stats.totalSeconds) — recording should resume once the directory exists again"
        )
    }

    @Test("the reconnect window is not part of the recording")
    func theReconnectWindowIsNotPartOfTheRecording() async throws {
        // Leaving a meeting used to keep writing through the 90-second
        // reconnect window, so every recording carried a tail of the
        // user's desk audio. A pause closes the segments; a resume after
        // a rejoin opens new ones and flushes the ring, so the moments
        // before the rejoin was confirmed still land on disk.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MeetingLayout(root: root)
        try FileManager.default.createDirectory(at: layout.segments, withIntermediateDirectories: true)

        let microphone = LockedBox<EmittingMicrophone?>(nil)
        let engine = CaptureEngine(
            segmentSeconds: 60,
            makeMicrophone: { sink, _ in
                let source = EmittingMicrophone(sink: sink)
                microphone.withLock { $0 = source }
                return source
            },
            makeTap: { sink, _ in EmittingTap(sink: sink) },
            delegate: SilentDelegate()
        )
        await engine.arm(bundlePrefixes: [], capturesRemote: false)
        try await engine.commit(layout: layout, meetingID: "m", source: .googleMeet)
        microphone.withLock { $0?.emit(seconds: 2, hostTime: 100) }

        await engine.pause(reason: "provider_evidence_gone")
        // Audio arriving during the window goes to the ring, not to disk.
        microphone.withLock { $0?.emit(seconds: 5, hostTime: 110) }

        await engine.resume()
        microphone.withLock { $0?.emit(seconds: 1, hostTime: 120) }
        _ = await engine.stop(reason: "test")

        let timeline = try ManifestReader.timeline(contentsOf: layout.manifest)
        #expect(
            timeline.segments(track: .mic).count >= 2,
            "the pause should close one segment and the resume open another"
        )
        #expect(
            timeline.markers.contains { $0.label.hasPrefix("pause:") },
            "the manifest should record where the window began"
        )
        // 2 s before the pause, 5 s recovered from the ring, 1 s after.
        #expect(
            abs(timeline.duration(track: .mic) - 8) <= 0.1,
            "expected \(8) ± \(0.1), got \(timeline.duration(track: .mic))"
        )
        #expect(timeline.isComplete)
    }
}

@Suite("DetectionHardening")
struct DetectionHardeningTests {
    @Test("consecutive uninformative reads never end a live huddle")
    func consecutiveUninformativeReadsNeverEndALiveHuddle() async throws {
        var detector = SlackHuddleDetector()
        var now = 100.0
        _ = detector.update(
            observation: DetectionFixtures.joined(), helperHoldsMicrophone: true,
            helperProducingOutput: true, at: now
        )
        #expect(detector.state == .joined)

        // Twelve consecutive empty reads, well past both the miss count and
        // the grace period, while Slack is plainly still in the huddle.
        for index in 0..<12 {
            now += 0.4
            let event = detector.update(
                observation: .empty, helperHoldsMicrophone: true,
                helperProducingOutput: true, at: now
            )
            if case .left(let reason) = event {
                Issue.record("ended on empty read \(index) with reason \(reason)")
                return
            }
            #expect(detector.state != .idle)
        }

        // The control comes back and the huddle is unaffected.
        now += 0.4
        _ = detector.update(
            observation: DetectionFixtures.joined(), helperHoldsMicrophone: true,
            helperProducingOutput: true, at: now
        )
        #expect(detector.state == .joined)
        #expect(detector.consecutiveMisses == 0)
    }

    @Test("a huddle is still detected without accessibility")
    func aHuddleIsStillDetectedWithoutAccessibility() async throws {
        var detector = SlackHuddleDetector()
        var now = 100.0
        var joined = false
        for _ in 0..<120 {
            now += 0.5
            let event = detector.update(
                observation: .unavailable, helperHoldsMicrophone: true,
                helperProducingOutput: true, at: now
            )
            if event == .joinedWithoutAccessibility { joined = true; break }
        }
        #expect(joined, "audio evidence alone should eventually confirm a huddle")
        #expect(detector.state == .joined)

        // It ends when the audio does, since there is no control to watch.
        var ended = false
        for _ in 0..<20 {
            now += 0.5
            if case .left = detector.update(
                observation: .unavailable, helperHoldsMicrophone: false,
                helperProducingOutput: false, at: now
            ) { ended = true; break }
        }
        #expect(ended)
    }

    @Test("a stale sensor event cannot demote a live call")
    func aStaleSensorEventCannotDemoteALiveCall() async throws {
        var tracker = BrowserSensorTracker()
        tracker.noteConnected(at: 100)
        tracker.receive(
            BrowserMeetingEvent(
                browser: .firefox, provider: .googleMeet, state: .inCall,
                timestamp: 1_000, tabID: 1
            ),
            at: 100
        )
        // An event observed earlier but delivered later.
        tracker.receive(
            BrowserMeetingEvent(
                browser: .firefox, provider: .googleMeet, state: .prejoin,
                timestamp: 990, tabID: 1
            ),
            at: 101
        )
        #expect(tracker.currentEvent(at: 101)?.state == .inCall)
    }

    @Test("a second tab does not overwrite the tab that is in a call")
    func aSecondTabDoesNotOverwriteTheTabThatIsInACall() async throws {
        var tracker = BrowserSensorTracker()
        tracker.noteConnected(at: 100)
        tracker.receive(
            BrowserMeetingEvent(
                browser: .firefox, provider: .googleMeet, state: .inCall,
                timestamp: 1_000, tabID: 1
            ),
            at: 100
        )
        tracker.receive(
            BrowserMeetingEvent(
                browser: .firefox, provider: .zoom, state: .browsing,
                timestamp: 1_001, tabID: 2
            ),
            at: 101
        )
        let current = tracker.currentEvent(at: 101)
        #expect(current?.state == .inCall)
        #expect(current?.tabID == 1)

        // Closing the browsing tab leaves the call alone.
        tracker.closeTab(2)
        #expect(tracker.currentEvent(at: 101)?.state == .inCall)
    }

    @Test("a sensor reporting browsing cannot cancel a confirmed native meeting")
    func aSensorReportingBrowsingCannotCancelAConfirmedNativeMeeting() async throws {
        var detector = BrowserMeetingDetector()
        var now = 100.0
        let native = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Meet - abc-defg-hij"]
        )
        _ = detector.update(native: native, at: now)
        now += 25
        #expect(detector.update(native: native, at: now).confidence == .confirmed)

        // The extension's selector stops matching the leave control, so it
        // reports browsing while the meeting is plainly still running.
        detector.sensorConnected(at: now)
        detector.receive(
            BrowserMeetingEvent(
                browser: .firefox, provider: .googleMeet, state: .browsing, timestamp: now
            ),
            at: now
        )
        let evidence = detector.update(native: native, at: now)
        #expect(
            evidence.confidence == .confirmed,
            "a DOM regression must cost precision, not the meeting"
        )
    }

    @Test("a stale window title stops producing evidence")
    func aStaleWindowTitleStopsProducingEvidence() async throws {
        var detector = BrowserMeetingDetector()
        var now = 100.0
        let withMeeting = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Meet - abc-defg-hij"]
        )
        _ = detector.update(native: withMeeting, at: now)
        now += 25
        #expect(detector.update(native: withMeeting, at: now).confidence == .confirmed)

        // The meeting tab is closed but the browser keeps using the
        // microphone for something else.
        let noTitles = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true, windowTitles: []
        )
        now += 200
        #expect(
            detector.update(native: noTitles, at: now).confidence == .none,
            "a title seen minutes ago is not evidence of a meeting now"
        )
    }

    @Test("an unsupported call keeps producing evidence for as long as it runs")
    func anUnsupportedCallKeepsProducingEvidenceForAsLongAsItRuns() async throws {
        var detector = GenericCallDetector()
        var now = 100.0
        let states = [
            ApplicationAudioState(
                bundleIdentifier: "com.example.videochat", processID: 4_242,
                holdsMicrophone: true, producesOutput: true,
                isFrontmost: true, windowTitle: "Team call"
            ),
        ]
        for _ in 0..<20 {
            now += 0.5
            _ = detector.update(states: states, at: now)
        }
        #expect(detector.currentEvidence().count == 1)

        // Half an hour later it is still reporting, so the session never
        // runs out of evidence and stops the recording.
        for _ in 0..<3_600 {
            now += 0.5
            _ = detector.update(states: states, at: now)
        }
        let evidence = try #require(detector.currentEvidence().first)
        #expect(evidence.confidence == .confirmed)
        #expect(evidence.audioBundlePrefixes == ["com.example.videochat"])

        // A single missed poll is not the end of the call.
        now += 0.5
        #expect(detector.update(states: [], at: now) == [])
        #expect(detector.currentEvidence().count == 1)

        now += 10
        let ended = detector.update(states: [], at: now)
        #expect(ended.contains(.callEnded(bundleIdentifier: "com.example.videochat")))
        #expect(detector.currentEvidence().count == 0)
    }
}

@Suite("SessionHardening")
struct SessionHardeningTests {
    @Test("a ban saved against a helper is read back as its application")
    func aBanSavedAgainstAHelperIsReadBackAsItsApplication() async throws {
        // Bans written before the identifier was normalised are on disk
        // as whichever helper the prompt named, and covered only their
        // own descendants.
        let json = Data(
            #"{"neverRecordApplications":["com.hnc.Discord.helper.Renderer"]}"#.utf8
        )
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(settings.neverRecordApplications == ["com.hnc.Discord"])
    }

    @Test("one application banned under three helpers is one entry")
    func oneApplicationBannedUnderThreeHelpersIsOneEntry() async throws {
        // Which is how the bug that prompted this arrived: the prompt came
        // back twice and was answered each time, naming a different helper
        // each time. Settings lists the application once.
        let json = Data(
            #"""
            {"neverRecordApplications":[
                "com.hnc.Discord.helper",
                "com.hnc.Discord.helper.Renderer",
                "com.hnc.Discord.helper.GPU",
                "com.example.videochat"
            ]}
            """#.utf8
        )
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(
            settings.neverRecordApplications == ["com.hnc.Discord", "com.example.videochat"],
            "collapsed to the application, in the order they were banned"
        )
    }

    @Test("an always-record entry saved against a helper still preapproves")
    func anAlwaysRecordEntrySavedAgainstAHelperStillPreapproves() async throws {
        // What is saved and what the detector looks up have to name the
        // same thing. Resolving the process to its application on one
        // side only leaves a saved entry matching nothing at all, which
        // is silent: the application simply waits out the dwell again.
        let json = Data(
            #"{"alwaysRecordApplications":["com.openai.chat.helper.Renderer"]}"#.utf8
        )
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        var detector = GenericCallDetector(
            configuration: settings.genericDetectorConfiguration
        )
        let events = detector.update(
            states: [
                ApplicationAudioState(
                    bundleIdentifier: "com.openai.chat.helper.GPU", processID: 1,
                    holdsMicrophone: true, producesOutput: false,
                    isFrontmost: true, windowTitle: nil
                ),
            ],
            at: 100
        )
        guard case .callLikely(let candidate) = events.first else {
            Issue.record("expected an immediate candidate, got \(events)")
            return
        }
        #expect(candidate.isPreapproved)
    }

    @Test("banning an application from the prompt records the application")
    func banningAnApplicationFromThePromptRecordsTheApplication() async throws {
        // The prompt names the process CoreAudio reported, which for an
        // Electron application is a helper. Stored verbatim, the ban was
        // one entry per helper and covered none of the others.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        await MainActor.run {
            let runtime = PipitRuntime(settingsDirectory: root)
            runtime.neverRecord(applicationBundleID: "com.openai.chat.helper.Renderer")
            #expect(runtime.settings.neverRecordApplications == ["com.openai.chat"])
            runtime.neverRecord(applicationBundleID: "com.openai.chat.helper.GPU")
            #expect(
                runtime.settings.neverRecordApplications == ["com.openai.chat"],
                "the same application twice is one ban"
            )

            // The other list is written the same way, and the two of them
            // hold the same kind of name, so a choice reverses cleanly.
            runtime.alwaysRecord(applicationBundleID: "com.openai.chat.helper")
            #expect(runtime.settings.alwaysRecordApplications == ["com.openai.chat"])
            #expect(runtime.settings.neverRecordApplications == [])
        }
    }

    @Test("a settings file without the meeting waits gets the current ones")
    func aSettingsFileWithoutTheMeetingWaitsGetsTheCurrentOnes() async throws {
        // Every installation predates the two keys, and the point of
        // adding them was that the waits they replace were too long.
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(settings.meetingEndGraceSeconds == 4)
        #expect(settings.meetingReconnectWindowSeconds == 30)
        let configuration = settings.sessionConfiguration
        #expect(configuration.endGraceSeconds == 4)
        #expect(configuration.reconnectWindowSeconds == 30)
    }

    @Test("hand-edited meeting waits are clamped to the supported range")
    func handEditedMeetingWaitsAreClampedToTheSupportedRange() async throws {
        // The pickers cannot produce these. A hand-edited file can, and a
        // zero-second wait ends a meeting on one dropped poll.
        let json = Data(
            #"{"meetingEndGraceSeconds":0,"meetingReconnectWindowSeconds":86400}"#.utf8
        )
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        let configuration = settings.sessionConfiguration
        #expect(configuration.endGraceSeconds == SessionController.Configuration.endGraceRange.lowerBound)
        #expect(configuration.reconnectWindowSeconds == SessionController.Configuration.reconnectWindowRange.upperBound)
    }

    @Test("a provider set to never record does not suppress another one")
    func aProviderSetToNeverRecordDoesNotSuppressAnotherOne() async throws {
        var policies = ProviderPolicies()
        policies.zoom = ProviderPolicy(autoStart: .never, autoStop: true)
        var controller = SessionController(policies: policies)
        let wall = Date(timeIntervalSince1970: 1_787_070_000)

        let zoom = ProviderEvidence(
            provider: .zoom, confidence: .confirmed, source: .browserSensor,
            meetingID: "81771591841", audioBundlePrefixes: ["org.mozilla.firefox"]
        )
        let meet = DetectionFixtures.meetEvidence(confidence: .confirmed)
        let actions = controller.update(
            evidence: [zoom, meet], now: 100, wallClock: wall
        )
        #expect(controller.snapshot.provider == .googleMeet)
        #expect(actions.contains { if case .commitRecording = $0 { true } else { false } })
    }

    @Test("a different meeting replaces the current one instead of merging")
    func aDifferentMeetingReplacesTheCurrentOneInsteadOfMerging() async throws {
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        _ = controller.update(
            evidence: [DetectionFixtures.meetEvidence(confidence: .confirmed)],
            now: 100, wallClock: wall
        )
        #expect(controller.snapshot.providerMeetingID == "abc-defg-hij")

        let actions = controller.update(
            evidence: [DetectionFixtures.meetEvidence(confidence: .confirmed, meetingID: "zzz-zzzz-zzz")],
            now: 101, wallClock: wall
        )
        #expect(
            actions.contains { if case .finishRecording = $0 { true } else { false } },
            "the first meeting must be finished, not extended"
        )
        #expect(actions.contains { if case .commitRecording = $0 { true } else { false } })
        #expect(controller.snapshot.providerMeetingID == "zzz-zzzz-zzz")
    }

    @Test("weaker evidence sustains a recording rather than ending it")
    func weakerEvidenceSustainsARecordingRatherThanEndingIt() async throws {
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        _ = controller.update(
            evidence: [DetectionFixtures.meetEvidence(confidence: .confirmed)],
            now: 100, wallClock: wall
        )
        var now = 100.0
        for _ in 0..<400 {
            now += 0.5
            let actions = controller.update(
                evidence: [DetectionFixtures.meetEvidence(confidence: .candidate)],
                now: now, wallClock: wall
            )
            #expect(
                !(actions.contains { if case .finishRecording = $0 { true } else { false } }),
                "candidate-level evidence still means the meeting is there"
            )
        }
        #expect(controller.snapshot.state == .recording)
    }

    @Test("a candidate survives a brief gap in evidence")
    func aCandidateSurvivesABriefGapInEvidence() async throws {
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        _ = controller.update(
            evidence: [DetectionFixtures.meetEvidence(confidence: .candidate)],
            now: 100, wallClock: wall
        )
        // A CoreAudio process-list flap: evidence vanishes for two polls.
        for offset in [100.5, 101.0] {
            let actions = controller.update(evidence: [], now: offset, wallClock: wall)
            #expect(actions == [], "one flap must not discard the pre-roll")
        }
        #expect(controller.snapshot.state == .candidate)

        let resumed = controller.update(
            evidence: [DetectionFixtures.meetEvidence(confidence: .confirmed)],
            now: 101.5, wallClock: wall
        )
        #expect(resumed.contains { if case .commitRecording = $0 { true } else { false } })
    }

    @Test("pausing detection finishes a live recording instead of freezing it")
    func pausingDetectionFinishesALiveRecordingInsteadOfFreezingIt() async throws {
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        _ = controller.update(
            evidence: [DetectionFixtures.meetEvidence(confidence: .confirmed)],
            now: 100, wallClock: wall
        )
        #expect(controller.snapshot.state == .recording)

        controller.policies.detectionPaused = true
        let actions = controller.update(evidence: [], now: 101, wallClock: wall)
        #expect(
            actions.contains { if case .finishRecording = $0 { true } else { false } },
            "a paused session must be finalised, not left writing segments forever"
        )
        #expect(controller.snapshot.state == .idle)
    }
}

@Suite("SensorTrust")
struct SensorTrustTests {
    @Test("an add-on in a Firefox profile is found without it saying anything")
    func anAddOnInAFirefoxProfileIsFoundWithoutItSayingAnything() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("abc123.default-release/extensions")
        try FileManager.default.createDirectory(
            at: profile, withIntermediateDirectories: true
        )

        #expect(
            !FirefoxProfile.hasInstalledAddOn(profilesDirectory: root),
            "an empty profile holds no add-on"
        )

        try Data().write(to: profile.appendingPathComponent("sensor@pipit.app.xpi"))
        #expect(
            FirefoxProfile.hasInstalledAddOn(profilesDirectory: root),
            "the file Firefox writes on install is the whole answer"
        )
        #expect(
            !FirefoxProfile.hasInstalledAddOn(
            profilesDirectory: root.appendingPathComponent("missing")
            ),
            "no Firefox on this Mac reads as no add-on"
        )
    }

    @Test("only Pipit's own relay, launched by a browser, is accepted")
    func onlyPipitSOwnRelayLaunchedByABrowserIsAccepted() async throws {
        let verifier = SensorPeerVerifier(
            allowedHostPaths: ["/Users/x/Library/Application Support/Pipit/pipit-nativehost"],
            allowedParentBundleIDs: ["org.mozilla.firefox"]
        )

        let genuine = SensorPeerVerifier.Peer(
            processID: 100,
            executablePath: "/Users/x/Library/Application Support/Pipit/pipit-nativehost",
            parentPath: "/Applications/Firefox.app/Contents/MacOS/firefox",
            parentBundleIdentifier: "org.mozilla.firefox"
        )
        #expect(verifier.isTrusted(genuine))

        // Pipit holds the microphone grant, so a process that can fake a
        // meeting event records without a prompt of its own.
        let imposter = SensorPeerVerifier.Peer(
            processID: 101, executablePath: "/tmp/attacker",
            parentPath: "/bin/zsh", parentBundleIdentifier: nil
        )
        #expect(!verifier.isTrusted(imposter))
        #expect(verifier.rejectionReason(imposter).contains("relay"))

        // Our own relay run from a shell is still refused: it relays
        // whatever it is fed on standard input.
        let shellLaunched = SensorPeerVerifier.Peer(
            processID: 102,
            executablePath: "/Users/x/Library/Application Support/Pipit/pipit-nativehost",
            parentPath: "/bin/zsh", parentBundleIdentifier: nil
        )
        #expect(!verifier.isTrusted(shellLaunched))
        #expect(verifier.rejectionReason(shellLaunched).contains("browser"))
    }

    @Test("a neighbour of the browser bundle is not the browser")
    func aNeighbourOfTheBrowserBundleIsNotTheBrowser() async throws {
        // The parent check compares against the browser's own bundle. An
        // earlier version compared against the containing folder, which
        // accepted any application installed alongside it.
        let verifier = SensorPeerVerifier(
            allowedHostPaths: ["/host/pipit-nativehost"],
            allowedParentBundleIDs: ["org.mozilla.firefox"],
            applicationURL: { _ in URL(fileURLWithPath: "/Applications/Firefox.app") }
        )
        let neighbour = SensorPeerVerifier.Peer(
            processID: 200,
            executablePath: "/host/pipit-nativehost",
            parentPath: "/Applications/NotFirefox.app/Contents/MacOS/NotFirefox",
            parentBundleIdentifier: "com.example.notfirefox"
        )
        #expect(!verifier.isTrusted(neighbour), "another application in /Applications is not a browser")
        #expect(verifier.rejectionReason(neighbour).contains("browser"))

        let real = SensorPeerVerifier.Peer(
            processID: 201,
            executablePath: "/host/pipit-nativehost",
            parentPath: "/Applications/Firefox.app/Contents/MacOS/firefox",
            parentBundleIdentifier: nil
        )
        #expect(verifier.isTrusted(real), "the browser itself still passes")
    }
}

/// Runs the real capture chain against real hardware.
///
/// Opt-in because it needs microphone access and a running audio device. It is
/// the check that the refactored engine still records: everything else in the
/// suite drives the algorithm through fakes.
@Suite("LiveCapture")
struct LiveCaptureTests {
    @Test(
        "the real engine records both tracks and closes a valid manifest",
        .enabled(if: ProcessInfo.processInfo.environment["PIPIT_LIVE_CAPTURE"] == "1",
                 "set PIPIT_LIVE_CAPTURE=1 to record from real hardware")
    )
    func theRealEngineRecordsBothTracksAndClosesAValidManifest() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MeetingLayout(root: root)
        try FileManager.default.createDirectory(
            at: layout.segments, withIntermediateDirectories: true
        )

        let delegate = SilentDelegate()
        let engine = CaptureEngine(segmentSeconds: 3, delegate: delegate)
        await engine.arm(
            bundlePrefixes: ["org.mozilla.firefox", "com.tinyspeck.slackmacgap"],
            capturesRemote: true
        )
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try await engine.commit(layout: layout, meetingID: "live", source: .manual)
        try await Task.sleep(nanoseconds: 8_000_000_000)
        let snapshot = await engine.stop(reason: "test")

        let timeline = try ManifestReader.timeline(contentsOf: layout.manifest)
        #expect(
            timeline.duration(track: .mic) > 5,
            "expected microphone audio, got \(timeline.duration(track: .mic))s"
        )
        #expect(timeline.isComplete, "the manifest should close cleanly")
        #expect(timeline.openSegments.count == 0)
        #expect(timeline.segments(track: .mic).count >= 2, "3 s segments over 8 s should rotate")
        // Every closed segment on disk matches what the manifest claims.
        for segment in timeline.segments(track: .mic) {
            let info = try AudioFileInspector().inspect(
                url: layout.segments.appendingPathComponent(segment.file)
            )
            #expect(info.frameCount == (segment.frameCount ?? -1), "mismatch in \(segment.file)")
        }
        // Read back the way processing reads it. A device with more than
        // two channels used to convert to exact zeros, so a recording of
        // the right length could contain no audio at all.
        let stream = TrackAudioStream(
            segments: timeline.segments(track: .mic),
            segmentsDirectory: layout.segments,
            targetFormat: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        )
        var peak: Float = 0
        try stream.forEachBuffer { buffer, _ in
            if let data = buffer.floatChannelData {
                for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[0][frame])) }
            }
            return true
        }
        #expect(
            peak > 0,
            "the recording read back as digital silence from a \(timeline.segments(track: .mic).first?.format.channelCount ?? 0)-channel device"
        )
        #expect(snapshot.micSeconds > 5, "the final snapshot should report what was written")
        // The pre-roll captured before commit is part of the recording.
        #expect(
            timeline.preRollFlushes.contains { $0.track == .mic && $0.seconds > 1 },
            "the two seconds before commit should have been flushed"
        )
    }

    // The whole menu-bar path minus the click: the runtime creates the
    // meeting, drives the engine, finalises and hands the recording to the
    // pipeline. Everything below PipitRuntime is the shipping code.
    @Test(
        "a manual recording started through the runtime lands in the archive",
        .enabled(if: ProcessInfo.processInfo.environment["PIPIT_LIVE_CAPTURE"] == "1",
                 "set PIPIT_LIVE_CAPTURE=1 to record from real hardware")
    )
    func aManualRecordingStartedThroughTheRuntimeLandsInTheArchive() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Meetings")

        let runtime = await MainActor.run { () -> PipitRuntime in
            let runtime = PipitRuntime(settingsDirectory: root)
            var settings = runtime.settings
            settings.storageRootPath = archive.path
            settings.segmentSeconds = 3
            settings.showNotifications = false
            runtime.update(settings: settings)
            runtime.startManualRecording()
            return runtime
        }
        try await Task.sleep(nanoseconds: 9_000_000_000)
        await MainActor.run { runtime.stopRecording(reason: "test") }

        let repository = MeetingRepository(root: archive)
        var summaries = repository.listMeetings()
        for _ in 0..<40 where summaries.first?.processingState.isAudioSafe != true {
            try await Task.sleep(nanoseconds: 500_000_000)
            summaries = repository.listMeetings()
        }
        #expect(summaries.count == 1, "one manual recording, one meeting")
        guard let summary = summaries.first,
              let meeting = repository.findMeeting(id: summary.id)
        else {
            Issue.record("the meeting was never written")
            return
        }

        #expect(meeting.metadata.source == .manual)
        #expect(
            meeting.metadata.processing.state.isAudioSafe,
            "state is \(meeting.metadata.processing.state.rawValue); the audio must be durable"
        )
        let timeline = try meeting.store.readTimeline()
        #expect(timeline.isComplete, "the manifest should close cleanly")
        #expect(timeline.openSegments.count == 0)
        #expect(
            timeline.duration(track: .mic) > 5,
            "expected microphone audio, got \(timeline.duration(track: .mic))s"
        )
        #expect(
            meeting.metadata.durationSeconds > 5,
            "the meeting duration should match what was captured"
        )
        for segment in timeline.segments(track: .mic) {
            let info = try AudioFileInspector().inspect(
                url: meeting.store.layout.segments.appendingPathComponent(segment.file)
            )
            #expect(info.frameCount == (segment.frameCount ?? -1), "mismatch in \(segment.file)")
        }
        // No key is configured here, so processing stops at the first API
        // call. That is the guarantee worth pinning: the recording survives
        // a processing failure intact.
        if meeting.metadata.processing.state == .failed {
            let failure = meeting.metadata.processing.lastFailure
            #expect(
                failure?.message.lowercased().contains("key") ?? false,
                "expected a missing-credential failure, got \(failure?.message ?? "none")"
            )
        }
    }
}

/// A continuous capture soak against real hardware.
///
/// Opt-in and slow. It answers the questions a short run cannot: does memory
/// stay flat, do segments keep rotating, and is every file still readable and
/// consistent with the manifest at the end.
@Suite("Soak")
struct SoakTests {
    /// How many minutes the soak was asked for, and nil when it was not asked
    /// for at all.
    private static var requestedMinutes: Double? {
        guard let text = ProcessInfo.processInfo.environment["PIPIT_SOAK_MINUTES"],
              let minutes = Double(text), minutes > 0
        else { return nil }
        return minutes
    }

    @Test(
        "capture stays healthy and bounded over a long run",
        .enabled(if: SoakTests.requestedMinutes != nil,
                 "set PIPIT_SOAK_MINUTES=30 to run a capture soak")
    )
    func captureStaysHealthyAndBoundedOverALongRun() async throws {
        let minutes = try #require(SoakTests.requestedMinutes)
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MeetingLayout(root: root)
        try FileManager.default.createDirectory(
            at: layout.segments, withIntermediateDirectories: true
        )

        func residentMegabytes() -> Int {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Int(usage.ru_maxrss) / 1_048_576
        }

        let delegate = SilentDelegate()
        let engine = CaptureEngine(segmentSeconds: 30, delegate: delegate)
        await engine.arm(
            bundlePrefixes: ["org.mozilla.firefox", "com.tinyspeck.slackmacgap"],
            capturesRemote: true
        )
        try await engine.commit(layout: layout, meetingID: "soak", source: .manual)

        let startedMemory = residentMegabytes()
        let deadline = Date().addingTimeInterval(minutes * 60)
        var samples: [Int] = []
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            samples.append(residentMegabytes())
        }
        let snapshot = await engine.stop(reason: "soak_complete")

        let timeline = try ManifestReader.timeline(contentsOf: layout.manifest)
        let expected = minutes * 60
        #expect(
            timeline.duration(track: .mic) > expected * 0.97,
            "captured \(Int(timeline.duration(track: .mic)))s of an expected \(Int(expected))s"
        )
        #expect(timeline.isComplete)
        #expect(timeline.openSegments.count == 0)
        #expect(
            timeline.segments(track: .mic).count >= Int(minutes * 2) - 1,
            "30 s rotation should produce two segments a minute"
        )

        // Every segment on disk still matches what the manifest recorded.
        for segment in timeline.segments(track: .mic) {
            let info = try AudioFileInspector().inspect(
                url: layout.segments.appendingPathComponent(segment.file)
            )
            #expect(info.frameCount == (segment.frameCount ?? -1), "mismatch in \(segment.file)")
        }

        let peak = samples.max() ?? startedMemory
        #expect(
            peak - startedMemory < 100,
            "resident memory grew from \(startedMemory) MB to \(peak) MB"
        )
        #expect(snapshot.micSeconds > expected * 0.97, "the final snapshot should agree with the files")
        print(
            "    soak: \(Int(timeline.duration(track: .mic)))s captured, "
                + "\(timeline.segments(track: .mic).count) segments, "
                + "memory \(startedMemory) → \(peak) MB, "
                + "\(timeline.restarts.count) restarts"
        )
    }
}
