import Foundation
import PipitCore
import Synchronization

/// Stands in for AVAudioEngine. Records every teardown and build so a rebuild
/// storm is countable, and lets a test script the exact device readings macOS
/// produced during Bluetooth negotiation, including the transient 0ch/0Hz one.
public final class FakeMicrophoneEngine: MicrophoneEngineController, Sendable {
    public init() {}

    public struct Build: Sendable, Equatable {
        public let format: AudioFormatDescriptor

        public init(format: AudioFormatDescriptor) {
            self.format = format
        }
    }

    private struct State {
        var formatQueue: [AudioFormatDescriptor?] = []
        var steadyFormat: AudioFormatDescriptor? = AudioFormatDescriptor(sampleRate: 48_000, channelCount: 1)
        var builds: [Build] = []
        var teardowns = 0
        var running = false
        var failNextBuild: CaptureError?
        var formatReads = 0
        var installedFormat: AudioFormatDescriptor?
        var failEveryBuild: CaptureError?
        var deviceUID: String? = "fake-input"
        /// The OSStatus a build reports for a device it could not open. A
        /// build that reports one still succeeds, which is the real shape:
        /// `MicrophoneSource` keeps the engine it built on whatever device the
        /// input unit already held.
        var deviceSelectionStatus: Int32?
        /// Runs inside `buildAndStart`, before the build is decided. A driver
        /// that flushes a buffer while the device is being opened delivers it
        /// here, on the coordinator's own call stack, which is the only place
        /// a test can put a buffer into the window between teardown and the
        /// build's outcome.
        var duringBuild: (@Sendable () -> Void)?
        /// Runs inside `teardown`. A driver that flushes a buffer as the tap is
        /// removed delivers it here, on the coordinator's own call stack, after
        /// the rebuild has been decided and before the new build begins.
        var duringTeardown: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    public var builds: [Build] { state.withLock { $0.builds } }
    public var buildCount: Int { state.withLock { $0.builds.count } }
    public var teardownCount: Int { state.withLock { $0.teardowns } }
    public var isRunning: Bool { state.withLock { $0.running } }
    public var formatReads: Int { state.withLock { $0.formatReads } }

    /// Sets the device reading returned once capture settles.
    public func setSteadyFormat(_ format: AudioFormatDescriptor?) {
        state.withLock { $0.steadyFormat = format }
    }

    /// The identity of the device behind the readings. Changing it is a
    /// different device; changing only the format is the same device
    /// renegotiating.
    public func setDeviceUID(_ uid: String?) {
        state.withLock { $0.deviceUID = uid }
    }

    /// Makes every build report that it could not open the device it asked for.
    public func setDeviceSelectionStatus(_ status: Int32?) {
        state.withLock { $0.deviceSelectionStatus = status }
    }

    public func setDuringBuild(_ hook: (@Sendable () -> Void)?) {
        state.withLock { $0.duringBuild = hook }
    }

    public func setDuringTeardown(_ hook: (@Sendable () -> Void)?) {
        state.withLock { $0.duringTeardown = hook }
    }

    public func currentInputDeviceUID() -> String? {
        state.withLock { $0.deviceUID }
    }

    public func currentInputDevice() -> MicrophoneDeviceDescription? {
        state.withLock { state in
            guard let uid = state.deviceUID else { return nil }
            let format = state.installedFormat ?? state.steadyFormat
            return MicrophoneDeviceDescription(
                uid: uid, name: "Fake input",
                sampleRate: format?.sampleRate ?? 0, channelCount: format?.channelCount ?? 0
            )
        }
    }

    /// Queues one-shot device readings, consumed in order before the steady value.
    public func queueFormatReadings(_ formats: [AudioFormatDescriptor?]) {
        state.withLock { $0.formatQueue.append(contentsOf: formats) }
    }

    public func failNextBuild(with error: CaptureError) {
        state.withLock { $0.failNextBuild = error }
    }

    /// Every build fails until `stopFailing`, which is a device that is gone
    /// rather than one that is momentarily busy.
    public func failEveryBuild(with error: CaptureError) {
        state.withLock { $0.failEveryBuild = error }
    }

    public func stopFailing() {
        state.withLock { state in
            state.failEveryBuild = nil
            state.failNextBuild = nil
        }
    }

    public func currentInputFormat() -> AudioFormatDescriptor? {
        state.withLock { state in
            state.formatReads += 1
            if !state.formatQueue.isEmpty { return state.formatQueue.removeFirst() }
            return state.steadyFormat
        }
    }

