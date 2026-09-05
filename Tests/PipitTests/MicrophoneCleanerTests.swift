import AVFoundation
import Foundation
import PipitAudio
import PipitCore
import PipitServices
import PipitTestSupport
import Testing

/// The cleaned microphone track: what comes out of it, what it is called, and
/// the meetings it must refuse to touch.
///
/// The problem it solves, measured on a Slack huddle of 3 September 2026: 81%
/// of the words on the microphone were the far end's, arriving through the air
/// from the speakers. Every earlier attempt worked on the transcript, guessing
/// which words to delete, and deleted the local user's 3957 words instead.
@Suite("MicrophoneCleaner")
struct MicrophoneCleanerTests {
    /// The second, to a fiftieth of one, at which a tone starts.
    ///
    /// The first 20 ms window past `after` whose energy at that frequency
    /// passes half the level it holds once the tone is running.
    private static func onset(
        of samples: [Float], frequency: Double, after: Double, steady: Double
    ) -> Double {
        let step = Int(0.02 * MicrophoneCleaningFixtures.rate)
        var index = Int(after * MicrophoneCleaningFixtures.rate)
        while index + step <= samples.count {
            let window = Array(samples[index..<(index + step)])
            if MicrophoneCleaningFixtures.toneEnergy(window, frequency: frequency) > steady / 2 {
                return Double(index) / MicrophoneCleaningFixtures.rate
            }
            index += step
        }
        return .infinity
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

        let raw = try MicrophoneCleaningFixtures.samples(store.rawTrackAudioLocation(
            track: .mic, metadata: metadata, timeline: timeline
        ))
        let clean = try MicrophoneCleaningFixtures.samples(store.trackAudioLocation(
            track: .mic, metadata: metadata, timeline: timeline
        ))
        #expect(clean.count == raw.count, "the cleaned track runs as long as the recording")

        // Measured over the last third, where the user is silent. The
        // first third is not comparable: the canceller reports nothing
        // until it has heard 2.5 s of far-end activity, and the far end
        // here does not start until two seconds in. Measured at 88.1 dB.
        let farBefore = MicrophoneCleaningFixtures.toneEnergy(
            MicrophoneCleaningFixtures.seconds(20, 30, of: raw),
            frequency: MicrophoneCleaningFixtures.farToneA
        )
        let farAfter = MicrophoneCleaningFixtures.toneEnergy(
            MicrophoneCleaningFixtures.seconds(20, 30, of: clean),
            frequency: MicrophoneCleaningFixtures.farToneA
        )
        let removed = MicrophoneCleaningFixtures.dropDB(from: farBefore, to: farAfter)
        #expect(removed > 20, "the far end came down only \(removed) dB")

        // And the user, over the middle third, where they are talking
        // across the far end. This is the number every earlier attempt got
        // wrong. Measured at 0.33 dB.
        let userBefore = MicrophoneCleaningFixtures.toneEnergy(
            MicrophoneCleaningFixtures.seconds(10, 20, of: raw),
            frequency: MicrophoneCleaningFixtures.nearTone
        )
        let userAfter = MicrophoneCleaningFixtures.toneEnergy(
            MicrophoneCleaningFixtures.seconds(10, 20, of: clean),
            frequency: MicrophoneCleaningFixtures.nearTone
        )
        let lost = MicrophoneCleaningFixtures.dropDB(from: userBefore, to: userAfter)
        #expect(lost < 3, "the user lost \(lost) dB of their own voice")

        // And it sits on the same clock the recording does. An encoder that
        // put its own priming frames at the front would move every
        // timestamp in the transcript by that much.
        let steady = MicrophoneCleaningFixtures.toneEnergy(
            MicrophoneCleaningFixtures.seconds(15, 15.02, of: raw),
            frequency: MicrophoneCleaningFixtures.nearTone
        )
        let rawOnset = Self.onset(
            of: raw,
            frequency: MicrophoneCleaningFixtures.nearTone,
            after: 9,
            steady: steady
        )
        let cleanOnset = Self.onset(
            of: clean,
            frequency: MicrophoneCleaningFixtures.nearTone,
            after: 9,
            steady: steady
        )
        #expect(
            abs((rawOnset) - (10)) <= 0.03,
            "expected 10 ± 0.03, got \(rawOnset) — within one 20 ms window"
        )
        #expect(
            abs((cleanOnset) - (rawOnset)) <= 0.03,
            "expected \(rawOnset) ± \(0.03), got \(cleanOnset) — within one 20 ms window"
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
        #expect(store.trackAudioLocation(track: .mic, metadata: carried, timeline: timeline)
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

