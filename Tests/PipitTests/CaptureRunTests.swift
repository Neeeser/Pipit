import Foundation
import PipitCore
import Testing

/// A call that dropped and was rejoined is several runs under one manifest.
/// Each run opens fresh writers, so each has its own place on the capture
/// clock, and the far end is not necessarily the same distance from the
/// microphone in all of them.
@Suite("CaptureRun")
struct CaptureRunTests {
    private struct Piece {
        var track: CaptureTrack
        var index: Int
        var reason: String
        var host: Double
        var seconds: Double
    }

    private static func timeline(_ pieces: [Piece]) -> RecordingTimeline {
        var lines = [
            ManifestLine(
                hostTime: 0, wallClock: Date(timeIntervalSince1970: 0),
                event: .sessionStart(
                    .init(
                        meetingID: "meeting", source: .googleMeet, segmentSeconds: 30,
                        appVersion: "1.0.0", processID: 1
                    )))
        ]
        for piece in pieces {
            lines.append(
                ManifestLine(
                    hostTime: piece.host, wallClock: Date(timeIntervalSince1970: piece.host),
                    event: .segmentOpen(
                        .init(
                            track: piece.track, index: piece.index,
                            file: "\(piece.track.segmentPrefix).\(piece.index).caf",
                            firstFrameHostTime: nil, startFrame: 0, sampleRate: 48_000,
                            channelCount: 1, reason: piece.reason
                        ))))
            lines.append(
                ManifestLine(
                    hostTime: piece.host + piece.seconds,
                    wallClock: Date(timeIntervalSince1970: piece.host + piece.seconds),
                    event: .segmentClose(
                        .init(
                            track: piece.track, index: piece.index,
                            frameCount: Int64(piece.seconds * 48_000), byteCount: 0,
                            seconds: piece.seconds, firstFrameHostTime: piece.host, reason: "rotate"
                        ))))
        }
        return ManifestReader.timeline(
            from: ManifestReadResult(lines: lines, hasTruncatedTail: false, unrecognisedLines: 0)
        )
    }

    @Test("a recording that was never paused is one run")
    func aRecordingThatWasNeverPausedIsOneRun() async throws {
        let timeline = Self.timeline([
            Piece(track: .mic, index: 1, reason: "start", host: 1_000, seconds: 30),
            Piece(track: .mic, index: 2, reason: "rotate", host: 1_030, seconds: 30),
            // The tap bound late, so its writer opened after the microphone's
            // second segment. That is still the first run.
            Piece(track: .remote, index: 1, reason: "start", host: 1_002, seconds: 30),
            Piece(track: .remote, index: 2, reason: "rotate", host: 1_032, seconds: 28),
        ])
        #expect(timeline.runs.count == 1)
        let run = try #require(timeline.runs.first)
        #expect(run.mic?.startSeconds == 0)
        #expect(abs((run.mic?.seconds ?? 0) - 60) <= 0.001)
        #expect(abs((run.remote?.seconds ?? 0) - 58) <= 0.001)
        #expect(abs((run.referenceOffset ?? .nan) - 2) <= 0.001)
    }

    @Test("a rejoin starts another run, and each run places the far end by its own host times")
    func aRejoinStartsAnotherRunAndEachRunPlacesTheFarEndByItsOwnHostTimes() async throws {
        let timeline = Self.timeline([
            // First run: the far end begins 2 s after the microphone.
            Piece(track: .mic, index: 1, reason: "start", host: 1_000, seconds: 100),
            Piece(track: .remote, index: 1, reason: "start", host: 1_002, seconds: 98),
            // A minute of reconnect wait, then new writers continue the
            // numbering. This time the far end begins 5 s after the microphone.
            Piece(track: .mic, index: 2, reason: "start", host: 1_160, seconds: 50),
            Piece(track: .remote, index: 2, reason: "start", host: 1_165, seconds: 45),
        ])
        #expect(timeline.runs.count == 2)
        #expect(timeline.segments(track: .mic).map(\.run) == [0, 1])
        #expect(timeline.segments(track: .remote).map(\.run) == [0, 1])

        let first = timeline.runs[0]
        let second = timeline.runs[1]
        #expect(abs((first.referenceOffset ?? .nan) - 2) <= 0.001)
        // 5 s on the capture clock, and the 2 s by which the first run's far end
        // is shorter than its microphone, which the concatenated tracks carry
        // forward as the offset of everything after it.
        #expect(abs((second.referenceOffset ?? .nan) - 7) <= 0.001)

        // Positions are in the concatenated audio of each track, which holds
        // no trace of the wait.
        #expect(abs((second.mic?.startSeconds ?? .nan) - 100) <= 0.001)
        #expect(abs((second.remote?.startSeconds ?? .nan) - 98) <= 0.001)
        #expect(abs((second.mic?.seconds ?? .nan) - 50) <= 0.001)
    }

    @Test("audio a track lost in one run is carried into where the next run places the far end")
    func audioATrackLostInOneRunIsCarriedIntoWhereTheNextRunPlacesTheFarEnd() async throws {
        // The microphone lost 3 s inside the first run, so its audio runs 3 s
        // shorter than the capture clock says. Everything after the loss sits
        // 3 s earlier in the track, and the next run's placement comes from
        // its own first frames and the audio before them, so it carries that.
        let timeline = Self.timeline([
            Piece(track: .mic, index: 1, reason: "start", host: 1_000, seconds: 97),
            Piece(track: .remote, index: 1, reason: "start", host: 1_002, seconds: 98),
            Piece(track: .mic, index: 2, reason: "start", host: 1_100, seconds: 50),
            Piece(track: .remote, index: 2, reason: "start", host: 1_100, seconds: 50),
        ])
        #expect(timeline.runs.count == 2)
        // origin(mic) = 1100 - 97 = 1003 and origin(remote) = 1100 - 98 = 1002.
        #expect(abs((timeline.runs[1].referenceOffset ?? .nan) - (-1)) <= 0.001)
    }

    @Test("a run with no far end has nothing to place")
    func aRunWithNoFarEndHasNothingToPlace() async throws {
        let timeline = Self.timeline([
            Piece(track: .mic, index: 1, reason: "start", host: 1_000, seconds: 100),
            Piece(track: .remote, index: 1, reason: "start", host: 1_002, seconds: 98),
            Piece(track: .mic, index: 2, reason: "start", host: 1_160, seconds: 50),
        ])
        #expect(timeline.runs.count == 2)
        #expect(timeline.runs[1].remote == nil)
        #expect(timeline.runs[1].referenceOffset == nil)
        #expect(timeline.runs[0].referenceOffset != nil)
    }
}