    public func teardown() {
        let hook: (@Sendable () -> Void)? = state.withLock { state in
            state.teardowns += 1
            let wasRunning = state.running
            state.running = false
            return wasRunning ? state.duringTeardown : nil
        }
        hook?()
    }

    /// The format the hardware settles on, which may differ from what the
    /// coordinator asked for.
    public func setInstalledFormat(_ format: AudioFormatDescriptor?) {
        state.withLock { $0.installedFormat = format }
    }

    @discardableResult
    public func buildAndStart(preferred: AudioFormatDescriptor) throws -> MicrophoneBuild {
        state.withLock { $0.duringBuild }?()
        let failure: CaptureError? = state.withLock { state in
            if let always = state.failEveryBuild {
                state.builds.append(Build(format: preferred))
                return always
            }
            defer { state.failNextBuild = nil }
            return state.failNextBuild
        }
        if let failure { throw failure }
        return state.withLock { state in
            let installed = state.installedFormat ?? preferred
            state.builds.append(Build(format: installed))
            state.running = true
            return MicrophoneBuild(
                format: installed, deviceSelectionStatus: state.deviceSelectionStatus
            )
        }
    }
}

/// Stands in for the CoreAudio process tap.
public final class FakeProcessTap: ProcessTapController, Sendable {
    public init() {}

    private struct State {
        var targets: [RemoteAudioTarget] = []
        var binds: [[Int32]] = []
        var teardowns = 0
        var format = AudioFormatDescriptor(sampleRate: 48_000, channelCount: 2)
        var failNextBind: CaptureError?
        /// What the current bind's first callback delivered. Cleared by every
        /// bind, as the real source clears it on teardown, so a rebind that
        /// delivers nothing reports nothing.
        var firstCallback: TapCallbackReading?
    }

    private let state = Mutex(State())

    public var bindCount: Int { state.withLock { $0.binds.count } }
    public var bindHistory: [[Int32]] { state.withLock { $0.binds } }
    public var teardownCount: Int { state.withLock { $0.teardowns } }

    public func setTargets(_ targets: [RemoteAudioTarget]) {
        state.withLock { $0.targets = targets }
    }

    public func setFormat(_ format: AudioFormatDescriptor) {
        state.withLock { $0.format = format }
    }

    public func failNextBind(with error: CaptureError) {
        state.withLock { $0.failNextBind = error }
    }

    public func resolveTargets(bundlePrefixes: [String]) -> [RemoteAudioTarget] {
        state.withLock { state in
            state.targets.filter { target in
                bundlePrefixes.contains { target.bundleIdentifier.hasPrefix($0) }
            }
        }
    }

    public func teardown() {
        state.withLock { $0.teardowns += 1 }
    }

    /// The tap's first IOProc callback of the current bind arriving.
    public func deliverFirstCallback(_ reading: TapCallbackReading) {
        state.withLock { $0.firstCallback = reading }
    }

    public func bind(to targets: [RemoteAudioTarget]) throws -> RemoteTapBinding {
        let failure: CaptureError? = state.withLock { state in
            defer { state.failNextBind = nil }
            return state.failNextBind
        }
        if let failure { throw failure }
        return state.withLock { state in
            state.binds.append(targets.map(\.processID).sorted())
            state.firstCallback = nil
            return RemoteTapBinding(format: state.format, streamCount: 2, tapStreamIndex: 1)
        }
    }

    public func firstCallback() -> TapCallbackReading? {
        state.withLock { $0.firstCallback }
    }
}

/// Captures coordinator callbacks so a test can assert on the manifest-visible
/// consequences of recovery.
public final class RecordingCaptureDelegate: CaptureCoordinatorDelegate, Sendable {
    public init() {}

    public struct FormatChange: Sendable, Equatable {
        public let track: CaptureTrack
        public let from: AudioFormatDescriptor?
        public let to: AudioFormatDescriptor
        public let reason: String

        public init(track: CaptureTrack, from: AudioFormatDescriptor?, to: AudioFormatDescriptor, reason: String) {
            self.track = track
            self.from = from
            self.to = to
            self.reason = reason
        }
    }

    public struct Restart: Sendable, Equatable {
        public let track: CaptureTrack
        public let reason: String
        public let count: Int

        public init(track: CaptureTrack, reason: String, count: Int) {
            self.track = track
            self.reason = reason
            self.count = count
        }
    }

