import AppKit
import Foundation
import PipitCore
import SwiftUI
import Testing

@testable import PipitServices
@testable import PipitUI

/// Frames of the meetings window while one meeting is processed, for a person
/// to turn into a video. Runs only when `PIPIT_RENDER_VIDEO_DIR` names a folder.
///
/// The run follows a 30-minute meeting on a Mac that has timed a few meetings
/// before, sped up ten times, with the reports the app really sends: nothing
/// from echo removal or a local transcription engine, a minute of the speaker
/// model loading, then its own progress. Each step runs a little longer or
/// shorter than this Mac's history expects, as real runs do.
@Suite("Processing steps video", .tags(.slow))
@MainActor
struct ProcessingStepsVideoTests {
    nonisolated static let folder = ProcessInfo.processInfo.environment["PIPIT_RENDER_VIDEO_DIR"]

    private struct Moment {
        var state: ProcessingState
        var step: ProcessingStep?
        var fraction: Double?
        var detail: String?
    }

    /// Seconds of real processing each step takes in this run.
    private static let run: [(ProcessingState, ProcessingStep, Double)] = [
        (.audioSafe, .save, 3), (.transcribing, .removeEcho, 135), (.transcribing, .transcribe, 26),
        (.diarizing, .identifySpeakers, 160), (.resolvingSpeakers, .matchNames, 5), (.enriching, .writeNotes, 15),
    ]
    private static let speakerModelLoading = 60.0
    private static let speed = 10.0
    private static let fps = 10.0

    @Test("frames of a meeting going through every step", .enabled(if: folder != nil))
    func frames() async throws {
        let output = URL(fileURLWithPath: try #require(Self.folder))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        NSApplication.shared.setActivationPolicy(.prohibited)

        let built = try ProcessingArchive.make(root: root, history: ProcessingArchive.timedHistory)
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        for (title, source, offset) in [
            ("Design review", MeetingSource.googleMeet, -7_200.0), ("Hiring sync", .zoom, -86_400),
            ("Roadmap planning", .googleMeet, -90_000), ("Customer call", .slackHuddle, -200_000),
        ] {
            _ = try RuntimeFixtures.makeMeeting(
                root: root, clusters: ["remote-001_speaker_00", "remote-001_speaker_01"], source: source,
                title: title, startedAt: started.addingTimeInterval(offset))
        }
        let model = MeetingsWindowModel(runtime: built.runtime)
        let window = WindowManager.makeSplitWindow(
            title: "Render", size: CGSize(width: 1_100, height: 720), content: MeetingsWindowView(model: model),
            autosaveName: "PipitRenderTest")
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(CGSize(width: 1_100, height: 720))
        window.hasShadow = false
        WindowRender.orderInOutOfSight(window)
        defer { window.close() }

        let total = Self.run.reduce(0) { $0 + $1.2 }
        let hold = 30.0
        let tick = Self.speed / Self.fps
        var lastState: ProcessingState?
        var frame = 0
        var time = 0.0
        while time <= total + hold {
            let moment = Self.moment(at: min(time, total - 0.01))
            if moment.state != lastState, moment.state == .enriching {
                try ProcessingArchive.writeTranscript(built.store)
            }
            if moment.state != lastState {
                _ = try built.store.updateMetadata {
                    $0.titles = TitleCandidates(provider: "Weekly sync", timestampFallback: "f")
                    $0.durationSeconds = 1_815
                    $0.processing = ProcessingStatus(state: moment.state, updatedAt: $0.startedAt)
                }
            }
            built.runtime.apply(
                ProcessingPipeline.Progress(
                    meetingID: built.id, state: moment.state, completedChunks: 0, totalChunks: 0,
                    title: "Weekly sync", fraction: moment.fraction, detail: moment.detail, step: moment.step))
            if moment.state != lastState {
                try await ProcessingArchive.open(built.id, in: model)
                lastState = moment.state
            }
            try await Task.sleep(for: .milliseconds(60))
            window.contentView?.displayIfNeeded()
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = [
                "-x", "-o", "-l\(window.windowNumber)",
                output.appendingPathComponent(String(format: "frame-%04d.png", frame)).path,
            ]
            try capture.run()
            capture.waitUntilExit()
            built.clock.advance(tick)
            time += tick
            frame += 1
        }
        #expect(frame > 0)
    }

    /// What the pipeline reports at a time in the run, in seconds.
    private static func moment(at time: Double) -> Moment {
        var start = 0.0
        for (state, step, seconds) in run {
            if time < start + seconds {
                let within = time - start
                if step == .identifySpeakers {
                    if within < speakerModelLoading {
                        return Moment(state: state, detail: ProcessingPipeline.Progress.loadingSpeakerModel)
                    }
                    let fraction = (within - speakerModelLoading) / (seconds - speakerModelLoading)
                    return Moment(state: state, fraction: fraction)
                }
                return Moment(state: state, step: step == .removeEcho ? .removeEcho : nil)
            }
            start += seconds
        }
        return Moment(state: .enriching)
    }
}