        // The second run reads the recording again. A run that took the
        // first run's output as its input would find a microphone the far
        // end has already been taken out of, report no echo path, and throw
        // away a track that was good.
        #expect(
            try cleaner.clean(store: store, metadata: &carried, timeline: timeline) == CleaningOutcome.cleaned
        )
        let second = try #require(carried.cleanedMic)
        #expect(
            abs((second.echoRemovedMedianDB) - (first.echoRemovedMedianDB)) <= 1,
            """
            expected \(first.echoRemovedMedianDB) ± 1, got \(second.echoRemovedMedianDB) — \
            the second pass found the same echo path the first did
            """
        )
        #expect(second.track.frameCount == first.track.frameCount)
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
        #expect(store.trackAudioLocation(
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
        // the far end that caused it. No filter can model that. The far end
        // still plays in bursts, so the suppressor keeps gating with them.
        // With the sign flipped, the pass cleared the 6 dB threshold and
        // returned `.cleaned` after taking out 5.0 dB. A wrong sign is not
        // self-announcing, and no outcome value separates it from a good
        // run. That is why the check at the end of this test reads the
        // far-end energy left in the cleaned track rather than the outcome.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let count = Int(30 * MicrophoneCleaningFixtures.rate)
        let offset = -2.0

        // Built here rather than from `makeCallOnSpeakers`, whose far end
        // is a tone that never stops. Such a tone is the same tone after
        // any shift, so a pair moved by four seconds cancels just as well
        // and the sign of the offset does not show. This far end plays in
        // bursts of 0.7 s every 1.3 s, which a shift does move.
        var remote = MicrophoneCleaningFixtures.tone(
            count: count, frequency: MicrophoneCleaningFixtures.farToneA, amplitude: 0.5
        )
        for index in 0..<count {
            let phase = (Double(index) / MicrophoneCleaningFixtures.rate).truncatingRemainder(dividingBy: 1.3)
            if phase > 0.7 { remote[index] = 0 }
        }
        // The user, over the middle third of their own track.
        var mic = MicrophoneCleaningFixtures.tone(
            count: count, frequency: MicrophoneCleaningFixtures.nearTone, amplitude: 0.3,
            from: count / 3, upTo: 2 * count / 3
        )
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
            expected 2 ± 0.01, got \(timeline.leadIn(track: .mic)) — the microphone is the \
            track that starts late here
            """
        )
        #expect(timeline.leadIn(track: .remote) == 0)

        var carried = meeting.metadata
        let outcome = try MicrophoneCleaner().clean(
            store: store, metadata: &carried, timeline: timeline
        )
        #expect(outcome == CleaningOutcome.cleaned)

        let metadata = try store.readMetadata()
        let raw = try MicrophoneCleaningFixtures.samples(store.rawTrackAudioLocation(
            track: .mic, metadata: metadata, timeline: timeline
        ))
        let clean = try MicrophoneCleaningFixtures.samples(store.trackAudioLocation(
            track: .mic, metadata: metadata, timeline: timeline
        ))
        // Up to 28 s, past which the far end's track has run out and the
        // microphone carries no echo to remove.
        let before = MicrophoneCleaningFixtures.toneEnergy(
            MicrophoneCleaningFixtures.seconds(20, 27, of: raw),
            frequency: MicrophoneCleaningFixtures.farToneA
        )
        let after = MicrophoneCleaningFixtures.toneEnergy(
            MicrophoneCleaningFixtures.seconds(20, 27, of: clean),
            frequency: MicrophoneCleaningFixtures.farToneA
        )
        let removed = MicrophoneCleaningFixtures.dropDB(from: before, to: after)
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
            try file.write(from: MicrophoneCleaningFixtures.buffer(
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
        #expect(store.trackAudioLocation(
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
        #expect(!(store.rawTrackAudioLocation(
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
