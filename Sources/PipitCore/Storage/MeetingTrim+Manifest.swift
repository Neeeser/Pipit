import Foundation

extension MeetingTrim {
    /// The capture record after a trim, and what it says about each track.
    public struct TrimmedManifest: Sendable, Equatable {
        public var lines: [ManifestLine]
        /// Seconds of audio the manifest now accounts for, per track.
        public var keptSeconds: [CaptureTrack: Double]
        /// Capture time of each track's first kept frame, where the manifest
        /// knows it.
        public var firstFrameHostTimes: [CaptureTrack: Double]
    }

    struct SegmentKey: Hashable {
        let track: CaptureTrack
        let index: Int
    }

    /// What becomes of one segment: where its kept audio starts and how long
    /// it is, and whether the cut shortened it.
    private struct SegmentPlan {
        var startFrame: Int64
        var frames: Int64
        var bytes: Int64
        var seconds: Double
        var firstFrameHostTime: Double?
        var isWhole: Bool
    }

    private struct SegmentRecord {
        var open: ManifestEvent.SegmentOpen?
        var frames: Int64 = 0
        var bytes: Int64 = 0
        var closeFirstFrameHostTime: Double?
        /// Adopted from a crash tail rather than closed by the writer.
        var wasAdopted = false
    }

    /// The capture record cut to the audio each track keeps.
    ///
    /// Segments are cut by their position in the track's joined audio, which
    /// is how the archive was cut, and not by host time. The two agree only
    /// while a track has no gap in it; after a stall or a capture restart the
    /// host clock runs on over audio that was never recorded, and a cut by
    /// host time keeps a segment the archive no longer has. A segment adopted
    /// after a crash has no start time at all, and is placed by its length
    /// like the rest.
    ///
    /// Every other event outside the range is dropped, except the device and
    /// stream descriptions from before the cut, which are moved to its start
    /// because they still describe the audio that remains.
    public static func trim(
        _ lines: [ManifestLine], to range: TrimRange, origin: Double, cuts: [CaptureTrack: TrackCut],
        firstHostTimes: [CaptureTrack: Double] = [:]
    ) -> TrimmedManifest {
        let startHost = origin + range.start
        let endHost = origin + range.effectiveEnd
        let plans = segmentPlans(lines, cuts: cuts, firstHostTimes: firstHostTimes)
        var kept: [CaptureTrack: Double] = [:]
        for (key, plan) in plans { kept[key.track, default: 0] += plan.seconds }
        let keptDuration = kept.values.max() ?? 0

        var output: [ManifestLine] = []
        var sessionStartWall: Date?
        for line in lines {
            switch line.event {
            case .sessionStart:
                sessionStartWall = line.wallClock.addingTimeInterval(range.start)
                output.append(
                    ManifestLine(
                        hostTime: max(line.hostTime, startHost), wallClock: sessionStartWall ?? line.wallClock,
                        event: line.event
                    ))
            case .segmentOpen(let open):
                guard let plan = plans[SegmentKey(track: open.track, index: open.index)] else { continue }
                output.append(moved(open, plan: plan, line: line, startHost: startHost))
            case .segmentClose(let close):
                guard let plan = plans[SegmentKey(track: close.track, index: close.index)] else { continue }
                output.append(moved(close, plan: plan, line: line, endHost: endHost))
            case .crashTailAdopted(let adopted):
                guard let plan = plans[SegmentKey(track: adopted.track, index: adopted.index)] else { continue }
                output.append(plan.isWhole ? line : moved(adopted, plan: plan, line: line))
            case .sessionEnd(let end):
                output.append(
                    ManifestLine(
                        hostTime: min(line.hostTime, endHost),
                        wallClock: (sessionStartWall ?? line.wallClock).addingTimeInterval(keptDuration),
                        event: .sessionEnd(
                            ManifestEvent.SessionEnd(
                                reason: end.reason, micSeconds: kept[.mic] ?? 0, remoteSeconds: kept[.remote] ?? 0
                            ))
                    ))
            case .micBind, .remoteBind, .remoteStream, .sourceHealth, .formatChange:
                if let described = moveDescription(line, startHost: startHost, endHost: endHost) {
                    output.append(described)
                }
            default:
                guard line.hostTime >= startHost, line.hostTime <= endHost else { continue }
                output.append(line)
            }
        }
        return TrimmedManifest(
            lines: output, keptSeconds: kept, firstFrameHostTimes: firstFrameHostTimes(plans)
        )
    }

