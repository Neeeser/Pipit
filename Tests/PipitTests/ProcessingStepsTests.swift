import AppKit
import Foundation
import PipitCore
import SwiftUI
import Synchronization
import Testing

@testable import PipitServices
@testable import PipitUI

private func progress(
    _ state: ProcessingState, id: String = "m", fraction: Double? = nil, detail: String? = nil,
    step: ProcessingStep? = nil, isWaiting: Bool = false, chunks: (Int, Int) = (0, 0)
) -> ProcessingPipeline.Progress {
    ProcessingPipeline.Progress(
        meetingID: id, state: state, completedChunks: chunks.0, totalChunks: chunks.1,
        title: "Weekly sync", fraction: fraction, detail: detail, step: step, isWaiting: isWaiting
    )
}

/// Which step the pane names, and which steps it lists.
@Suite("Processing steps")
struct ProcessingStepsTests {
    /// The review of the first version found the pane naming echo removal for
    /// the whole of transcription: local engines report nothing until they
    /// finish, so the step was guessed from a stale metadata field. The step
    /// now comes from the pipeline's report.
    @Test("a report with no fraction during transcription names transcription")
    func transcriptionIsNamedWithoutAFraction() throws {
        let steps = try #require(
            ProcessingSteps(
                state: .transcribing,
                progress: progress(.transcribing, detail: ProcessingPipeline.Progress.preparingModels),
                metadata: nil))
        #expect(steps.current == .transcribe)
        #expect(steps.note == ProcessingPipeline.Progress.preparingModels)
    }

    @Test("the echo step comes from the pipeline's report")
    func echoComesFromTheReport() throws {
        let steps = try #require(
            ProcessingSteps(state: .transcribing, progress: progress(.transcribing, step: .removeEcho), metadata: nil))
        #expect(steps.current == .removeEcho)
    }

    @Test("a meeting with no call audio has no echo step")
    func noCallAudioNoEchoStep() {
        #expect(!ProcessingStep.steps(for: .inPerson).contains(.removeEcho))
        #expect(!ProcessingStep.steps(for: .imported).contains(.removeEcho))
        #expect(ProcessingStep.steps(for: .googleMeet).contains(.removeEcho))
    }

    @Test("plumbing lines stay out of the pane, waiting and loading lines show")
    func onlyUsefulNotesShow() throws {
        let aligning = try #require(
            ProcessingSteps(
                state: .transcribing, progress: progress(.transcribing, detail: "Aligning transcript timings"),
                metadata: nil))
        #expect(aligning.note == nil)
        let waiting = try #require(
            ProcessingSteps(
                state: .audioSafe,
                progress: progress(
                    .audioSafe, detail: ProcessingPipeline.Progress.waitingForOtherMeeting, isWaiting: true),
                metadata: nil))
        #expect(waiting.note == ProcessingPipeline.Progress.waitingForOtherMeeting)
        #expect(waiting.isWaiting)
    }

    @Test("a report from an earlier stage is not read as this one's")
    func staleReportIsIgnored() throws {
        let steps = try #require(
            ProcessingSteps(state: .diarizing, progress: progress(.transcribing, fraction: 0.9), metadata: nil))
        #expect(steps.current == .identifySpeakers)
        #expect(steps.reported == nil)
    }

    @Test("the furthest progress reached is kept when a later pass starts from zero")
    func reachedIsKept() throws {
        let steps = try #require(
            ProcessingSteps(
                state: .transcribing, progress: progress(.transcribing, chunks: (1, 10)), metadata: nil,
                reached: 0.8))
        #expect(steps.reported == 0.8)
    }

    @Test("recording, failed, and finished meetings show no steps")
    func terminalStatesShowNoSteps() {
        for state in [ProcessingState.recording, .failed, .complete] {
            #expect(ProcessingSteps(state: state, progress: nil, metadata: nil) == nil)
        }
    }

    @Test("time left shows only after enough timed meetings, and never while waiting")
    func timeLeftNeedsHistory() {
        var history = ProcessingTimeHistory()
        #expect(ProcessingSteps.timeLeft(300, history: history, isWaiting: false) == nil)
        for _ in 0..<ProcessingTimeHistory.runsBeforeTimeLeft {
            history.record([.transcribe: 30], meetingSeconds: 1_800)
        }
        #expect(ProcessingSteps.timeLeft(300, history: history, isWaiting: false) == "About 5 min left")
        #expect(ProcessingSteps.timeLeft(301, history: history, isWaiting: false) == "About 6 min left")
        #expect(ProcessingSteps.timeLeft(40, history: history, isWaiting: false) == "Less than a minute left")
        #expect(ProcessingSteps.timeLeft(300, history: history, isWaiting: true) == nil)
    }
}

