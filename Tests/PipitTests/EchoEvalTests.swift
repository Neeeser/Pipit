import Foundation
import PipitCore
import PipitServices
import Testing

/// What `pipit-eval echo` measures, on fixtures whose echo path is known.
///
/// The fixtures are speech from the system synthesiser, because the canceller
/// that ships is a network trained on speech and takes a tone for something to
/// remove. They pin the arithmetic, the classification and the decision on a
/// call whose timing is known. Numbers on real recordings come from running
/// the command over them, which no test does.
@Suite("EchoEval")
struct EchoEvalTests {
    private static let rate = MicrophoneCleaningFixtures.rate
    /// Seconds of fixture. Long enough that the far end is above the floor in
    /// more than the forty windows the cleaner's decision needs.
    private static let seconds = 32.0
    /// The room noise a real capsule always has, well under the -60 dBFS floor
    /// the classification uses. Digital silence would make every quiet window
    /// read -120 dBFS and would hide what the canceller does to a microphone
    /// that holds nothing.
    private static let noiseTone = 3_100.0
    private static let noiseAmplitude: Float = 0.0003

    // MARK: - fixtures

    /// A call whose far end talks in two bursts, so the pair can be moved.
    ///
    /// The far end talks over its own seconds 0 to 8 and 18 to 26, which land
    /// in the microphone two seconds later. The user talks over microphone
    /// seconds 12 to 18, where the far end is quiet, and again over 21 to 27,
    /// where it is not. That gives one stretch of the user alone and one of
    /// both at once, which is the split the retention figures are reported on.
    /// Both voices pause between sentences, so a stretch holds fewer active
    /// windows than its length says.
    ///
    /// `micHoldsEcho` false is the same call taken on headphones: the far end
    /// plays and nothing of it comes back to the capsule.
    private static func makeBurstyCall(
        root: URL, micHoldsEcho: Bool = true, userSpeaks: Bool = true,
        remoteStartOffset: Double = 2, roomNoise: Float = noiseAmplitude
    ) throws -> (metadata: MeetingMetadata, store: MeetingStore, repository: MeetingRepository) {
        let count = Int(seconds * rate)
        let farText = MicrophoneCleaningFixtures.farText
        var remote = [Float](repeating: 0, count: count)
        // The second burst picks up where the first left off, so the two
        // do not read the same sentences.
        for (from, upTo, texts) in [
            (0.0, 8.0, farText), (18.0, 26.0, Array(farText[2...] + farText[..<2])),
        ] {
            let burst = MicrophoneCleaningFixtures.talking(
                voice: MicrophoneCleaningFixtures.farVoice, texts: texts, count: Int((upTo - from) * rate)
            )
            for index in 0..<burst.count { remote[Int(from * rate) + index] = burst[index] }
        }

        var mic = MicrophoneCleaningFixtures.tone(
            count: count, frequency: noiseTone, amplitude: roomNoise
        )
        if userSpeaks {
            let userText = MicrophoneCleaningFixtures.userText
            for (from, upTo, texts) in [
                (12.0, 18.0, userText), (21.0, 27.0, Array(userText[1...] + userText[..<1])),
            ] {
                let user = MicrophoneCleaningFixtures.talking(
                    voice: MicrophoneCleaningFixtures.userVoice, texts: texts, count: Int((upTo - from) * rate)
                )
                for index in 0..<user.count { mic[Int(from * rate) + index] += user[index] }
            }
        }
        if micHoldsEcho {
            let shift = Int(remoteStartOffset * rate) + MicrophoneCleaningFixtures.echoDelaySamples
            for index in max(0, shift)..<count {
                mic[index] += MicrophoneCleaningFixtures.echoGain * remote[index - shift]
            }
        }
        return try MicrophoneCleaningFixtures.makeMeeting(
            root: root, mic: mic, remote: remote, remoteStartOffset: remoteStartOffset
        )
    }

