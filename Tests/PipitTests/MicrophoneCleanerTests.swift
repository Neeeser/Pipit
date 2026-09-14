import AVFoundation
import Foundation
import PipitAudio
import PipitCore
import PipitServices
import Testing

/// The cleaned microphone track: what comes out of it, what it is called, and
/// the meetings it must refuse to touch.
///
/// The problem it solves, measured on a Slack huddle of 3 September 2026: 81%
/// of the words on the microphone were the far end's, arriving through the air
/// from the speakers. Every earlier attempt worked on the transcript, guessing
/// which words to delete, and deleted the local user's 3957 words instead.
///
/// Every fixture here is speech. The canceller that ships is a network trained
/// on speech, and it takes a steady tone for something to remove, so a tone
/// would measure the wrong thing on both sides: the far end would come down
/// with no echo path at all, and the user would be taken out with it.
@Suite("MicrophoneCleaner")
struct MicrophoneCleanerTests {
    /// The second, to a fiftieth of one, at which the user starts talking.
    ///
    /// The first 20 ms window past `after` whose broadband energy passes half
    /// of `steady`, the level the user holds once they are talking.
    private static func onset(of samples: [Float], after: Double, steady: Double) -> Double {
        let step = Int(0.02 * MicrophoneCleaningFixtures.rate)
        var index = Int(after * MicrophoneCleaningFixtures.rate)
        while index + step <= samples.count {
            let window = Array(samples[index..<(index + step)])
            if MicrophoneCleaningFixtures.energy(window) > steady / 2 {
                return Double(index) / MicrophoneCleaningFixtures.rate
            }
            index += step
        }
        return .infinity
    }

    /// The recording and the cleaned track, sample for sample.
    private static func rawAndClean(
        store: MeetingStore, timeline: RecordingTimeline
    ) throws -> (raw: [Float], clean: [Float]) {
        let metadata = try store.readMetadata()
        let raw = try MicrophoneCleaningFixtures.samples(
            store.rawTrackAudioLocation(track: .mic, metadata: metadata, timeline: timeline))
        let clean = try MicrophoneCleaningFixtures.samples(
            store.trackAudioLocation(track: .mic, metadata: metadata, timeline: timeline))
        return (raw, clean)
    }

    /// The tap's timestamps can run a few milliseconds behind the microphone's,
    /// so the manifest lines the far end up just after its own echo. On the
    /// Zoom call of 11 September 2026 the pair sat 2.4 ms the wrong way and the
    /// canceller then shipped took 10 dB off the far end where the same pass
    /// 30 ms either side took 30. The far end is handed over with a lead, and
    /// the canceller finds the lag itself.
    @Test("a far end that arrives ahead of the tap's clock still comes out")
    func aFarEndThatArrivesAheadOfTheTapsClockStillComesOut() async throws {
        // Both delays through the same fixture: the causal one says the
        // fixture can be cleaned at all, the other is the fault.
        for delay in [0.003, -0.0024] {
            let root = try TestPaths.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let meeting = try MicrophoneCleaningFixtures.makeCallOnSpeakers(
                root: root, echoDelaySeconds: delay
            )
            let store = meeting.store
            let timeline = try store.readTimeline()
            var carried = meeting.metadata
            let outcome = try MicrophoneCleaner().clean(
                store: store, metadata: &carried, timeline: timeline
            )
            #expect(outcome == CleaningOutcome.cleaned, "delay \(delay)")
            let (raw, clean) = try Self.rawAndClean(store: store, timeline: timeline)

            // The last ten seconds hold the far end alone.
            let removed = MicrophoneCleaningFixtures.dropDB(before: raw, after: clean, from: 20, to: 30)
            #expect(removed > 15, "at \(delay * 1000) ms the far end came down only \(removed) dB")

            // And 12 to 16 s hold the user alone.
            let lost = MicrophoneCleaningFixtures.dropDB(before: raw, after: clean, from: 12, to: 16)
            #expect(abs(lost) < 1.5, "at \(delay * 1000) ms the user's own voice moved \(lost) dB")
        }
    }

