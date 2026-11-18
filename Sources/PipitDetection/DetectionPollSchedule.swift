import Foundation
import PipitCore

/// When detection's timer fires and what each tick does, kept apart from the
/// timer itself so the sequence of events, ticks and polls can be tested.
///
/// The full poll (audio, window titles, Slack's accessibility tree) runs every
/// `pollInterval` while anything could be a meeting and every
/// `idlePollInterval` otherwise. While quiet with an application playing
/// audio, the timer still fires every `pollInterval`, and those ticks read only
/// the audio flags, because an application already playing can open the
/// microphone on the same device without Core Audio saying so. An event (a
/// Core Audio change, an add-on message) asks for a full poll at once, but
/// never sooner than `pollInterval` after the last one.
///
/// Not thread-safe: the engine uses it only on its own queue.
struct DetectionPollSchedule {
    /// What to set the timer to.
    struct TimerSetting: Equatable {
        var delay: Double
        var interval: Double
        var leewayMilliseconds: Int
    }

    let configuration: DetectionEngine.Configuration
    /// Whether the last full poll found nothing that could be a meeting.
    private(set) var isQuiet = false
    /// How often the timer repeats now.
    private(set) var tickInterval: Double
    private var lastFullPollAt: Double?
    /// An event asked for a full poll on the next tick.
    private var fullPollRequested = false
    /// The timer was last set for an event's poll rather than for the cadence.
    private var timerHasOneOffDeadline = false

    init(configuration: DetectionEngine.Configuration) {
        self.configuration = configuration
        self.tickInterval = configuration.pollInterval
    }

    /// The setting a starting engine gives its timer.
    var startSetting: TimerSetting {
        TimerSetting(
            delay: 0.2, interval: configuration.pollInterval,
            leewayMilliseconds: Self.leewayMilliseconds(for: configuration.pollInterval, configuration)
        )
    }

    /// Back to the state of a fresh start.
    mutating func reset() {
        self = DetectionPollSchedule(configuration: configuration)
    }

    /// An event that could start a meeting arrived. Returns the timer setting
    /// for a prompt full poll, or nil while polls are already fast or one is
    /// already on its way.
    mutating func eventArrived(at now: Double) -> TimerSetting? {
        guard isQuiet, !fullPollRequested else { return nil }
        fullPollRequested = true
        timerHasOneOffDeadline = true
        let wait = Self.delayBeforeRequestedPoll(
            sinceLastFullPoll: lastFullPollAt.map { now - $0 }, configuration: configuration
        )
        // The short leeway: this poll answers an event, and the idle leeway
        // would let it slip by a quarter of a second.
        return TimerSetting(delay: wait, interval: tickInterval, leewayMilliseconds: 50)
    }

    /// A timer tick. True when it should be a full poll, which the caller
    /// follows with `pollFinished`; false when the audio read was enough, and
    /// the caller follows with `pollFinished(quiet: true, ...)`.
    mutating func beginTick(at now: Double, audio: [ApplicationAudioState]) -> Bool {
        guard
            Self.needsFullPoll(
                quiet: isQuiet, requested: fullPollRequested, audio: audio,
                sinceLastFullPoll: lastFullPollAt.map { now - $0 }, configuration: configuration
            )
        else { return false }
        fullPollRequested = false
        lastFullPollAt = now
        return true
    }

    /// What the tick found. Returns a new timer setting when the cadence
    /// changes, or when an event's one-off deadline has to give way to it.
    mutating func pollFinished(quiet: Bool, audio: [ApplicationAudioState]) -> TimerSetting? {
        isQuiet = quiet
        let interval = Self.tickInterval(quiet: quiet, audio: audio, configuration: configuration)
        guard interval != tickInterval || timerHasOneOffDeadline else { return nil }
        timerHasOneOffDeadline = false
        tickInterval = interval
        return TimerSetting(
            delay: interval, interval: interval,
            leewayMilliseconds: Self.leewayMilliseconds(for: interval, configuration)
        )
    }

    /// Room for the system to fold the wake-up into others. Idle ticks can
    /// wait longer, since nothing they look for is in progress.
    static func leewayMilliseconds(for interval: Double, _ configuration: DetectionEngine.Configuration) -> Int {
        interval > configuration.pollInterval ? 250 : 50
    }

    /// How often the timer fires: fast while anything could be a meeting or
    /// any application is playing or recording audio, slow otherwise.
    static func tickInterval(
        quiet: Bool, audio: [ApplicationAudioState], configuration: DetectionEngine.Configuration
    ) -> Double {
        let audioRunning = audio.contains { $0.holdsMicrophone || $0.producesOutput }
        return quiet && !audioRunning ? configuration.idlePollInterval : configuration.pollInterval
    }

    /// Whether a tick reads everything or only the audio flags.
    static func needsFullPoll(
        quiet: Bool, requested: Bool, audio: [ApplicationAudioState], sinceLastFullPoll: Double?,
        configuration: DetectionEngine.Configuration
    ) -> Bool {
        guard quiet, !requested, !audio.contains(where: \.holdsMicrophone), let elapsed = sinceLastFullPoll
        else { return true }
        // Half a fast tick of slack, so a full poll due on this tick is not
        // pushed to the next one by timer jitter.
        return elapsed >= configuration.idlePollInterval - configuration.pollInterval / 2
    }

    /// How long a poll an event asked for waits: none, unless the last full
    /// poll was less than `pollInterval` ago.
    static func delayBeforeRequestedPoll(
        sinceLastFullPoll: Double?, configuration: DetectionEngine.Configuration
    ) -> Double {
        guard let elapsed = sinceLastFullPoll else { return 0 }
        return max(0, configuration.pollInterval - elapsed)
    }
}