/// This Mac's step times and the estimate built from them.
@Suite("Processing estimate")
struct ProcessingEstimateTests {
    @Test("a step that scales with length is estimated as a rate of this Mac's meetings")
    func scalingStepsUseARate() {
        var history = ProcessingTimeHistory()
        history.record([.removeEcho: 120, .writeNotes: 15], meetingSeconds: 1_800)
        history.record([.removeEcho: 40, .writeNotes: 25], meetingSeconds: 600)
        // 4 seconds of work per minute in both meetings.
        #expect(history.expectedSeconds(.removeEcho, meetingSeconds: 3_600) == 240)
        // Notes take about the same time for any meeting.
        #expect(history.expectedSeconds(.writeNotes, meetingSeconds: 3_600) == 20)
    }

    @Test("a step this Mac has never timed uses the built-in guess")
    func untimedStepsUseTheDefault() {
        let history = ProcessingTimeHistory()
        // A fixed start-up part plus a part per minute of meeting.
        #expect(history.expectedSeconds(.removeEcho, meetingSeconds: 600) == 125)
    }

    @Test("short meetings, mostly start-up time, do not set the rate for long ones")
    func shortMeetingsKeepToThemselves() {
        var history = ProcessingTimeHistory()
        history.record([.identifySpeakers: 70], meetingSeconds: 120)
        history.record([.identifySpeakers: 70], meetingSeconds: 120)
        history.record([.identifySpeakers: 210], meetingSeconds: 1_800)
        #expect(history.expectedSeconds(.identifySpeakers, meetingSeconds: 3_600) == 420)
        #expect(history.expectedSeconds(.identifySpeakers, meetingSeconds: 150) == 70)
    }

    @Test("only the newest samples of a step are kept")
    func oldSamplesAreDropped() {
        var history = ProcessingTimeHistory()
        for _ in 0..<5 { history.record([.transcribe: 600], meetingSeconds: 600) }
        for _ in 0..<ProcessingTimeHistory.keptPerStep { history.record([.transcribe: 60], meetingSeconds: 600) }
        #expect(history.expectedSeconds(.transcribe, meetingSeconds: 600) == 60)
        #expect(history.samples.count == ProcessingTimeHistory.keptPerStep)
    }

    @Test("a step that reports nothing stops short of the end until it finishes")
    func estimateStopsShort() {
        let estimate = ProcessingEstimate(
            steps: [.save, .transcribe], current: .transcribe, secondsInStep: 10_000, reported: nil,
            history: ProcessingTimeHistory(), meetingSeconds: 600)
        #expect(estimate.segments[1].fill == ProcessingEstimate.estimateCeiling)
        #expect(estimate.secondsLeft > 0, "a step past its estimate still has time left")
    }

    @Test("the first report after a model loads never sends the bar back")
    func firstReportDoesNotGoBack() {
        let history = ProcessingTimeHistory()
        let steps: [ProcessingStep] = [.transcribe, .identifySpeakers, .matchNames]
        let expected = history.expectedSeconds(.identifySpeakers, meetingSeconds: 600)
        let loading = ProcessingEstimate(
            steps: steps, current: .identifySpeakers, secondsInStep: expected / 2, reported: nil,
            history: history, meetingSeconds: 600)
        let reporting = ProcessingEstimate(
            steps: steps, current: .identifySpeakers, secondsInStep: expected / 2 + 1, reported: 0.01,
            history: history, meetingSeconds: 600)
        #expect(reporting.overall >= loading.overall)
        let ahead = ProcessingEstimate(
            steps: steps, current: .identifySpeakers, secondsInStep: 1, reported: 0.9,
            history: history, meetingSeconds: 600)
        #expect(ahead.segments[1].fill == 0.9, "a report ahead of the guess wins")
    }