    // MARK: planning

    /// Lays each track's segments end to end in index order, which is the
    /// joined audio the archive was cut from, and works out what the cut
    /// leaves of each one.
    private static func segmentPlans(
        _ lines: [ManifestLine], cuts: [CaptureTrack: TrackCut], firstHostTimes: [CaptureTrack: Double]
    ) -> [SegmentKey: SegmentPlan] {
        var records: [SegmentKey: SegmentRecord] = [:]
        for line in lines {
            switch line.event {
            case .segmentOpen(let open):
                records[SegmentKey(track: open.track, index: open.index), default: SegmentRecord()].open = open
            case .segmentClose(let close):
                var record = records[SegmentKey(track: close.track, index: close.index)] ?? SegmentRecord()
                record.frames = close.frameCount
                record.bytes = close.byteCount
                record.closeFirstFrameHostTime = close.firstFrameHostTime
                records[SegmentKey(track: close.track, index: close.index)] = record
            case .crashTailAdopted(let adopted):
                var record = records[SegmentKey(track: adopted.track, index: adopted.index)] ?? SegmentRecord()
                record.frames = adopted.frameCount
                record.bytes = adopted.byteCount
                record.wasAdopted = true
                records[SegmentKey(track: adopted.track, index: adopted.index)] = record
            default: break
            }
        }
        var plans: [SegmentKey: SegmentPlan] = [:]
        for track in CaptureTrack.allCases {
            guard let cut = cuts[track] else { continue }
            var position = 0.0
            var startFrame: Int64 = 0
            for key in records.keys.filter({ $0.track == track }).sorted(by: { $0.index < $1.index }) {
                guard let record = records[key], let open = record.open, record.frames > 0 else { continue }
                let rate = open.sampleRate > 0 ? open.sampleRate : 16_000
                let length = Double(record.frames) / rate
                let from = max(position, cut.from)
                let to = min(position + length, cut.to)
                defer { position += length }
                guard to - from > 1e-9 else { continue }
                let isWhole = from <= position + 1e-9 && to >= position + length - 1e-9
                let frames = isWhole ? record.frames : Int64(((to - from) * rate).rounded())
                guard frames > 0 else { continue }
                let first = (open.firstFrameHostTime ?? record.closeFirstFrameHostTime)
                    .map { $0 + (from - position) }
                plans[key] = SegmentPlan(
                    startFrame: startFrame, frames: frames,
                    bytes: isWhole
                        ? record.bytes : Int64(Double(record.bytes) * Double(frames) / Double(record.frames)),
                    seconds: Double(frames) / rate, firstFrameHostTime: first, isWhole: isWhole
                )
                startFrame += frames
            }
        }
        return aligned(plans, cuts: cuts, firstHostTimes: firstHostTimes)
    }

