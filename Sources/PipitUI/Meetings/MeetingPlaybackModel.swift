import AVFoundation
import Foundation
import Observation
import PipitCore

/// Plays a meeting's recording and says where in the transcript it is.
///
/// One per open meeting, owned by its review model, so opening another meeting
/// stops this one rather than leaving it talking behind the new one.
@MainActor
@Observable
public final class MeetingPlaybackModel {
    /// Every recording's mixdown, end to end.
    public private(set) var timeline = PlaybackTimeline()
    /// When each speaker talks, for the strip on the bar.
    public private(set) var lanes: [SpeakerLane] = []
    /// Playback seconds. Ticks while playing, so only the bar reads it.
    public private(set) var position: Double = 0
    public private(set) var isPlaying = false
    public private(set) var rate: Float = 1
    /// Whether the transcript scrolls to what is playing. Turned off by
    /// scrolling the transcript by hand while it plays.
    public var follows = true
    /// The turn and word at the position. Set only when either changes, so
    /// the transcript is redrawn a few times a second rather than on every
    /// tick, and nil until playback has been started or moved.
    public private(set) var cursor: PlaybackCursor?

    public var hasAudio: Bool { !timeline.isEmpty }

    /// What the speed button steps through.
    public static let rates: [Float] = [1, 1.25, 1.5, 2, 0.75]

    @ObservationIgnored private var lines: [CombinedLine] = []
    @ObservationIgnored private var blocks: [CombinedLineBlock] = []
    @ObservationIgnored private var laneOrder: [String] = []
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playerPart: Int?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// Read once per file. A pane reload comes with every progress tick.
    @ObservationIgnored private var durations: [URL: Double] = [:]
    /// Whether the reader has played or moved the playhead yet. Until then
    /// nothing in the transcript is marked as playing.
    @ObservationIgnored private var engaged = false

    public init() {}

    /// One recording of the conversation, as the files were last read.
    public struct Recording: Equatable, Sendable {
        public var id: String
        public var audio: URL
        /// Seconds after the conversation's first recording began.
        public var timelineOffset: Double

        public init(id: String, audio: URL, timelineOffset: Double) {
            self.id = id
            self.audio = audio
            self.timelineOffset = timelineOffset
        }
    }

    /// Takes a fresh read of the meeting. Does nothing when neither the audio
    /// nor the lines changed.
    public func update(recordings: [Recording], lines: [CombinedLine]) {
        let rebuilt = PlaybackTimeline(
            recordings.map { recording in
                PlaybackTimeline.Source(
                    recordingID: recording.id, audio: recording.audio,
                    duration: duration(of: recording.audio),
                    timelineOffset: recording.timelineOffset
                )
            })
        let timelineChanged = rebuilt != timeline
        if timelineChanged {
            // A part appeared or went away under the player. The file it holds
            // may no longer be the one at this position.
            stop()
            timeline = rebuilt
            position = min(position, rebuilt.duration)
        }
        guard timelineChanged || lines != self.lines else { return }
        self.lines = lines
        blocks = CombinedLineBlock.blocks(from: lines)
        refreshLanes()
        refreshCursor()
    }

    /// Puts the lanes in the order the speaker chips are in.
    public func setLaneOrder(_ names: [String]) {
        guard names != laneOrder else { return }
        laneOrder = names
        refreshLanes()
    }

    // MARK: - transport

    public func toggle() {
        if isPlaying { pause() } else { play() }
    }

    public func play() {
        guard hasAudio, !isPlaying else { return }
        if position >= timeline.duration - 0.05 { position = 0 }
        engaged = true
        guard load(at: position), let player, player.play() else { return }
        isPlaying = true
        startTicking()
        refreshCursor()
    }

    public func pause() {
        guard isPlaying else { return }
        player?.pause()
        isPlaying = false
        ticker?.cancel()
        ticker = nil
    }

    /// Pauses and lets go of the file.
    public func stop() {
        pause()
        player?.stop()
        player = nil
        playerPart = nil
    }

    /// Moves the playhead, playing on from there if it was playing.
    public func seek(to target: Double) {
        guard hasAudio else { return }
        engaged = true
        position = min(max(target, 0), timeline.duration)
        // AVAudioPlayer can restart the final file when its currentTime is
        // set to the file's duration while it is playing.
        if position == timeline.duration {
            stop()
            refreshCursor()
            return
        }
        if isPlaying {
            if !load(at: position) || player?.isPlaying != true {
                isPlaying = false
                ticker?.cancel()
                ticker = nil
            }
        }
        refreshCursor()
    }

    public func skip(by seconds: Double) {
        seek(to: position + seconds)
    }

    /// Plays from a moment in one recording, which is what a word and a turn
    /// header know. Takes the transcript back to following.
    public func play(recordingID: String, seconds: Double) {
        guard let target = timeline.position(recordingID: recordingID, seconds: seconds) else { return }
        follows = true
        seek(to: target)
        play()
    }

    public func cycleRate() {
        let next = Self.rates.firstIndex(of: rate).map { ($0 + 1) % Self.rates.count } ?? 0
        rate = Self.rates[next]
        player?.rate = rate
    }

    /// Whether this recording has audio to play, so a word in it can offer to.
    public func canPlay(recordingID: String) -> Bool {
        timeline.parts.contains { $0.recordingID == recordingID }
    }

    // MARK: - internals

    private func duration(of audio: URL) -> Double {
        if let known = durations[audio] { return known }
        guard FileManager.default.fileExists(atPath: audio.path) else { return 0 }
        do {
            let file = try AVAudioFile(forReading: audio)
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            durations[audio] = seconds
            return seconds
        } catch {
            Log.ui.notice("recording unreadable: \(logSafeDescription(error), privacy: .public)")
            return 0
        }
    }

    /// Points the player at the part holding `position` and the moment in it,
    /// opening that part's file when it is not the one already open.
    private func load(at position: Double) -> Bool {
        guard let located = timeline.locate(position) else { return false }
        let index = located.part
        if playerPart != index || player == nil {
            player?.stop()
            player = nil
            playerPart = nil
            do {
                let opened = try AVAudioPlayer(contentsOf: timeline.parts[index].audio)
                opened.enableRate = true
                opened.prepareToPlay()
                player = opened
                playerPart = index
            } catch {
                Log.ui.notice("recording unplayable: \(logSafeDescription(error), privacy: .public)")
                return false
            }
        }
        player?.rate = rate
        player?.currentTime = located.seconds
        if isPlaying, player?.isPlaying == false { player?.play() }
        return true
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard isPlaying, let player, let index = playerPart, timeline.parts.indices.contains(index)
        else { return }
        let part = timeline.parts[index]
        if player.isPlaying {
            position = part.start + min(player.currentTime, part.duration)
        } else if timeline.parts.indices.contains(index + 1) {
            // The file ran out and the call carries on in the next recording.
            position = timeline.parts[index + 1].start
            if !load(at: position) || self.player?.play() != true { pause() }
        } else {
            position = timeline.duration
            pause()
        }
        refreshCursor()
    }

    private func refreshLanes() {
        let rebuilt = timeline.lanes(for: lines, order: laneOrder)
        if rebuilt != lanes { lanes = rebuilt }
    }

    private func refreshCursor() {
        let found = engaged ? timeline.cursor(at: position, in: blocks) : nil
        if found != cursor { cursor = found }
    }
}
