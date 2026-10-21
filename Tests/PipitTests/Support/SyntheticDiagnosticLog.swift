import Foundation
import PipitCore

/// A made-up event log with the shape of real use: launches, meetings with
/// their capture and processing events, browser add-ons coming and going,
/// update checks, and the occasional failure. Seeded, so a run is the same
/// every time. Nothing in it describes a real meeting.
struct SyntheticDiagnosticLog {
    /// SplitMix64.
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    private mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    private mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(max(1, bound))) }

    private mutating func pick<T>(_ values: [T]) -> T { values[below(values.count)] }

    private mutating func uuid() -> UUID {
        let high = next()
        let low = next()
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8(truncatingIfNeeded: high >> (index * 8))
            bytes[index + 8] = UInt8(truncatingIfNeeded: low >> (index * 8))
        }
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6] & 0x0F | 0x40, bytes[7],
                bytes[8] & 0x3F | 0x80, bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }

    /// `days` of use ending at `end`, `meetingsPerDay` meetings a day.
    /// `chatter` adds that many extra add-on and capture events per meeting,
    /// for a log that fills the 10 MB the files keep.
    mutating func events(days: Int, end: Date, meetingsPerDay: Int, chatter: Int = 0) -> [DiagnosticEvent] {
        var events: [DiagnosticEvent] = []
        let start = end.addingTimeInterval(-Double(days) * 86_400)
        for day in 0..<days {
            let morning = start.addingTimeInterval(Double(day) * 86_400 + 8 * 3_600)
            var clock = morning
            func tick(_ seconds: Double) -> Date {
                clock = clock.addingTimeInterval(seconds)
                return clock
            }
            let launch = DiagnosticLaunchID(uuid: uuid())
            func add(
                _ kind: DiagnosticEvent.Kind, after seconds: Double, session: DiagnosticSessionID? = nil,
                job: DiagnosticJobID? = nil, count: Int = 1
            ) {
                events.append(
                    DiagnosticEvent(
                        time: tick(seconds), launch: launch, session: session, job: job, kind: kind, count: count)
                )
            }

            add(
                .appLaunched(
                    .init(
                        version: "0.1.8", build: "812", commit: "9e8e301640b62399dfabc104e5252138a5f09925",
                        os: "15.6.1", osBuild: "24G90", hardware: "Mac15,3", arch: .appleSilicon
                    )
                ),
                after: 0
            )
            add(
                .appPreviousExit(
                    exitClass: pick([.clean, .clean, .clean, .systemRestart, .uncleanUnknown]),
                    previousLaunch: DiagnosticLaunchID(uuid: uuid())), after: 1.2)
            for permission in DiagnosticEvent.Permission.allCases {
                add(
                    .permissionState(permission: permission, state: pick([.granted, .granted, .granted, .denied])),
                    after: 0.05)
            }
            add(.updateChecked(outcome: pick([.upToDate, .upToDate, .available, .failed]), code: nil), after: 30)
            add(.nativeHostStarted(browser: .firefox), after: 2)
            add(
                .browserAddonConnected(
                    browser: .firefox, addonVersion: .version("1.0.1"), hostVersion: .version("1.1.0"),
                    protocolVersion: 2
                ),
                after: 0.3
            )

            for _ in 0..<meetingsPerDay {
                _ = tick(Double(600 + below(3_600)))
                let session = DiagnosticSessionID(uuid: uuid())
                let source = pick([MeetingSource.googleMeet, .zoom, .slackHuddle, .faceTime, .genericCall])
                add(
                    .detectionMeeting(
                        source: source, evidence: pick([.browserAddon, .windowTitle, .processAudio]),
                        browser: pick([.firefox, .chrome, nil])), after: 0)
                add(
                    .sessionStarted(source: source, trigger: pick([.auto, .auto, .manual]), segmentSeconds: 30),
                    after: 0.4, session: session)
                add(
                    .captureBound(
                        track: .mic, transport: pick([.builtIn, .bluetooth, .usb]), sampleRate: 48_000, channels: 1,
                        targets: nil), after: 0.2, session: session)
                add(
                    .captureBound(
                        track: .remote, transport: .aggregate, sampleRate: 48_000, channels: 2, targets: 1 + below(3)),
                    after: 0.1, session: session)
                for _ in 0..<chatter {
                    switch below(4) {
                    case 0:
                        add(
                            .captureHealth(
                                track: pick([.mic, .remote]), state: pick([.healthy, .recovering, .degraded])),
                            after: Double(5 + below(60)), session: session)
                    case 1:
                        add(
                            .captureRestarted(
                                track: .remote, reason: pick([.configurationChange, .watchdog, .wake]),
                                count: 1 + below(3)), after: Double(5 + below(60)), session: session)
                    case 2:
                        add(
                            .browserAddonDisconnected(browser: .safari, reason: .silence), after: Double(5 + below(60)),
                            count: 1 + below(4))
                    default:
                        add(
                            .captureWarning(code: .word(pick(["mic_silent", "remote_silent", "device_changed"]))),
                            after: Double(5 + below(60)), session: session)
                    }
                }
                let seconds = Double(900 + below(3_600))
                add(
                    .sessionStopped(trigger: pick([.auto, .manual]), seconds: seconds, segments: Int(seconds / 30)),
                    after: seconds, session: session)
                for stage in [ProcessingState.finalizing, .transcribing, .diarizing, .resolvingSpeakers, .enriching] {
                    let job = DiagnosticJobID(uuid: uuid())
                    add(.processingStageStarted(stage: stage, attempt: 1), after: 0.5, session: session, job: job)
                    if stage == .enriching, below(8) == 0 {
                        add(
                            .processingStageFailed(
                                stage: stage, attempt: 1, code: DiagnosticCode("language_model", "unreachable"),
                                retryable: true), after: 12.5, session: session, job: job)
                    } else {
                        add(
                            .processingStageFinished(stage: stage, attempt: 1, seconds: Double(below(90_000)) / 1_000),
                            after: Double(1 + below(90)), session: session, job: job)
                    }
                }
            }
            if below(5) == 0 { add(.diagnosticsDropped(count: 1 + below(5)), after: 3) }
            add(.nativeHostExited(reason: .browserClosed, relayed: below(400)), after: 1_800)
            add(.appTerminated, after: 3_600)
        }
        return events
    }
}