    /// Puts each track on the clock the meeting timeline is read from.
    ///
    /// The timeline is a track's lead-in plus a position in its joined audio,
    /// and the lead-in is the track's first-frame time less the earliest
    /// track's. After a gap in the capture clock the real time of a later
    /// frame is ahead of that position by the gap, so the kept audio starts at
    /// the old first-frame time plus the cut, not at its real capture time. The
    /// first kept segment is stamped with that, even where it never had a
    /// start of its own (a crash tail), so the manifest and the archive say
    /// the same, and the track's other segments move by the same amount so the
    /// gaps between them stay as recorded.
    private static func aligned(
        _ plans: [SegmentKey: SegmentPlan], cuts: [CaptureTrack: TrackCut], firstHostTimes: [CaptureTrack: Double]
    ) -> [SegmentKey: SegmentPlan] {
        var result = plans
        for track in CaptureTrack.allCases {
            guard let cut = cuts[track], let old = firstHostTimes[track] else { continue }
            let keys = plans.keys.filter { $0.track == track }.sorted { $0.index < $1.index }
            guard let first = keys.first else { continue }
            let target = old + cut.from
            // Where the first kept frame really was, worked back from the first
            // segment that knows its start.
            var before = 0.0
            var real: Double?
            for key in keys {
                guard let plan = plans[key] else { continue }
                if let host = plan.firstFrameHostTime {
                    real = host - before
                    break
                }
                before += plan.seconds
            }
            let shift = real.map { target - $0 } ?? 0
            for key in keys {
                result[key]?.firstFrameHostTime = plans[key]?.firstFrameHostTime.map { $0 + shift }
            }
            result[first]?.firstFrameHostTime = target
        }
        return result
    }

    /// Capture time of each track's first kept frame, as the timeline reads it.
    private static func firstFrameHostTimes(_ plans: [SegmentKey: SegmentPlan]) -> [CaptureTrack: Double] {
        var result: [CaptureTrack: Double] = [:]
        for track in CaptureTrack.allCases {
            let keys = plans.keys.filter { $0.track == track }.sorted { $0.index < $1.index }
            if let host = keys.first.flatMap({ plans[$0]?.firstFrameHostTime }) { result[track] = host }
        }
        return result
    }

    // MARK: rewriting events

    private static func moved(
        _ open: ManifestEvent.SegmentOpen, plan: SegmentPlan, line: ManifestLine, startHost: Double
    ) -> ManifestLine {
        let event = ManifestEvent.SegmentOpen(
            track: open.track, index: open.index, file: open.file,
            firstFrameHostTime: plan.firstFrameHostTime ?? open.firstFrameHostTime,
            startFrame: plan.startFrame, sampleRate: open.sampleRate, channelCount: open.channelCount,
            reason: open.reason
        )
        return ManifestLine(
            hostTime: max(line.hostTime, startHost), wallClock: line.wallClock, event: .segmentOpen(event))
    }

    private static func moved(
        _ close: ManifestEvent.SegmentClose, plan: SegmentPlan, line: ManifestLine, endHost: Double
    ) -> ManifestLine {
        ManifestLine(
            hostTime: plan.isWhole ? line.hostTime : min(line.hostTime, endHost), wallClock: line.wallClock,
            event: .segmentClose(
                ManifestEvent.SegmentClose(
                    track: close.track, index: close.index, frameCount: plan.frames, byteCount: plan.bytes,
                    seconds: plan.seconds, firstFrameHostTime: plan.firstFrameHostTime ?? close.firstFrameHostTime,
                    reason: plan.isWhole ? close.reason : "trimmed"
                ))
        )
    }

    private static func moved(
        _ adopted: ManifestEvent.CrashTailAdopted, plan: SegmentPlan, line: ManifestLine
    ) -> ManifestLine {
        ManifestLine(
            hostTime: line.hostTime, wallClock: line.wallClock,
            event: .crashTailAdopted(
                ManifestEvent.CrashTailAdopted(
                    track: adopted.track, index: adopted.index, frameCount: plan.frames, byteCount: plan.bytes,
                    seconds: plan.seconds
                ))
        )
    }

    /// A device or stream description. One from before the cut still
    /// describes the audio that remains, so it moves to the cut; one from
    /// after the range describes nothing kept.
    private static func moveDescription(_ line: ManifestLine, startHost: Double, endHost: Double) -> ManifestLine? {
        if line.hostTime > endHost { return nil }
        guard line.hostTime < startHost else { return line }
        return ManifestLine(
            hostTime: startHost, wallClock: line.wallClock.addingTimeInterval(startHost - line.hostTime),
            event: line.event
        )
    }
}