    @Test("segments are as wide as their expected time and the whole bar adds up")
    func segmentsShareTheBar() {
        var history = ProcessingTimeHistory()
        history.record([.save: 10, .transcribe: 30], meetingSeconds: 600)
        let estimate = ProcessingEstimate(
            steps: [.save, .transcribe], current: .transcribe, secondsInStep: 15, reported: nil,
            history: history, meetingSeconds: 600)
        #expect(estimate.segments.map(\.share) == [0.25, 0.75])
        #expect(estimate.overall == 0.25 + 0.75 * 0.5)
        #expect(estimate.secondsLeft == 15)
    }

    @Test("each track fills its share of the step")
    func tracksShareTheStep() {
        let second = TrackShare(index: 1, count: 2)
        #expect(second.of(0) == 0.5)
        #expect(second.of(0.5) == 0.75)
        #expect(TrackShare.whole.of(0.3) == 0.3)
    }
}

/// How the runtime times the steps of a run.
@Suite("Processing step clock")
struct ProcessingStepClockTests {
    @Test("a run watched from the start gives each step's time, waiting left out")
    func timesEachStep() {
        var clock = ProcessingStepClock()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = clock.observe(progress(.audioSafe), at: start)
        _ = clock.observe(
            progress(.audioSafe, detail: ProcessingPipeline.Progress.waitingForOtherMeeting, isWaiting: true),
            at: start.addingTimeInterval(2))
        _ = clock.observe(progress(.audioSafe), at: start.addingTimeInterval(62))
        _ = clock.observe(progress(.transcribing, step: .removeEcho), at: start.addingTimeInterval(63))
        _ = clock.observe(progress(.transcribing), at: start.addingTimeInterval(183))
        _ = clock.observe(progress(.diarizing, fraction: 0.5), at: start.addingTimeInterval(213))
        let times = clock.observe(progress(.complete), at: start.addingTimeInterval(263))
        #expect(times == [.save: 3, .removeEcho: 120, .transcribe: 30, .identifySpeakers: 50])
        #expect(clock.running.isEmpty)
    }

    @Test("a run picked up partway through is not learned from")
    func partialRunsAreNotTimed() {
        var clock = ProcessingStepClock()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = clock.observe(progress(.diarizing), at: start)
        #expect(clock.observe(progress(.complete), at: start.addingTimeInterval(60)) == nil)
    }

    @Test("a run that failed is forgotten, so its retry is not learned from")
    func failedRunsAreForgotten() {
        var clock = ProcessingStepClock()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = clock.observe(progress(.audioSafe), at: start)
        _ = clock.observe(progress(.diarizing), at: start.addingTimeInterval(10))
        clock.forget("m")
        _ = clock.observe(progress(.diarizing), at: start.addingTimeInterval(20))
        #expect(clock.observe(progress(.complete), at: start.addingTimeInterval(30)) == nil)
    }

    @Test("the furthest fraction is kept and the step's seconds leave out waiting")
    func reachedAndSeconds() throws {
        var clock = ProcessingStepClock()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = clock.observe(progress(.transcribing, fraction: 0.6), at: start)
        _ = clock.observe(progress(.transcribing, chunks: (1, 10)), at: start.addingTimeInterval(5))
        _ = clock.observe(
            progress(.transcribing, detail: ProcessingPipeline.Progress.waitingForRecording, isWaiting: true),
            at: start.addingTimeInterval(10))
        let entry = try #require(clock.running["m"])
        #expect(entry.reached == 0.6)
        #expect(entry.secondsInStep(at: start.addingTimeInterval(100)) == 10)
    }
}

/// A meeting's archive with one recording, for the window tests below.
@MainActor
enum ProcessingArchive {
    struct Built {
        let runtime: PipitRuntime
        let store: MeetingStore
        let id: String
        let clock: ManualClock
    }

    /// - Parameter history: step times to start from, as a Mac that has
    ///   processed meetings before would have.
    static func make(root: URL, history: ProcessingTimeHistory = ProcessingTimeHistory()) throws -> Built {
        let archive = root.appendingPathComponent("Meetings")
        let made = try PipelineFixtures.makeRecordedMeeting(root: archive, cleaning: .notYetRun)
        try ProcessingTimeStore(directory: root).save(history)
        let clock = ManualClock()
        let runtime = PipitRuntime(settingsDirectory: root, clock: clock)
        var settings = runtime.settings
        settings.storageRootPath = archive.path
        settings.showNotifications = false
        runtime.update(settings: settings)
        return Built(runtime: runtime, store: made.store, id: made.metadata.id, clock: clock)
    }

