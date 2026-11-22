"""Tests for the alignment measurement, on synthetic manifests. Run from the repository root:

    uv run --with numpy --with scipy --with soundfile python -m unittest discover -s Benchmarks/calls
"""

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import measure_alignment  # noqa: E402

BUFFER = measure_alignment.CAPTURE_BUFFER_FRAMES / measure_alignment.CAPTURE_RATE


def segments(track: str, start: float, count: int, ppm: float = 0.0, steps: dict | None = None) -> list[dict]:
    """Closed 30 s segments whose host time runs `ppm` fast, with `steps` (segment index to seconds lost)."""
    events = []
    host = start
    for index in range(count):
        events.append(
            {"ev": "segment_close", "track": track, "index": index + 1, "frameCount": 1440000,
             "seconds": 30.0, "firstFrameHostTime": host}
        )
        host += 30.0 * (1 + ppm * 1e-6) + (steps or {}).get(index, 0.0)
    return events


def write(directory: Path, events: list[dict]) -> Path:
    path = directory / "raw" / "manifest.jsonl"
    path.parent.mkdir(parents=True)
    path.write_text("".join(json.dumps(e) + "\n" for e in events))
    return path


class MeasureTests(unittest.TestCase):
    def measure(self, events: list[dict]) -> dict:
        with tempfile.TemporaryDirectory() as scratch:
            return measure_alignment.measure(write(Path(scratch), events))

    def test_a_late_far_end_reads_its_start_offset(self):
        found = self.measure(segments("mic", 100.0, 12) + segments("remote", 101.25, 12))
        self.assertAlmostEqual(found["offset"], 1.25, places=6)
        self.assertAlmostEqual(found["relativePPM"], 0.0, places=3)

    def test_a_steady_rate_is_drift_and_a_single_jump_is_a_step_not_drift(self):
        lost = 4 * BUFFER
        found = self.measure(segments("mic", 100.0, 20) + segments("remote", 100.0, 20, ppm=5.0, steps={9: lost}))
        self.assertAlmostEqual(found["relativePPM"], 5.0, places=2)
        self.assertEqual(len(found["remoteSteps"]), 1)
        self.assertAlmostEqual(found["remoteSteps"][0], lost + 30.0 * 5e-6, places=6)
        self.assertEqual(found["micSteps"], [])
        self.assertAlmostEqual(measure_alignment.slide_seconds(found), found["remoteSteps"][0], places=9)

    def test_the_host_time_jump_across_a_pause_is_not_a_step(self):
        before = segments("mic", 100.0, 12) + segments("remote", 100.0, 12)
        after = segments("mic", 1000.0, 12) + segments("remote", 1000.0, 12)
        found = self.measure(before + [{"ev": "marker", "label": "pause:user"}] + after)
        self.assertEqual(found["remoteSteps"], [])
        self.assertEqual(found["micSteps"], [])

    def test_the_report_counts_whole_buffers_and_names_no_meeting(self):
        results = [
            self.measure(segments("mic", 0.0, 20) + segments("remote", 0.0, 20, steps={3: BUFFER, 8: 4 * BUFFER})),
            self.measure(segments("mic", 0.0, 20) + segments("remote", 0.5, 20)),
        ]
        lines = measure_alignment.report(results)
        self.assertIn("far-end steps under 50 ms, by nearest whole 512-frame buffers: 1: 1, 4: 1", lines)
        self.assertIn("meetings where the far end slid earlier (steps under 1 s): 1", lines)


if __name__ == "__main__":
    unittest.main()
