#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10,<3.14"
# dependencies = ["numpy>=1.26"]
# ///
"""Measure how far apart the two tracks of recorded calls start and drift.

    Benchmarks/calls/measure_alignment.py ~/Documents/Pipit/Meetings

Reads `raw/manifest.jsonl` of every meeting under the folder and never writes
there. Each closed segment records the capture host time of its first frame and
how many frames it holds, so for one track the host time a frame was captured
at can be set against how many frames came before it:

- The start offset is the system-audio track's first frame minus the
  microphone's, in seconds. Positive means the far end started later.
- A track's drift is how much faster host time runs than its samples, in
  parts per million: the median over consecutive segments of the host time
  between their first frames against the seconds the first one recorded. The
  median ignores a single jump, which a plain line fit would spread over the
  whole meeting as a rate. The relative drift is the system-audio track's
  drift minus the microphone's, the rate at which the far end slides against
  the microphone when both files are read at their nominal rate.
- A step is a jump in one track's host time against its samples between two
  segments of more than `STEP_SECONDS`: audio lost and not padded, or padded
  with more than was lost. The writer pads a gap of 50 ms or more with
  silence, so a step shows what is left after that.

Only segments of the first capture run are used. Meeting names and
content are never printed; the output is counts and percentiles.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

# A segment shorter than this says little about the rate.
MIN_SEGMENT_SECONDS = 5.0
# A track needs this much audio before its drift is worth reporting.
MIN_TRACK_SECONDS = 300.0
# A step of this size or more is a restart or a pause the marker missed, not
# lost buffers, and is left out of the slide.
SLIDE_STEP_LIMIT_SECONDS = 1.0
# The capture pads a gap from this size up, so a single unpadded loss is shorter.
PAD_FLOOR_SECONDS = 0.05
CAPTURE_RATE = 48000
CAPTURE_BUFFER_FRAMES = 512

# Consecutive segments whose host times disagree with their samples by more
# than this hold a step. Steady drift moves them by well under a millisecond.
STEP_SECONDS = 0.002


def track_points(events: list[dict], track: str) -> list[tuple[float, float, float]]:
    """(recorded seconds before the segment, host time of its first frame, its seconds)."""
    points = []
    before = 0.0
    for event in events:
        if event.get("ev") != "segment_close" or event.get("track") != track:
            continue
        frames = event.get("frameCount") or 0
        seconds = event.get("seconds") or 0.0
        first = event.get("firstFrameHostTime")
        if frames <= 0 or seconds <= 0 or first is None or first < 0:
            continue
        points.append((before, float(first), float(seconds)))
        before += float(seconds)
    return points


def first_run(events: list[dict]) -> list[dict]:
    """Events up to the first pause, so a resumed recording is not one line.

    The capture records a pause as a marker labelled `pause:<reason>`
    (`CaptureEngine.pause`), and the host-time jump across it is not audio lost.
    """
    kept = []
    for event in events:
        if event.get("ev") == "marker" and str(event.get("label", "")).startswith("pause:"):
            break
        kept.append(event)
    return kept


def drift_and_steps(points: list[tuple[float, float, float]]) -> tuple[float | None, list[float]]:
    """The track's rate against host time in ppm, and the steps in seconds."""
    rates, steps = [], []
    for (_, host, seconds), (_, following, _) in zip(points, points[1:]):
        error = (following - host) - seconds
        if abs(error) > STEP_SECONDS:
            steps.append(error)
        elif seconds >= MIN_SEGMENT_SECONDS:
            rates.append(error / seconds)
    total = points[-1][0] + points[-1][2] if points else 0.0
    if len(rates) < 3 or total < MIN_TRACK_SECONDS:
        return None, steps
    return float(np.median(rates) * 1e6), steps


def measure(manifest: Path) -> dict | None:
    events = []
    for line in manifest.read_text().splitlines():
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    events = first_run(events)
    mic, remote = track_points(events, "mic"), track_points(events, "remote")
    if not mic or not remote:
        return None
    result: dict = {"offset": remote[0][1] - mic[0][1], "seconds": max(p[0] + p[2] for p in mic + remote)}
    mic_drift, mic_steps = drift_and_steps(mic)
    remote_drift, remote_steps = drift_and_steps(remote)
    result["micSteps"] = mic_steps
    result["remoteSteps"] = remote_steps
    if mic_drift is not None and remote_drift is not None:
        result["micPPM"] = mic_drift
        result["remotePPM"] = remote_drift
        result["relativePPM"] = remote_drift - mic_drift
    return result