    /// A Mac that has timed a few 30-minute meetings, about as fast as the one
    /// these numbers came from.
    static var timedHistory: ProcessingTimeHistory {
        var history = ProcessingTimeHistory()
        for _ in 0..<ProcessingTimeHistory.runsBeforeTimeLeft {
            history.record(
                [.save: 3, .removeEcho: 122, .transcribe: 30, .identifySpeakers: 148, .matchNames: 5, .writeNotes: 15],
                meetingSeconds: 1_815)
        }
        return history
    }

    /// Puts the meeting at a stage the way a run in progress leaves it, then
    /// lets `thenWait` seconds pass on the runtime's clock.
    static func move(
        _ built: Built, to state: ProcessingState, step: ProcessingStep? = nil, fraction: Double? = nil,
        detail: String? = nil, isWaiting: Bool = false, thenWait: Double = 0
    ) throws {
        _ = try built.store.updateMetadata {
            $0.titles = TitleCandidates(provider: "Weekly sync", timestampFallback: "f")
            $0.durationSeconds = 1_815
            $0.processing = ProcessingStatus(state: state, updatedAt: $0.startedAt)
        }
        built.runtime.apply(
            ProcessingPipeline.Progress(
                meetingID: built.id, state: state, completedChunks: 0, totalChunks: 0,
                title: "Weekly sync", fraction: fraction, detail: detail, step: step, isWaiting: isWaiting))
        built.clock.advance(thenWait)
    }

    /// The transcript the speaker step writes, before notes are generated.
    static func writeTranscript(_ store: MeetingStore) throws {
        let lines = [
            (SpeakerLabel.localUser, CaptureTrack.mic, "Shall we start with the release checklist?"),
            ("remote-001_speaker_00", .remote, "Sure. The build is green and the release notes are drafted."),
            (SpeakerLabel.localUser, .mic, "Is the migration tested on the staging copy?"),
            ("remote-001_speaker_01", .remote, "Yes, it ran last night in about four minutes."),
        ]
        let utterances = lines.enumerated().map { index, line in
            Utterance(
                id: "u\(index)", start: Double(index) * 12, end: Double(index) * 12 + 10,
                track: line.1, rawSpeakerLabel: line.0, speakerKey: line.0,
                text: line.2, chunkID: "c1", model: "m")
        }
        try store.writeCanonicalTranscript(CanonicalTranscript(generatedAt: Date(), utterances: utterances))
    }