    @Test("the cleaned microphone loses the far end and keeps the user")
    func theCleanedMicrophoneLosesTheFarEndAndKeepsTheUser() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try MicrophoneCleaningFixtures.makeCallOnSpeakers(root: root)
        let store = meeting.store
        let timeline = try store.readTimeline()

        var carried = meeting.metadata
        let outcome = try MicrophoneCleaner().clean(
            store: store, metadata: &carried, timeline: timeline
        )
        #expect(outcome == CleaningOutcome.cleaned)
        #expect(
            FileManager.default.fileExists(atPath: store.layout.cleanedMicFile.path),
            "the cleaned track is on disk"
        )

        let metadata = try store.readMetadata()
        let cleaned = try #require(metadata.cleanedMic)
        #expect(cleaned.track.file == "mic.cleaned.m4a")
        #expect(cleaned.track.sampleRate == MicrophoneCleaningFixtures.rate)
        #expect(cleaned.track.channelCount == 1)
        #expect(
            abs((cleaned.track.seconds) - (30)) <= 0.2,
            "expected 30 ± 0.2, got \(cleaned.track.seconds)"
        )

        let (raw, clean) = try Self.rawAndClean(store: store, timeline: timeline)
        #expect(clean.count == raw.count, "the cleaned track runs as long as the recording")

        // The far end, over the last ten seconds, where the user has stopped
        // and the microphone holds only the echo. Measured at 46.4 dB.
        let removed = MicrophoneCleaningFixtures.dropDB(before: raw, after: clean, from: 20, to: 30)
        #expect(removed > 20, "the far end came down only \(removed) dB")

        // The user alone, over 12 to 16 s, where the far end pauses. This
        // is the number every earlier attempt got wrong. Measured at 0.03 dB.
        let lost = MicrophoneCleaningFixtures.dropDB(before: raw, after: clean, from: 12, to: 16)
        #expect(abs(lost) < 1.5, "the user's own voice moved \(lost) dB")

        // And the user talking across the far end, over 10 to 12 s and 16 to
        // 18 s. The echo carries a sixteenth of the energy there, so taking
        // all of it out moves the stretch by 0.3 dB, and anything past that
        // came out of the user. Measured at 0.24 and 0.27 dB.
        for (from, to) in [(10.0, 12.0), (16.0, 18.0)] {
            let both = MicrophoneCleaningFixtures.dropDB(before: raw, after: clean, from: from, to: to)
            #expect(both < 2, "over \(from) to \(to) s the user talking across the far end lost \(both) dB")
        }

        // And it sits on the same clock the recording does. An encoder that
        // put its own priming frames at the front would move every
        // timestamp in the transcript by that much. The user starts at 10 s,
        // and the level they hold over their first tenth of a second is what
        // their onset is found against: the far end's echo in the windows
        // before it sits at a third of that at its loudest.
        let steady = MicrophoneCleaningFixtures.energy(
            MicrophoneCleaningFixtures.seconds(10, 10.1, of: raw))
        let rawOnset = Self.onset(of: raw, after: 9.5, steady: steady)
        let cleanOnset = Self.onset(of: clean, after: 9.5, steady: steady)
        #expect(
            rawOnset >= 10 && rawOnset <= 10.05,
            "expected the user's onset at 10 s, got \(rawOnset)"
        )
        #expect(
            abs((cleanOnset) - (rawOnset)) <= 0.03,
            "expected \(rawOnset) ± \(0.03), got \(cleanOnset), within one 20 ms window"
        )
    }

    @Test("a microphone that lost audio mid-recording is lined up again and cleaned")
    func aMicrophoneThatLostAudioMidRecordingIsLinedUpAgainAndCleaned() async throws {
        // The manifest says when each track's first frame arrived, and a source
        // that stalls after that leaves a hole without changing it. On the
        // standup of 10 September 2026 the microphone ran 2.45 s ahead of the
        // far end for 31 minutes while the manifest reported the two tracks
        // starting 1.3 ms apart, and the canceller took 6.5 dB off the far end
        // where the same pass at the measured offset takes 15.3 dB.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try MicrophoneCleaningFixtures.makeSpokenCall(
            root: root, micLostSeconds: 2.45
        )
        let store = meeting.store
        let timeline = try store.readTimeline()

        var carried = meeting.metadata
        let outcome = try MicrophoneCleaner().clean(
            store: store, metadata: &carried, timeline: timeline
        )
        #expect(outcome == CleaningOutcome.cleaned)

        // The last twelve seconds hold the far end alone: the user stops at
        // 20 s. Measured at 56.2 dB.
        let (raw, clean) = try Self.rawAndClean(store: store, timeline: timeline)
        let removed = MicrophoneCleaningFixtures.dropDB(before: raw, after: clean, from: 28, to: 40)
        #expect(removed > 20, "the far end came down only \(removed) dB")
    }

    @Test("the far end is found where the recording holds it, not where the manifest says")
    func theFarEndIsFoundWhereTheRecordingHoldsItNotWhereTheManifestSays() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try MicrophoneCleaningFixtures.makeSpokenCall(
            root: root, micLostSeconds: 2.45
        )
        let timeline = try meeting.store.readTimeline()
        let fromTimeline = EchoMeasurement.timelineReferenceOffset(timeline)
        let measurement = try EchoMeasurement.measure(
            store: meeting.store, metadata: meeting.metadata, timeline: timeline
        )
        guard case .measured(let report) = measurement else {
            Issue.record("the pair was not measurable")
            return
        }
        #expect(report.measuredOffsetIsUsable)
        #expect(
            abs((report.measuredOffsetSeconds - fromTimeline) - (-2.45)) <= 0.02,
            """
            expected the far end moved -2.45 ± 0.02 s, \
            got \(report.measuredOffsetSeconds - fromTimeline)
            """
        )
        #expect(report.measuredOffsetCorrelation > report.timelineOffsetCorrelation)
        #expect(
            abs((report.referenceOffsetSeconds) - (report.measuredOffsetSeconds)) <= 0.001,
            "and the pass ran at the offset it measured"
        )
    }

    @Test("a recording already lined up is left where the manifest put it")
    func aRecordingAlreadyLinedUpIsLeftWhereTheManifestPutIt() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try MicrophoneCleaningFixtures.makeSpokenCall(root: root)
        let timeline = try meeting.store.readTimeline()
        let measurement = try EchoMeasurement.measure(
            store: meeting.store, metadata: meeting.metadata, timeline: timeline
        )
        guard case .measured(let report) = measurement else {
            Issue.record("the pair was not measurable")
            return
        }
        #expect(
            !report.measuredOffsetIsUsable,
            "the 3 ms across the desk is not worth moving a whole track for"
        )
        #expect(
            abs(
                (report.referenceOffsetSeconds)
                    - (EchoMeasurement.timelineReferenceOffset(timeline))) <= 0.001
        )
    }

    @Test("a call on headphones offers no echo path to line up against")
    func aCallOnHeadphonesOffersNoEchoPathToLineUpAgainst() async throws {
        // Two thirds of the recordings on disk are these. There is no peak to
        // find, so the loudest piece of noise must not be taken for one.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try MicrophoneCleaningFixtures.makeSpokenCall(root: root, micHoldsEcho: false)
        let timeline = try meeting.store.readTimeline()
        let measurement = try EchoMeasurement.measure(
            store: meeting.store, metadata: meeting.metadata, timeline: timeline
        )
        guard case .measured(let report) = measurement else {
            Issue.record("the pair was not measurable")
            return
        }
        #expect(!report.measuredOffsetIsUsable)
        #expect(
            abs(
                (report.referenceOffsetSeconds)
                    - (EchoMeasurement.timelineReferenceOffset(timeline))) <= 0.001
        )
    }

    @Test("a cleaned meeting reads the cleaned track and still reaches the raw one")
    func aCleanedMeetingReadsTheCleanedTrackAndStillReachesTheRawOne() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try MicrophoneCleaningFixtures.makeCallOnSpeakers(root: root)
        let store = meeting.store
        let timeline = try store.readTimeline()

        // Before the cleaner runs, both resolve to the recording. This is
        // what makes the assertions below mean something.
        let before = store.trackAudioLocation(
            track: .mic, metadata: meeting.metadata, timeline: timeline
        )
        #expect(before.directory.lastPathComponent == "segments")

        var carried = meeting.metadata
        _ = try MicrophoneCleaner().clean(
            store: store, metadata: &carried, timeline: timeline
        )
        let metadata = try store.readMetadata()
        let cleaned = store.trackAudioLocation(
            track: .mic, metadata: metadata, timeline: timeline
        )
        #expect(cleaned.segments.first?.file == "mic.cleaned.m4a")
        #expect(cleaned.directory.lastPathComponent == "audio")
        // The mixdown aligns tracks by this, and the cleaned track starts on
        // the same frame the recording did.
        #expect(
            cleaned.segments.first?.resolvedFirstFrameHostTime == timeline.firstFrameHostTime(track: .mic)
        )

        let raw = store.rawTrackAudioLocation(
            track: .mic, metadata: metadata, timeline: timeline
        )
        #expect(raw.directory.lastPathComponent == "segments")
        #expect(
            raw.segments.first?.file.hasSuffix(".caf") == true,
            "the recording is still where it was"
        )
        // Only the microphone is cleaned. The far end is untouched either
        // way.
        let remote = store.trackAudioLocation(
            track: .remote, metadata: metadata, timeline: timeline
        )
        #expect(remote.directory.lastPathComponent == "segments")

        // And the caller's own copy resolves to it too. `trackAudioLocation`
        // reads the metadata it is handed, so a caller left holding the copy
        // it passed in would keep reading the recording for the rest of the
        // run, with the cleaned file written and nothing using it.
        #expect(
            store.trackAudioLocation(track: .mic, metadata: carried, timeline: timeline)
                .segments.first?.file == "mic.cleaned.m4a")
    }

    @Test("cleaning twice subtracts from the recording both times")
    func cleaningTwiceSubtractsFromTheRecordingBothTimes() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try MicrophoneCleaningFixtures.makeCallOnSpeakers(root: root)
        let store = meeting.store
        let timeline = try store.readTimeline()
        let cleaner = MicrophoneCleaner()

        var carried = meeting.metadata
        #expect(
            try cleaner.clean(store: store, metadata: &carried, timeline: timeline) == CleaningOutcome.cleaned
        )
        let first = try #require(carried.cleanedMic)
        let (raw, firstClean) = try Self.rawAndClean(store: store, timeline: timeline)

        // The second run reads the recording again. A run that took the
        // first run's output as its input would find a microphone the far
        // end has already been taken out of, and would work on the residue
        // the first run left rather than on the echo.
        #expect(
            try cleaner.clean(store: store, metadata: &carried, timeline: timeline) == CleaningOutcome.cleaned
        )
        let second = try #require(carried.cleanedMic)
        #expect(second.track.frameCount == first.track.frameCount)
        let (_, secondClean) = try Self.rawAndClean(store: store, timeline: timeline)
        #expect(secondClean.count == firstClean.count)

        // Same input, same pass, same output. Over the last ten seconds the
        // recording holds the far end alone, and what the first run left of
        // it is what a second run over that residue would work on. The two
        // runs' outputs differ there by far less than that residue.
        // Measured 45 dB under it.
        let residue = MicrophoneCleaningFixtures.energy(
            MicrophoneCleaningFixtures.seconds(20, 30, of: firstClean))
        let difference = MicrophoneCleaningFixtures.energy(
            MicrophoneCleaningFixtures.seconds(20, 30, of: zip(firstClean, secondClean).map { $0 - $1 }))
        let apart = MicrophoneCleaningFixtures.dropDB(from: residue, to: difference)
        #expect(apart > 20, "the second run's output sits only \(apart) dB under the first's residue")
        let removed = MicrophoneCleaningFixtures.dropDB(before: raw, after: secondClean, from: 20, to: 30)
        #expect(removed > 20, "the second run took only \(removed) dB off the far end")
    }

    @Test("a run that decides against cleaning clears what an earlier run left")
    func aRunThatDecidesAgainstCleaningClearsWhatAnEarlierRunLeft() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // A meeting that was cleaned once, whose far end now reads as
        // nothing. The record and the file from the first run both have
        // to go, or every reader stays on a cleaned track this run decided
        // against.
        let count = Int(15 * MicrophoneCleaningFixtures.rate)
        let meeting = try MicrophoneCleaningFixtures.makeMeeting(
            root: root,
            mic: MicrophoneCleaningFixtures.tone(count: count, frequency: 700, amplitude: 0.3),
            remote: [Float](repeating: 0, count: count)
        )
        let store = meeting.store
        try FileManager.default.createDirectory(
            at: store.layout.trackArchiveDirectory, withIntermediateDirectories: true
        )
        try Data("not audio".utf8).write(to: store.layout.cleanedMicFile)
        var carried = try store.updateMetadata {
            $0.cleanedMic = CleanedMicrophone(
                track: AudioArchive.Track(
                    file: "mic.cleaned.m4a", sampleRate: MicrophoneCleaningFixtures.rate, channelCount: 1,
                    frameCount: Int64(count), seconds: 15, firstFrameHostTime: 100
                ),
                echoRemovedMedianDB: 40, farEndActiveWindows: 60,
                producedAt: Date(timeIntervalSince1970: 1_787_070_000)
            )
        }

        let outcome = try MicrophoneCleaner().clean(
            store: store, metadata: &carried, timeline: try store.readTimeline()
        )
        #expect(outcome == CleaningOutcome.skippedNoReference)
        #expect(carried.cleanedMic == nil)
        #expect(try store.readMetadata().cleanedMic == nil)
        #expect(
            !(FileManager.default.fileExists(atPath: store.layout.cleanedMicFile.path)),
            "the earlier run's file is gone with its record"
        )
        #expect(
            store.trackAudioLocation(
                track: .mic, metadata: carried, timeline: try store.readTimeline()
            ).directory.lastPathComponent == "segments")
    }

    @Test("a far end that started before the microphone is lined up too")
    func aFarEndThatStartedBeforeTheMicrophoneIsLinedUpToo() async throws {
        // The one caller that can hand `TimelineTrackReader` a negative
        // offset. The far end's track opens first whenever the meeting
        // application was already making noise as capture began, and the
        // reference is then read forward to meet the microphone rather than
        // padded to it. Subtracting the two lead-ins the other way round
        // pads the reference instead of skipping into it. That moves the
        // pair by four seconds and puts the echo in the microphone ahead of
        // the far end that caused it. No filter can model that. A wrong sign
        // is not self-announcing, and no outcome value separates it from a
        // good run. That is why the check at the end of this test reads the
        // far-end energy left in the cleaned track rather than the outcome.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let count = Int(30 * MicrophoneCleaningFixtures.rate)
        let offset = -2.0

        // Built here rather than from `makeCallOnSpeakers`, because the far
        // end has to start first. It talks in sentences with pauses between
        // them, which a four-second shift moves: a far end that never
        // stopped would be the same far end after any shift, and the sign
        // of the offset would not show.
        let remote = MicrophoneCleaningFixtures.talking(
            voice: MicrophoneCleaningFixtures.farVoice, texts: MicrophoneCleaningFixtures.farText,
            count: count
        )
        // The user, over the middle third of their own track.
        var mic = [Float](repeating: 0, count: count)
        let user = MicrophoneCleaningFixtures.talking(
            voice: MicrophoneCleaningFixtures.userVoice, texts: MicrophoneCleaningFixtures.userText,
            count: count / 3
        )
        for index in 0..<user.count { mic[count / 3 + index] = user[index] }
        // The far end's first frame landed two seconds before the
        // microphone's, so far-end sample j was in the room at microphone
        // sample j - 2 s + 3 ms, and the last two seconds of the microphone
        // are past the end of the far end's track.
        let shift = Int(offset * MicrophoneCleaningFixtures.rate) + MicrophoneCleaningFixtures.echoDelaySamples
        for index in max(0, shift)..<min(count, count + shift) {
            mic[index] += MicrophoneCleaningFixtures.echoGain * remote[index - shift]
        }
        let meeting = try MicrophoneCleaningFixtures.makeMeeting(
            root: root, mic: mic, remote: remote, remoteStartOffset: offset
        )
        let store = meeting.store
        let timeline = try store.readTimeline()
        #expect(
            abs((timeline.leadIn(track: .mic)) - (2)) <= 0.01,
            """
            expected 2 ± 0.01, got \(timeline.leadIn(track: .mic)), the microphone is the \
            track that starts late here
            """
        )
        #expect(timeline.leadIn(track: .remote) == 0)

        var carried = meeting.metadata
        let outcome = try MicrophoneCleaner().clean(
            store: store, metadata: &carried, timeline: timeline
        )
        #expect(outcome == CleaningOutcome.cleaned)

        // The far end alone, from where the user stops at 20 s up to 27 s,
        // past which the far end's track has run out and the microphone
        // carries no echo to remove. Measured at 40.1 dB.
        let (raw, clean) = try Self.rawAndClean(store: store, timeline: timeline)
        let removed = MicrophoneCleaningFixtures.dropDB(before: raw, after: clean, from: 20, to: 27)
        #expect(removed > 20, "the far end came down only \(removed) dB")
    }

    @Test("a microphone read that came up short is refused")
    func aMicrophoneReadThatCameUpShortIsRefused() async throws {
        // `TrackAudioReader` skips a segment it cannot open and logs a
        // notice, so a pass can read ten seconds of a sixty-minute
        // microphone. Measured against its own read that track agrees with
        // itself, and it would be promoted as the microphone every reader
        // takes with fifty minutes of the meeting gone. The manifest is
        // what says how much audio there was.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try MicrophoneCleaningFixtures.makeCallOnSpeakers(root: root)
        let store = meeting.store
        let timeline = try store.readTimeline()
        let location = store.rawTrackAudioLocation(
            track: .mic, metadata: meeting.metadata, timeline: timeline
        )
        #expect(
            abs((location.seconds) - (30)) <= 0.01,
            "expected 30 ± 0.01, got \(location.seconds)"
        )

        // Twenty of the thirty seconds, written back over the file the
        // manifest still describes as thirty. Long enough for the canceller
        // to lock on and be judged worth keeping.
        let recorded = try MicrophoneCleaningFixtures.samples(location)
        let format = AVAudioFormat(standardFormatWithSampleRate: MicrophoneCleaningFixtures.rate, channels: 1)!
        let segment = try #require(location.segments.first)
        let url = location.directory.appendingPathComponent(segment.file)
        func writeShortSegment() throws {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(
                from: MicrophoneCleaningFixtures.buffer(
                    Array(recorded.prefix(Int(20 * MicrophoneCleaningFixtures.rate))), format: format
                ))
        }
        try writeShortSegment()

        var carried = meeting.metadata
        do {
            let outcome = try MicrophoneCleaner().clean(
                store: store, metadata: &carried, timeline: timeline
            )
            Issue.record(
                "a twenty-second read of a thirty-second microphone came back \(outcome.rawValue)"
            )
        } catch {
            // Expected. The pass is measured against the manifest.
        }
        #expect(carried.cleanedMic == nil)
        #expect(try store.readMetadata().cleanedMic == nil)
        #expect(
            !(FileManager.default.fileExists(atPath: store.layout.cleanedMicFile.path)),
            "and nothing of the short track was left on disk"
        )
    }

    @Test("a pass that throws clears what an earlier run left")
    func aPassThatThrowsClearsWhatAnEarlierRunLeft() async throws {
        // A throw is one more answer that is not `.cleaned`, and the caller
        // records `.failed` and never runs the cleaner on this meeting
        // again. A record an earlier run left would keep every reader on
        // that run's file for good.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try MicrophoneCleaningFixtures.makeCallOnSpeakers(root: root)
        let store = meeting.store
        let count = Int(30 * MicrophoneCleaningFixtures.rate)
        try FileManager.default.createDirectory(
            at: store.layout.trackArchiveDirectory, withIntermediateDirectories: true
        )
        try Data("an earlier run's track".utf8).write(to: store.layout.cleanedMicFile)
        var carried = try store.updateMetadata {
            $0.cleanedMic = CleanedMicrophone(
                track: AudioArchive.Track(
                    file: "mic.cleaned.m4a", sampleRate: MicrophoneCleaningFixtures.rate, channelCount: 1,
                    frameCount: Int64(count), seconds: 30, firstFrameHostTime: 100
                ),
                echoRemovedMedianDB: 40, farEndActiveWindows: 100,
                producedAt: Date(timeIntervalSince1970: 1_787_070_000)
            )
        }

        // The directory the pass writes into, taken away from it after the
        // record above is in place. This throws before the point that
        // clears the record on the way to writing a new one.
        let audio = store.layout.trackArchiveDirectory
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: audio.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: audio.path
            )
        }

        do {
            let outcome = try MicrophoneCleaner().clean(
                store: store, metadata: &carried, timeline: try store.readTimeline()
            )
            Issue.record("a pass that could not write its file came back \(outcome.rawValue)")
        } catch {
            // Expected. The disk would not take the cleaned track.
        }
        // The record is what points a reader at the file, so it is the
        // record that has to go.
        #expect(carried.cleanedMic == nil)
        #expect(try store.readMetadata().cleanedMic == nil)
        #expect(
            store.trackAudioLocation(
                track: .mic, metadata: carried, timeline: try store.readTimeline()
            ).directory.lastPathComponent == "segments")
    }

    @Test("a meeting whose far end never played is left alone")
    func aMeetingWhoseFarEndNeverPlayedIsLeftAlone() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let count = Int(15 * MicrophoneCleaningFixtures.rate)
        let meeting = try MicrophoneCleaningFixtures.makeMeeting(
            root: root,
            mic: MicrophoneCleaningFixtures.tone(
                count: count, frequency: MicrophoneCleaningFixtures.nearTone, amplitude: 0.3
            ),
            remote: [Float](repeating: 0, count: count)
        )
        let store = meeting.store
        let timeline = try store.readTimeline()
        #expect(
            !(store.rawTrackAudioLocation(
                track: .remote, metadata: meeting.metadata, timeline: timeline
            ).isEmpty), "the far end was recorded, it just holds nothing")

        var carried = meeting.metadata
        let outcome = try MicrophoneCleaner().clean(
            store: store, metadata: &carried, timeline: timeline
        )
        #expect(outcome == CleaningOutcome.skippedNoReference)
        #expect(
            !(FileManager.default.fileExists(atPath: store.layout.cleanedMicFile.path)),
            "no cleaned track was written"
        )
        #expect(try store.readMetadata().cleanedMic == nil)
    }

    @Test("a recording holding everyone on one track has no far end to subtract")
    func aRecordingHoldingEveryoneOnOneTrackHasNoFarEndToSubtract() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let count = Int(2 * MicrophoneCleaningFixtures.rate)
        let meeting = try MicrophoneCleaningFixtures.makeMeeting(
            root: root, source: .imported,
            mic: MicrophoneCleaningFixtures.tone(
                count: count, frequency: MicrophoneCleaningFixtures.nearTone, amplitude: 0.3
            ),
            remote: nil
        )
        let store = meeting.store
        var carried = meeting.metadata
        let outcome = try MicrophoneCleaner().clean(
            store: store, metadata: &carried, timeline: try store.readTimeline()
        )
        #expect(outcome == CleaningOutcome.skippedOneTrack)
        #expect(
            !(FileManager.default.fileExists(atPath: store.layout.cleanedMicFile.path)),
            "no cleaned track was written"
        )
    }

}