def percentiles(values: list[float]) -> str:
    if not values:
        return "none"
    v = np.array(values)
    return "n=%d  min %.4g  p10 %.4g  median %.4g  p90 %.4g  p95 %.4g  max %.4g" % (
        len(v), v.min(), np.percentile(v, 10), np.median(v), np.percentile(v, 90), np.percentile(v, 95), v.max(),
    )


def slide_seconds(result: dict) -> float:
    """How far the far end moved earlier against the microphone over the run."""

    def lost(track: str) -> float:
        return sum(s for s in result[track + "Steps"] if abs(s) < SLIDE_STEP_LIMIT_SECONDS)

    return lost("remote") - lost("mic")


def report(results: list[dict]) -> list[str]:
    """The lines the script prints: counts and percentiles, nothing per meeting."""
    lines = []
    offsets = [r["offset"] for r in results]
    lines.append("meetings with both tracks: %d" % len(results))
    lines.append("start offset, seconds (far end minus microphone): %s" % percentiles(offsets))
    lines.append("absolute start offset, seconds:                   %s" % percentiles([abs(o) for o in offsets]))
    for limit in (1.0,):
        later = sum(1 for o in offsets if o > limit)
        earlier = sum(1 for o in offsets if o < -limit)
        lines.append("offsets over %.0f s: far end later in %d, microphone later in %d" % (limit, later, earlier))
    drifts = [r for r in results if "relativePPM" in r]
    lines.append("meetings long enough to measure drift: %d" % len(drifts))
    lines.append("microphone drift, ppm:          %s" % percentiles([r["micPPM"] for r in drifts]))
    lines.append("system audio drift, ppm:        %s" % percentiles([r["remotePPM"] for r in drifts]))
    lines.append("absolute relative drift, ppm:   %s" % percentiles([abs(r["relativePPM"]) for r in drifts]))
    lines.append(
        "drift over the meeting, ms:     %s" % percentiles([abs(r["relativePPM"]) * r["seconds"] / 1000 for r in drifts])
    )
    for track in ("mic", "remote"):
        steps = [step for r in results for step in r[track + "Steps"]]
        stepped = sum(1 for r in results if r[track + "Steps"])
        lines.append("%s steps: %d meetings have one; sizes, ms: %s" % (track, stepped, percentiles([1000 * s for s in steps])))
    buffer_seconds = CAPTURE_BUFFER_FRAMES / CAPTURE_RATE
    small = [s for r in results for s in r["remoteSteps"] if 0 < s < PAD_FLOOR_SECONDS]
    counts: dict[int, int] = {}
    for step in small:
        counts[int(round(step / buffer_seconds))] = counts.get(int(round(step / buffer_seconds)), 0) + 1
    lines.append(
        "far-end steps under %.0f ms, by whole %d-frame buffers: %s"
        % (PAD_FLOOR_SECONDS * 1000, CAPTURE_BUFFER_FRAMES, ", ".join("%d: %d" % kv for kv in sorted(counts.items())))
    )
    slides = [slide_seconds(r) for r in results]
    lines.append(
        "meetings where the far end slid earlier (steps under %.0f s): %d" % (SLIDE_STEP_LIMIT_SECONDS, sum(1 for s in slides if s > 0))
    )
    lines.append("far-end slide, ms per meeting:  %s" % percentiles([1000 * s for s in slides]))
    lines.append(
        "far-end slide, ms per minute:   %s"
        % percentiles([1000 * s / (r["seconds"] / 60) for s, r in zip(slides, results)])
    )
    return lines


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("archive", type=Path, help="the Pipit meetings folder")
    parser.add_argument("--detail", type=Path, help="also write one JSON line per meeting, with no names")
    args = parser.parse_args()

    results = []
    for manifest in sorted(args.archive.rglob("raw/manifest.jsonl")):
        found = measure(manifest)
        if found is not None:
            results.append(found)
    if not results:
        sys.exit("no meeting with both tracks under %s" % args.archive)
    if args.detail:
        with open(args.detail, "w") as handle:
            for found in results:
                handle.write(json.dumps(found) + "\n")

    for line in report(results):
        print(line)


if __name__ == "__main__":
    main()