    static func open(_ id: String, in model: MeetingsWindowModel) async throws {
        await model.reload()
        model.select(id, extending: false)
        model.tab = .transcript
        model.detail?.reload()
        for _ in 0..<40 where model.detail?.combinedLines.isEmpty ?? true {
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// The transcript is readable once the speaker step has written it, while the
/// notes and summary are still being generated.
@Suite("Processing steps window")
@MainActor
struct ProcessingStepsWindowTests {
    @Test("the transcript opens while notes are still being written")
    func transcriptOpensBeforeNotes() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let built = try ProcessingArchive.make(root: root)
        try ProcessingArchive.writeTranscript(built.store)
        try ProcessingArchive.move(built, to: .enriching)
        let model = MeetingsWindowModel(runtime: built.runtime)
        try await ProcessingArchive.open(built.id, in: model)
        #expect(model.detail?.combinedLines.count == 4, "the pane shows the steps instead of the words")
    }

    @Test("a run watched from the start is saved as this Mac's step times")
    func finishedRunsAreRemembered() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let built = try ProcessingArchive.make(root: root)
        try ProcessingArchive.move(built, to: .audioSafe, thenWait: 5)
        try ProcessingArchive.move(built, to: .transcribing, thenWait: 60)
        try ProcessingArchive.move(built, to: .complete)
        #expect(built.runtime.processingTimes.completedRuns == 1)
        #expect(ProcessingTimeStore(directory: root).load().completedRuns == 1)
    }
}

/// The meetings window at each processing step, dark and light, for a person
/// to look at with `PIPIT_RENDER_DIR` set. The last one has its transcript,
/// which replaces the steps while notes are written.
@Suite("Processing steps drawings", .tags(.slow))
@MainActor
struct ProcessingStepsDrawingTests {
    @Test("the window lays out at every processing step")
    func everyStepLaysOut() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let built = try ProcessingArchive.make(root: root, history: ProcessingArchive.timedHistory)
        let model = MeetingsWindowModel(runtime: built.runtime)
        let moments: [(name: String, apply: () throws -> Void)] = [
            (
                "waiting",
                {
                    try ProcessingArchive.move(
                        built, to: .audioSafe, detail: ProcessingPipeline.Progress.waitingForOtherMeeting,
                        isWaiting: true)
                }
            ),
            ("echo", { try ProcessingArchive.move(built, to: .transcribing, step: .removeEcho, thenWait: 70) }),
            ("words", { try ProcessingArchive.move(built, to: .transcribing, thenWait: 12) }),
            (
                "loading",
                {
                    try ProcessingArchive.move(
                        built, to: .diarizing, detail: ProcessingPipeline.Progress.loadingSpeakerModel,
                        thenWait: 40)
                }
            ),
            ("speakers", { try ProcessingArchive.move(built, to: .diarizing, fraction: 0.6, thenWait: 110) }),
            (
                "notes",
                {
                    try ProcessingArchive.writeTranscript(built.store)
                    try ProcessingArchive.move(built, to: .enriching)
                }
            ),
        ]
        for moment in moments {
            try moment.apply()
            try await ProcessingArchive.open(built.id, in: model)
            for (look, appearance) in WindowRender.looks {
                try await WindowRender.render(
                    MeetingsWindowView(model: model), size: CGSize(width: 1_100, height: 720),
                    appearance: appearance, name: "processing-\(moment.name)-\(look)")
            }
        }
    }
}

/// The line under Processing in the menu bar.
@Suite("Processing menu line")
struct ProcessingMenuLineTests {
    @Test("a waiting meeting says why, and a step says how far it has got")
    func menuLine() {
        #expect(
            MenuBarController.processingLine(
                progress(.audioSafe, detail: ProcessingPipeline.Progress.waitingForOtherMeeting, isWaiting: true))
                == ProcessingPipeline.Progress.waitingForOtherMeeting)
        #expect(MenuBarController.processingLine(progress(.transcribing, chunks: (3, 10))) == "Transcribing 30%")
        #expect(MenuBarController.processingLine(progress(.diarizing)) == "Identifying speakers")
    }
}

/// The steps a real run reports, in the order it reports them.
@Suite("Processing step order")
struct ProcessingStepOrderTests {
    /// The stage-start report named transcription before the cleaner named
    /// echo removal, so the steps went back. The pane ticked echo removal off
    /// and returned to it, and the step clock threw away every call's timings.
    @Test("a call's run reports its steps in order, echo removal first", .timeLimit(.minutes(2)))
    func stepsOnlyMoveForward() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try MicrophoneCleaningFixtures.makeCallOnSpeakers(root: root)
        let transcriber = StubLocalTranscriber(segments: [
            RawTranscriptSegment(
                start: 0, end: 5, text: "we ship friday", speaker: nil,
                words: [RawTranscriptWord(start: 0, end: 0.3, text: " we")])
        ])
        let diarizer = StubLocalDiarizer(
            intervals: [DiarizationInterval(start: 0, end: 2, clusterID: "S1")], chunkEmbeddings: [])
        var settings = AppSettings()
        settings.enrichment = EnrichmentSettings(
            generateTitle: false, generateDescription: false, generateNotes: false,
            generateSummary: false, suggestSpeakers: false)
        let steps = Mutex<[ProcessingStep]>([])
        let pipeline = PipelineFixtures.makePipeline(
            repository: meeting.repository, backend: FakeAIBackend(),
            transcriber: transcriber, diarizer: diarizer, speakers: nil,
            settings: settings, scratchRoot: root.appendingPathComponent("scratch"),
            onProgress: { report in
                guard let step = report.step else { return }
                steps.withLock { if $0.last != step { $0.append(step) } }
            })
        await pipeline.process(meetingID: meeting.metadata.id)
        let seen = steps.withLock { $0 }
        #expect(seen.first(where: { $0 > .save }) == .removeEcho, "steps: \(seen)")
        #expect(seen == seen.sorted(), "steps went back: \(seen)")
    }
}
