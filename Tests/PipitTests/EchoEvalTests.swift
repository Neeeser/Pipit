import Foundation
import PipitCore
import PipitServices
import Testing

/// What `pipit-eval echo` measures, on fixtures whose echo path is known.
///
/// The command exists because every number supporting the canceller so far
/// came from a continuous tone. These fixtures are still tones, so they pin
/// the arithmetic and the classification rather than the canceller's behaviour
/// on speech. Speech numbers come from running the command over real
/// recordings, which no test does.
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

    /// A call whose far end plays in bursts, so the pair can be moved.
    ///
    /// The far end plays over its own seconds 0 to 8 and 18 to 26, which land
    /// in the microphone two seconds later. The user talks over microphone
    /// seconds 12 to 18, where the far end is quiet, and again over 21 to 27,
    /// where it is not. That gives one stretch of the user alone and one of
    /// both at once, which is the split the retention figures are reported on.
    ///
    /// `micHoldsEcho` false is the same call taken on headphones: the far end
    /// plays and nothing of it comes back to the capsule.
    private static func makeBurstyCall(
        root: URL, micHoldsEcho: Bool = true, userSpeaks: Bool = true,
        remoteStartOffset: Double = 2, roomNoise: Float = noiseAmplitude
    ) throws -> (metadata: MeetingMetadata, store: MeetingStore, repository: MeetingRepository) {
        let count = Int(seconds * rate)
        var remote = MicrophoneCleaningFixtures.tone(
            count: count, frequency: MicrophoneCleaningFixtures.farToneA, amplitude: 0.5
        )
        for index in 0..<count {
            let at = Double(index) / rate
            let playing = (at >= 0 && at < 8) || (at >= 18 && at < 26)
            if !playing { remote[index] = 0 }
        }

        var mic = MicrophoneCleaningFixtures.tone(
            count: count, frequency: noiseTone, amplitude: roomNoise
        )
        if userSpeaks {
            for (from, upTo) in [(12.0, 18.0), (21.0, 27.0)] {
                let user = MicrophoneCleaningFixtures.tone(
                    count: count, frequency: MicrophoneCleaningFixtures.nearTone, amplitude: 0.3,
                    from: Int(from * rate), upTo: Int(upTo * rate)
                )
                for index in 0..<count { mic[index] += user[index] }
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

        // The far end plays for sixteen of the thirty-two seconds.
        #expect(
            abs((report.farEndDutyCycle) - (0.5)) <= 0.05,
            "expected 0.5 ± 0.05, got \(report.farEndDutyCycle)"
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
        // microphone above its floor for every second the far end plays,
        // and levels alone cannot tell that echo from the user. This is
        // the limit the retention figures are split around.
        #expect(Self.summary(report, .farEndOnly).windows == 0)
        #expect(
            Self.summary(report, .farEndOnly).changeDB == nil,
            "a class with no windows reports no level rather than zero"
        )
        #expect(Self.summary(report, .farEndOnly).worstChangeDB == nil)

        // The user alone, with the far end quiet, is where a class-level
        // power ratio is at its most misleading. Across the class the
        // microphone came down 0.007 dB, which reads as untouched. Two of
        // its twenty-six windows lost 36 dB, at the transition where the
        // far end stops and the suppressor is still gating. That is the
        // shape of the incident this work exists to stop repeating, and
        // the ratio alone does not show it.
        let solo = Self.summary(report, .userOnly)
        #expect(solo.windows == 26)
        let changeDB = try #require(solo.changeDB)
        #expect(
            abs(changeDB - (0)) <= 0.5,
            "expected 0 ± 0.5, got \(changeDB)"
        )
        let worstChangeDB = try #require(solo.worstChangeDB)
        #expect(
            abs(worstChangeDB - (36.5)) <= 2,
            "expected 36.5 ± 2, got \(worstChangeDB)"
        )
        let p95ChangeDB = try #require(solo.p95ChangeDB)
        #expect(
            abs(p95ChangeDB - (31.8)) <= 3,
            "expected 31.8 ± 3, got \(p95ChangeDB)"
        )
        #expect(solo.windowsOverLossThreshold == 2)

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

        // Both at once, where the same ratio understates in the other
        // direction. The class reads 3.2 dB because six seconds of
        // retained user tone carries most of the energy, while the median
        // window gave up 55 dB of echo. The per-window figure is the one
        // that answers how much of the far end left.
        let together = Self.summary(report, .both)
        #expect(together.windows == 64)
        let togetherChangeDB = try #require(together.changeDB)
        #expect(
            abs(togetherChangeDB - (3.2)) <= 0.5,
            "expected 3.2 ± 0.5, got \(togetherChangeDB)"
        )
        let togetherMedianDB = try #require(together.medianChangeDB)
        #expect(
            abs(togetherMedianDB - (54.7)) <= 3,
            "expected 54.7 ± 3, got \(togetherMedianDB)"
        )
        #expect(together.windowsOverLossThreshold == 40)

        let median = try #require(report.reportedEnhancementMedianDB)
        #expect(abs((median) - (48.5)) <= 2, "expected 48.5 ± 2, got \(median)")
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

        // The canceller reports almost nothing removed, because there was
        // nothing to remove. That figure decides nothing: what does is
        // that the user's own windows came through untouched, so the
        // cleaned track is as good as the recording and is kept.
        let median = try #require(report.reportedEnhancementMedianDB)
        #expect(abs((median) - (0.2)) <= 0.5, "expected 0.2 ± 0.5, got \(median)")
        #expect(report.decision == CleaningOutcome.cleaned)
        let harm = try #require(report.userHarmMedianDB)
        #expect(abs(harm) < 0.5, "the user's own windows moved \(harm) dB")

        // With no echo returning, the far end plays over a microphone that
        // holds only room noise, and those windows are far-end-only. This
        // is the class a speaker call cannot populate.
        let farOnly = Self.summary(report, .farEndOnly)
        #expect(farOnly.windows == 40)

        // Across the class the microphone comes back 29.1 dB louder than
        // it went in, which reads as a noise floor lifted throughout. The
        // per-window figures say otherwise: the median window moved 0.05 dB
        // and one window came back 45 dB louder. The canceller replaces
        // what it suppressed with comfort noise in a few windows, and the
        // power ratio spreads that over all of them.
        let changeDB = try #require(farOnly.changeDB)
        #expect(
            abs(changeDB - (-29.1)) <= 2,
            "expected -29.1 ± 2, got \(changeDB)"
        )
        let medianChangeDB = try #require(farOnly.medianChangeDB)
        #expect(
            abs(medianChangeDB - (-0.05)) <= 0.5,
            "expected -0.05 ± 0.5, got \(medianChangeDB)"
        )
        let largestGainDB = try #require(farOnly.largestGainDB)
        #expect(
            abs(largestGainDB - (-45.1)) <= 3,
            "expected -45.1 ± 3, got \(largestGainDB)"
        )
        #expect(farOnly.windowsOverLossThreshold == 0)

        // The user is untouched here, by the ratio and window by window
        // both. A filter that never locked on has nothing to subtract.
        for windowClass in [EchoMeasurement.WindowClass.userOnly, .both] {
            let held = Self.summary(report, windowClass)
            let changeDB = try #require(held.changeDB)
            #expect(
                abs(changeDB) < 0.5,
                "\(windowClass) moved \(String(describing: held.changeDB)) dB"
            )
            let worstChangeDB = try #require(held.worstChangeDB)
            #expect(
                abs(worstChangeDB) < 0.5,
                "\(windowClass) worst window \(String(describing: held.worstChangeDB)) dB"
            )
            #expect(held.windowsOverLossThreshold == 0)
        }
    }

    @Test("a room louder than the far end's floor gets a floor of its own")
    func aRoomLouderThanTheFarEndSFloorGetsAFloorOfItsOwn() async throws {
        // A real capsule records the room. Where its tone sits above
        // -60 dBFS, borrowing the far end's floor would call every window
        // microphone-active: `farEndOnly` and `neither` would come back
        // empty on every meeting, `userOnly` would stop meaning "the user
        // spoke", and the comfort noise above would never appear in a
        // table. Room tone here is -44.9 dBFS, which is that regime.
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
        // With the derived floor the two quiet classes are populated.
        #expect(Self.summary(report, .farEndOnly).windows == 40)
        #expect(Self.summary(report, .neither).windows == 40)

        // And what the canceller does to a microphone holding only room
        // tone is then visible. The class ratio reads -0.9 dB, which is
        // nothing, while thirty-seven of forty windows lost more than 6 dB.
        let farOnly = Self.summary(report, .farEndOnly)
        let changeDB = try #require(farOnly.changeDB)
        #expect(
            abs(changeDB - (-0.9)) <= 1,
            "expected -0.9 ± 1, got \(changeDB)"
        )
        let medianChangeDB = try #require(farOnly.medianChangeDB)
        #expect(
            abs(medianChangeDB - (14.3)) <= 2,
            "expected 14.3 ± 2, got \(medianChangeDB)"
        )
        #expect(farOnly.windowsOverLossThreshold == 37)
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
        #expect(!(FileManager.default.fileExists(
                atPath: meeting.store.layout.cleanedMicFile.path
            )), "no cleaned track was left behind")
        #expect(try meeting.store.readMetadata().cleanedMic == nil)
    }

    @Test("a reference offset given by hand replaces the one the timeline holds")
    func aReferenceOffsetGivenByHandReplacesTheOneTheTimelineHolds() async throws {
        // What Task 2 runs to show the threshold does not catch a
        // misaligned pair. The far end here plays in bursts, so moving it
        // moves the echo away from where the filter is told to look for
        // it. A far end that never stops is the same far end after any
        // shift and would hide this.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try Self.makeBurstyCall(root: root)
        let timeline = try meeting.store.readTimeline()
        #expect(
            abs((EchoMeasurement.timelineReferenceOffset(timeline)) - (2)) <= 0.01,
            """
            expected 2 ± 0.01, got \(EchoMeasurement.timelineReferenceOffset(timeline)) — \
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

        // And the filter has nothing to lock onto, which the reported
        // enhancement says: 48.5 dB aligned against 0.2 dB reversed. The
        // decision no longer reads that figure, so a misaligned pair is
        // caught by what the far end lost, not by the outcome value.
        let alignedMedian = try #require(aligned.reportedEnhancementMedianDB)
        let reversedMedian = try #require(reversed.reportedEnhancementMedianDB)
        #expect(alignedMedian > reversedMedian + 20, "\(alignedMedian) against \(reversedMedian)")
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
        let speakers = (0..<60).map { _ in window(far: -25, before: -30, after: -55) }
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
        let gutted = (0..<60).map { _ in window(far: -25, before: -30, after: -55) }
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
        let tail = (0..<60).map { _ in window(far: -25, before: -30, after: -55) }
            + (0..<26).map { _ in window(far: -90, before: -30, after: -30) }
            + (0..<4).map { _ in window(far: -90, before: -30, after: -60) } + room
        #expect(
            EchoCancellationPass.judge(windows: tail).outcome == CleaningOutcome.bypassedNoEchoPath
        )

        // Too few user-only windows to judge harm on: kept.
        let brief = (0..<60).map { _ in window(far: -25, before: -30, after: -55) }
            + (0..<5).map { _ in window(far: -90, before: -30, after: -60) } + room
        let unjudged = EchoCancellationPass.judge(windows: brief)
        #expect(unjudged.outcome == CleaningOutcome.cleaned)
        #expect(unjudged.userHarmMedianDB == nil)

        // Too little far end to have been judged on at all.
        let quiet = (0..<10).map { _ in window(far: -25, before: -30, after: -55) }
            + (0..<60).map { _ in window(far: -90, before: -30, after: -30) } + room
        #expect(
            EchoCancellationPass.judge(windows: quiet).outcome == CleaningOutcome.skippedNoReference
        )
    }

}