    public struct HealthChange: Sendable, Equatable {
        public let track: CaptureTrack
        public let state: CaptureHealthState
        /// The reason written beside the state in the manifest.
        public let detail: String?

        public init(track: CaptureTrack, state: CaptureHealthState, detail: String?) {
            self.track = track
            self.state = state
            self.detail = detail
        }
    }

    public struct RemoteBind: Sendable, Equatable {
        public let reason: String
        public let processIDs: [Int32]
        public let producing: [Bool]
        public let count: Int
        public let binding: RemoteTapBinding

        public init(reason: String, processIDs: [Int32], producing: [Bool], count: Int, binding: RemoteTapBinding) {
            self.reason = reason
            self.processIDs = processIDs
            self.producing = producing
            self.count = count
            self.binding = binding
        }
    }

    public struct RemoteStream: Sendable, Equatable {
        public let reading: TapCallbackReading
        public let bindCount: Int

        public init(reading: TapCallbackReading, bindCount: Int) {
            self.reading = reading
            self.bindCount = bindCount
        }
    }

    public struct MicBind: Sendable, Equatable {
        public let device: MicrophoneDeviceDescription
        public let build: MicrophoneBuild
        public let reason: String

        public init(device: MicrophoneDeviceDescription, build: MicrophoneBuild, reason: String) {
            self.device = device
            self.build = build
            self.reason = reason
        }
    }

    private struct State {
        var formatChanges: [FormatChange] = []
        var restarts: [Restart] = []
        var healthChanges: [HealthChange] = []
        var remoteBinds: [RemoteBind] = []
        var remoteStreams: [RemoteStream] = []
        var micBinds: [MicBind] = []
        var failures: [CaptureError] = []
    }

    private let state = Mutex(State())

    public var formatChanges: [FormatChange] { state.withLock { $0.formatChanges } }
    public var restarts: [Restart] { state.withLock { $0.restarts } }
    public var healthChanges: [HealthChange] { state.withLock { $0.healthChanges } }
    public var remoteBinds: [RemoteBind] { state.withLock { $0.remoteBinds } }
    public var remoteStreams: [RemoteStream] { state.withLock { $0.remoteStreams } }
    public var micBinds: [MicBind] { state.withLock { $0.micBinds } }
    public var failures: [CaptureError] { state.withLock { $0.failures } }

    public func captureWillChangeFormat(
        track: CaptureTrack, from: AudioFormatDescriptor?, to: AudioFormatDescriptor, reason: String
    ) {
        state.withLock { $0.formatChanges.append(FormatChange(track: track, from: from, to: to, reason: reason)) }
    }

    public func captureDidRestart(track: CaptureTrack, reason: RebuildReason, restartCount: Int) {
        state.withLock { $0.restarts.append(Restart(track: track, reason: reason.label, count: restartCount)) }
    }

    public func captureHealthChanged(track: CaptureTrack, state newState: CaptureHealthState, detail: String?) {
        state.withLock {
            $0.healthChanges.append(HealthChange(track: track, state: newState, detail: detail))
        }
    }

    public func captureDidBindRemote(
        targets: [RemoteAudioTarget], reason: RebuildReason, bindCount: Int, binding: RemoteTapBinding
    ) {
        state.withLock {
            $0.remoteBinds.append(RemoteBind(
                reason: reason.label,
                processIDs: targets.map(\.processID),
                producing: targets.map(\.isRunningOutput),
                count: bindCount,
                binding: binding
            ))
        }
    }

    public func captureDidReadRemoteStream(reading: TapCallbackReading, bindCount: Int) {
        state.withLock {
            $0.remoteStreams.append(RemoteStream(reading: reading, bindCount: bindCount))
        }
    }

    public func captureDidBindMicrophone(
        device: MicrophoneDeviceDescription, build: MicrophoneBuild, reason: RebuildReason
    ) {
        state.withLock {
            $0.micBinds.append(MicBind(device: device, build: build, reason: reason.label))
        }
    }

    public func captureDidFail(track: CaptureTrack, error: CaptureError) {
        state.withLock { $0.failures.append(error) }
    }
}

public func makeTarget(
    pid: Int32, bundle: String = "org.mozilla.firefox", producing: Bool = false, objectID: UInt32? = nil
) -> RemoteAudioTarget {
    RemoteAudioTarget(
        audioObjectID: objectID ?? UInt32(pid),
        processID: pid,
        bundleIdentifier: bundle,
        isRunningOutput: producing
    )
}