    /// Every file under a meeting folder, with its size. The command is
    /// read-only on the archive, and this is what says so.
    private static func contents(of root: URL) -> [String: Int] {
        var out: [String: Int] = [:]
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            out[url.path.replacingOccurrences(of: root.path, with: "")] = size
        }
        return out
    }

    private static func summary(
        _ report: EchoMeasurement.Report, _ windowClass: EchoMeasurement.WindowClass
    ) -> EchoMeasurement.ClassSummary {
        report.summary(windowClass)
    }

    @Test("a call on speakers reports the user surviving and the far end leaving")
    func aCallOnSpeakersReportsTheUserSurvivingAndTheFarEndLeaving() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try Self.makeBurstyCall(root: root)
        let measurement = try EchoMeasurement.measure(
            store: meeting.store, metadata: meeting.metadata,
            timeline: try meeting.store.readTimeline()
        )
        guard case .measured(let report) = measurement else {
            Issue.record("a two-track call came back \(measurement)")
            return
        }

        #expect(report.decision == CleaningOutcome.cleaned)
        #expect(
            abs((report.seconds) - (Self.seconds)) <= 0.2,
            "expected \(Self.seconds) ± \(0.2), got \(report.seconds)"
        )

        // The far end talks for sixteen of the thirty-two seconds, less the
        // pauses between its sentences.
        #expect(
            report.farEndDutyCycle > 0.4 && report.farEndDutyCycle <= 0.5,
            "the far end was active in \(report.farEndDutyCycle) of the windows"
        )
        #expect(
            report.farEndActiveWindows
                == Self.summary(report, .farEndOnly).windows + Self.summary(report, .both).windows,
            "far-end-active is the two classes the far end is above its floor in"
        )

        // This fixture's room tone sits under the far end's floor, so that
        // floor is the one that decided the microphone's.
        let microphoneQuietWindowDBFS = try #require(report.microphoneQuietWindowDBFS)
        #expect(
            abs(microphoneQuietWindowDBFS - (-73.5)) <= 0.5,
            "expected -73.5 ± 0.5, got \(microphoneQuietWindowDBFS)"
        )
        #expect(report.microphoneFloorDBFS == report.farEndFloorDBFS)

        // A speaker call has no far-end-only windows. The echo keeps the
        // microphone above its floor for every window the far end talks
        // in, and levels alone cannot tell that echo from the user. This is
        // the limit the retention figures are split around.
        #expect(Self.summary(report, .farEndOnly).windows == 0)
        #expect(
            Self.summary(report, .farEndOnly).changeDB == nil,
            "a class with no windows reports no level rather than zero"
        )
        #expect(Self.summary(report, .farEndOnly).worstChangeDB == nil)

        // The user alone, with the far end quiet: the 24 windows of 12 to
        // 18 s less the user's own pauses, plus the far end's pauses under
        // 21 to 27 s. This is the class the decision is made on, and the
        // class a level drop is a loss in. Across the class the microphone
        // moved 0.0005 dB and the window ninety-five in a hundred stayed
        // under moved 0.75 dB.
        //
        // The single window over the loss threshold is the one at 11.75 s,
        // which reads -29 dBFS before and -74 dBFS after. The recording
        // holds only room tone there: the user starts at 12.0 s. The pass
        // pairs each cleaned sample with the recording 24 ms later than it,
        // which is the canceller's output delay, so the user's first 24 ms
        // land in the window before their own. That window reads as a loss
        // of 44.5 dB, and the fault is in `EchoCancellationPass.run`, not
        // in what the canceller did to the user.
        let solo = Self.summary(report, .userOnly)
        #expect(
            solo.windows >= report.minimumUserWindows && solo.windows <= 30,
            "the user alone held \(solo.windows) windows"
        )
        let changeDB = try #require(solo.changeDB)
        #expect(abs(changeDB) <= 0.5, "the user alone moved \(changeDB) dB across the class")
        // The network takes a hop or two to open on a voice that starts from
        // silence, so the first quarter second of each of the user's two
        // turns can come down. Two windows out of twenty-odd, which the
        // judge's own rule of one in ten allows; the median and the class
        // ratio above say the user was left alone.
        #expect(
            solo.windowsOverLossThreshold <= 2,
            "\(solo.windowsOverLossThreshold) of the user's own windows lost more than 6 dB"
        )

        // And the log is what lets a run be re-read later without being
        // measured again, so the summary has to be recoverable from it.
        let soloLog = report.windowLog.filter { $0.windowClass == .userOnly }
        #expect(soloLog.count == solo.windows)
        #expect(
            soloLog.filter { $0.changeDB > report.notableLossDB }.count == solo.windowsOverLossThreshold
        )
        #expect(report.windowLog.count == report.windowCount)
        #expect(
            abs((report.windowLog[1].startSeconds) - (report.windowSeconds)) <= 0.001,
            "expected \(report.windowSeconds) ± \(0.001), got \(report.windowLog[1].startSeconds)"
        )

        // Both at once, which on speakers is every window the far end talks
        // in. The class ratio understates what left: the six seconds of
        // retained user speech under 21 to 27 s carry most of the energy,
        // so the class reads 0.8 dB while the median window gave up 27.1 dB
        // of echo and 42 of the 62 windows lost more than 6 dB. The median
        // window is the figure that answers how much of the far end came
        // out.
        let together = Self.summary(report, .both)
        #expect(together.windows == report.farEndActiveWindows)
        #expect(together.windows <= 64, "the far end talks for sixteen seconds")
        let togetherChangeDB = try #require(together.changeDB)
        let togetherMedianDB = try #require(together.medianChangeDB)
        #expect(togetherMedianDB > 15, "the median far-end window came down only \(togetherMedianDB) dB")
        #expect(togetherMedianDB > togetherChangeDB, "the ratio hides what the windows lost")
        #expect(
            together.windowsOverLossThreshold >= together.windows - 24,
            "\(together.windowsOverLossThreshold) of \(together.windows) far-end windows lost more than 6 dB"
        )

        // The user alone was left alone, which is what the decision is
        // made on.
        let harm = try #require(report.userHarmMedianDB)
        #expect(harm < report.harmMedianLimitDB, "the user's own windows lost \(harm) dB")
        #expect(report.userWindowsJudged >= report.minimumUserWindows)
    }

    @Test("a call on headphones is kept cleaned when the user is left alone")
    func aCallOnHeadphonesIsKeptCleanedWhenTheUserIsLeftAlone() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try Self.makeBurstyCall(root: root, micHoldsEcho: false)
        let measurement = try EchoMeasurement.measure(
            store: meeting.store, metadata: meeting.metadata,
            timeline: try meeting.store.readTimeline()
        )
        guard case .measured(let report) = measurement else {
            Issue.record("a two-track call came back \(measurement)")
            return
        }

        // There was nothing to remove. What decides is that the user's own
        // windows came through untouched, so the cleaned track is as good as
        // the recording and is kept.
        #expect(report.decision == CleaningOutcome.cleaned)
        let harm = try #require(report.userHarmMedianDB)
        #expect(abs(harm) < 0.5, "the user's own windows moved \(harm) dB")

        // With no echo returning, the far end talks over a microphone that
        // holds only room noise, and those windows are far-end-only. This
        // is the class a speaker call cannot populate: the far end's
        // sixteen seconds less the windows the user talks in under 21 to
        // 27 s.
        let farOnly = Self.summary(report, .farEndOnly)
        #expect(
            farOnly.windows >= 24 && farOnly.windows <= 48, "far-end-only held \(farOnly.windows) windows"
        )
        #expect(farOnly.windows + Self.summary(report, .both).windows == report.farEndActiveWindows)

        // The user is untouched here, by the ratio and window by window
        // both. A canceller with no echo to find has nothing to subtract.
        // Across each class the microphone moved under 0.01 dB and the
        // median window under 0.02 dB.
        //
        // Two windows read as losses. At 11.75 s and at 20.75 s the
        // recording holds room tone and the user starts 250 ms later, at
        // 12.0 s and 21.0 s. The pass pairs each cleaned sample with the
        // recording 24 ms later than it, the canceller's output delay, so
        // the user's first 24 ms land in the window before their own and
        // that window reads as 44.8 dB and 35.9 dB lost. The fault is in
        // `EchoCancellationPass.run`. One more window, at 26.25 s, is the
        // canceller's own: the user talking under the far end came out
        // 5.9 dB down for that quarter second.
        for windowClass in [EchoMeasurement.WindowClass.userOnly, .both] {
            let held = Self.summary(report, windowClass)
            let changeDB = try #require(held.changeDB)
            #expect(
                abs(changeDB) < 0.5,
                "\(windowClass) moved \(String(describing: held.changeDB)) dB"
            )
            let medianChangeDB = try #require(held.medianChangeDB)
            #expect(
                abs(medianChangeDB) < 0.5,
                "\(windowClass) median window moved \(medianChangeDB) dB"
            )
            #expect(
                held.windowsOverLossThreshold == 0,
                """
                \(held.windowsOverLossThreshold) \(windowClass) windows lost more than 6 dB, \
                the worst \(String(describing: held.worstChangeDB)) dB
                """
            )
        }
    }

    @Test("a room louder than the far end's floor gets a floor of its own")
    func aRoomLouderThanTheFarEndSFloorGetsAFloorOfItsOwn() async throws {
        // A real capsule records the room. Where its tone sits above
        // -60 dBFS, borrowing the far end's floor would call every window
        // microphone-active: `farEndOnly` and `neither` would come back
        // empty on every meeting, `userOnly` would stop meaning "the user
        // spoke", and what the canceller does to a room would never appear
        // in a table. Room tone here is -44.9 dBFS, which is that regime.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try Self.makeBurstyCall(root: root, micHoldsEcho: false, roomNoise: 0.008)
        let measurement = try EchoMeasurement.measure(
            store: meeting.store, metadata: meeting.metadata,
            timeline: try meeting.store.readTimeline()
        )
        guard case .measured(let report) = measurement else {
            Issue.record("a two-track call came back \(measurement)")
            return
        }

        let quiet = try #require(report.microphoneQuietWindowDBFS)
        #expect(abs((quiet) - (-44.9)) <= 0.5, "expected -44.9 ± 0.5, got \(quiet)")
        #expect(
            quiet > report.farEndFloorDBFS,
            "this room tone at \(quiet) dBFS has to sit above the far end's floor"
        )
        #expect(
            abs((report.microphoneFloorDBFS) - (quiet + EchoMeasurement.microphoneActivationMarginDB)) <= 0.001,
            """
            expected \(quiet + EchoMeasurement.microphoneActivationMarginDB) ± 0.001, \
            got \(report.microphoneFloorDBFS)
            """
        )

        // The counterfactual, measured rather than argued: with the far
        // end's floor every window would have been microphone-active.
        #expect(
            report.windowLog.filter { $0.microphoneBeforeDBFS > report.farEndFloorDBFS }.count == report.windowCount,
            "every window clears -60 dBFS in this room"
        )
        // With the derived floor the two quiet classes are populated:
        // far-end-only from the far end's sixteen seconds less the windows
        // the user talks in under 21 to 27 s, and neither from at least the
        // eight seconds nobody talks in, 10 to 12, 18 to 20 and 28 to 32.
        let farOnly = Self.summary(report, .farEndOnly)
        #expect(
            farOnly.windows >= 24 && farOnly.windows <= 48, "far-end-only held \(farOnly.windows) windows"
        )
        #expect(farOnly.windows + Self.summary(report, .both).windows == report.farEndActiveWindows)
        #expect(Self.summary(report, .neither).windows >= 32)

        // And what the canceller does to a microphone holding only room
        // tone under a playing far end is then visible: a steady tone is
        // not speech to it, and the class comes down 20.5 dB with the
        // median window down 29.1 dB.
        let medianChangeDB = try #require(farOnly.medianChangeDB)
        #expect(medianChangeDB > 10, "the room tone under the far end moved \(medianChangeDB) dB")
    }

    @Test("a far end that holds nothing reports no reference, not zero removal")
    func aFarEndThatHoldsNothingReportsNoReferenceNotZeroRemoval() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let count = Int(15 * Self.rate)
        let meeting = try MicrophoneCleaningFixtures.makeMeeting(
            root: root,
            mic: MicrophoneCleaningFixtures.tone(
                count: count, frequency: MicrophoneCleaningFixtures.nearTone, amplitude: 0.3
            ),
            remote: [Float](repeating: 0, count: count)
        )
        let measurement = try EchoMeasurement.measure(
            store: meeting.store, metadata: meeting.metadata,
            timeline: try meeting.store.readTimeline()
        )
        #expect(
            measurement == EchoMeasurement.noReference(.recordedSilence),
            "a tap that opened and recorded nothing has no reference to subtract"
        )
    }

    @Test("a recording holding everyone on one track reports no reference")
    func aRecordingHoldingEveryoneOnOneTrackReportsNoReference() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let count = Int(2 * Self.rate)
        let meeting = try MicrophoneCleaningFixtures.makeMeeting(
            root: root, source: .imported,
            mic: MicrophoneCleaningFixtures.tone(
                count: count, frequency: MicrophoneCleaningFixtures.nearTone, amplitude: 0.3
            ),
            remote: nil
        )
        let measurement = try EchoMeasurement.measure(
            store: meeting.store, metadata: meeting.metadata,
            timeline: try meeting.store.readTimeline()
        )
        #expect(measurement == EchoMeasurement.noReference(.oneTrack))
    }

    @Test("measuring leaves the meeting folder exactly as it found it")
    func measuringLeavesTheMeetingFolderExactlyAsItFoundIt() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try Self.makeBurstyCall(root: root)
        let folder = meeting.store.layout.root
        let before = Self.contents(of: folder)
        #expect(before.count > 3, "the fixture wrote something to compare against")

        _ = try EchoMeasurement.measure(
            store: meeting.store, metadata: meeting.metadata,
            timeline: try meeting.store.readTimeline()
        )

        #expect(Self.contents(of: folder) == before, "the command wrote into the meeting")
        #expect(
            !(FileManager.default.fileExists(
                atPath: meeting.store.layout.cleanedMicFile.path
            )), "no cleaned track was left behind")
        #expect(try meeting.store.readMetadata().cleanedMic == nil)
    }

    @Test("a reference offset given by hand replaces the one the timeline holds")
    func aReferenceOffsetGivenByHandReplacesTheOneTheTimelineHolds() async throws {
        // What Task 2 runs to show the threshold does not catch a
        // misaligned pair. The far end here talks in bursts, so moving it
        // moves the echo away from where the canceller is told to look for
        // it. A far end that never stops is the same far end after any
        // shift and would hide this.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try Self.makeBurstyCall(root: root)
        let timeline = try meeting.store.readTimeline()
        #expect(
            abs((EchoMeasurement.timelineReferenceOffset(timeline)) - (2)) <= 0.01,
            """
            expected 2 ± 0.01, got \(EchoMeasurement.timelineReferenceOffset(timeline)), \
            the far end started two seconds after the microphone
            """
        )

        func measure(offset: Double?) throws -> EchoMeasurement.Report? {
            let measurement = try EchoMeasurement.measure(
                store: meeting.store, metadata: meeting.metadata, timeline: timeline,
                referenceOffset: offset
            )
            guard case .measured(let report) = measurement else { return nil }
            return report
        }

        let aligned = try #require(try measure(offset: nil))
        #expect(!(aligned.referenceOffsetIsOverride))
        #expect(
            abs((aligned.referenceOffsetSeconds) - (2)) <= 0.01,
            "expected 2 ± 0.01, got \(aligned.referenceOffsetSeconds)"
        )

        let reversed = try #require(try measure(offset: -2))
        #expect(reversed.referenceOffsetIsOverride)
        #expect(
            abs((reversed.referenceOffsetSeconds) - (-2)) <= 0.01,
            "expected -2 ± 0.01, got \(reversed.referenceOffsetSeconds)"
        )

        // The far end is read through the offset, so a reversed one moves
        // the classification as well as the cancellation: the two tracks
        // are compared at moments that are not the same moment.
        #expect(
            Self.summary(reversed, .both).windows != Self.summary(aligned, .both).windows,
            "the classification moved with the far end"
        )

        // And the canceller has nothing to lock onto. The decision does not
        // read that, so a misaligned pair is caught by what the far end
        // lost, not by the outcome value.
        #expect(aligned.decision == CleaningOutcome.cleaned)
        let alignedFar = try #require(Self.summary(aligned, .both).medianChangeDB)
        let reversedFar = try #require(Self.summary(reversed, .both).medianChangeDB)
        #expect(
            alignedFar > reversedFar + 20,
            "aligned removed \(alignedFar) dB, reversed \(reversedFar) dB"
        )
    }

    @Test("the judgement keeps a pass that left the user alone and drops one that did not")
    func theJudgementKeepsAPassThatLeftTheUserAloneAndDropsOneThatDid() async throws {
        func window(far: Double, before: Double, after: Double) -> EchoCancellationPass.Window {
            EchoCancellationPass.Window(
                farEndDBFS: far, echoRemovedDB: 0, microphoneBeforeDBFS: before,
                microphoneAfterDBFS: after
            )
        }
        // Room tone, so the microphone has a floor to be judged against.
        let room = (0..<30).map { _ in window(far: -90, before: -80, after: -80) }
        // A call on speakers: the far end plays for most of it and the
        // user's own windows lose nothing.
        let speakers =
            (0..<60).map { _ in window(far: -25, before: -30, after: -55) }
            + (0..<30).map { _ in window(far: -90, before: -30, after: -30.3) } + room
        let kept = EchoCancellationPass.judge(windows: speakers)
        #expect(kept.outcome == CleaningOutcome.cleaned)
        #expect(kept.userWindows == 30)
        let userHarmMedianDB = try #require(kept.userHarmMedianDB)
        #expect(
            abs(userHarmMedianDB - (0.3)) <= 0.01,
            "expected 0.3 ± 0.01, got \(userHarmMedianDB)"
        )

        // The same call with the user's solo speech gutted.
        let gutted =
            (0..<60).map { _ in window(far: -25, before: -30, after: -55) }
            + (0..<30).map { _ in window(far: -90, before: -30, after: -45) } + room
        let dropped = EchoCancellationPass.judge(windows: gutted)
        #expect(dropped.outcome == CleaningOutcome.bypassedNoEchoPath)
        let droppedHarmDB = try #require(dropped.userHarmMedianDB)
        #expect(
            abs(droppedHarmDB - (15)) <= 0.01,
            "expected 15 ± 0.01, got \(droppedHarmDB)"
        )

        // Enough gated windows is enough: the median holds and the share
        // does not.
        let tail =
            (0..<60).map { _ in window(far: -25, before: -30, after: -55) }
            + (0..<26).map { _ in window(far: -90, before: -30, after: -30) }
            + (0..<4).map { _ in window(far: -90, before: -30, after: -60) } + room
        #expect(
            EchoCancellationPass.judge(windows: tail).outcome == CleaningOutcome.bypassedNoEchoPath
        )

        // Too few user-only windows to judge harm on: kept.
        let brief =
            (0..<60).map { _ in window(far: -25, before: -30, after: -55) }
            + (0..<5).map { _ in window(far: -90, before: -30, after: -60) } + room
        let unjudged = EchoCancellationPass.judge(windows: brief)
        #expect(unjudged.outcome == CleaningOutcome.cleaned)
        #expect(unjudged.userHarmMedianDB == nil)

        // Too little far end to have been judged on at all.
        let quiet =
            (0..<10).map { _ in window(far: -25, before: -30, after: -55) }
            + (0..<60).map { _ in window(far: -90, before: -30, after: -30) } + room
        #expect(
            EchoCancellationPass.judge(windows: quiet).outcome == CleaningOutcome.skippedNoReference
        )
    }

}
