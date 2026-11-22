"""Tests for synthesize.py that need no network and no speech model.

    uv run --with numpy --with scipy --with soundfile python -m unittest Benchmarks/synthetic/test_synthesize.py
"""

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import synthesize

RATE = synthesize.RATE


def tone(seconds: float) -> np.ndarray:
    t = np.arange(int(seconds * RATE)) / RATE
    return (0.3 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)


def silence(seconds: float) -> np.ndarray:
    return np.zeros(int(seconds * RATE), dtype=np.float32)


class SplitByAlignment(unittest.TestCase):
    def split(self, audio: np.ndarray, lines: list[str], heard: list[dict]) -> list[np.ndarray] | None:
        def fake_asr(command: list[str], **_: object) -> None:
            Path(command[command.index("--json") + 1]).write_text(json.dumps([{"words": heard}]))

        with mock.patch.object(synthesize.subprocess, "run", side_effect=fake_asr), \
                mock.patch.object(synthesize, "PIPIT_EVAL", Path(__file__)):
            return synthesize.split_by_alignment(audio, lines)

    def five_lines(self, missed: int, stretched: bool) -> tuple[np.ndarray, list[str], list[dict]]:
        """Five 1.2 s lines with 0.6 s pauses between them and a 0.2 s pause inside each."""
        lines = ["alpha one", "bravo two", "charlie three", "delta four", "echo five"]
        audio = np.concatenate([part for _ in lines for part in (tone(0.5), silence(0.2), tone(0.5), silence(0.6))])
        heard = []
        for index, line in enumerate(lines):
            if index != missed:
                first, second = line.split()
                heard += [{"text": first, "start": index * 1.8, "end": index * 1.8 + 0.5},
                          {"text": second, "start": index * 1.8 + 0.7, "end": index * 1.8 + 1.2}]
        if stretched:
            # Parakeet often ends a word where the next one starts, across the pause.
            for word, following in zip(heard, heard[1:]):
                word["end"] = following["start"]
        return audio, lines, heard

    def assert_lines(self, pieces: list[np.ndarray] | None) -> None:
        self.assertIsNotNone(pieces)
        self.assertEqual(len(pieces), 5)
        for piece in pieces:
            self.assertAlmostEqual(len(piece) / RATE, 1.2, delta=0.1)

    def test_a_line_the_recogniser_missed_is_cut_at_the_silences_around_it(self) -> None:
        for stretched in (False, True):
            with self.subTest(stretched=stretched):
                self.assert_lines(self.split(*self.five_lines(missed=2, stretched=stretched)))

    def test_a_line_missing_from_the_audio_stops_the_split(self) -> None:
        # The speech model said only a 0.1 s fragment of the third line, which
        # has eight words; the pauses around it are still there.
        audio, lines, heard = self.five_lines(missed=2, stretched=False)
        lines[2] = "a line of eight words never said aloud"
        start, end = int(1.8 * 2 * RATE), int((1.8 * 2 + 1.2) * RATE)
        audio = audio.copy()
        audio[start + int(0.1 * RATE): end] = 0.0
        self.assertIsNone(self.split(audio, lines, heard))

    def test_cuts_stay_in_the_pause_when_word_ends_run_through_it(self) -> None:
        self.assert_lines(self.split(*self.five_lines(missed=-1, stretched=True)))

    def test_a_missed_last_line_is_still_cut(self) -> None:
        self.assert_lines(self.split(*self.five_lines(missed=4, stretched=True)))


class SplitOneWordLine(unittest.TestCase):
    def test_a_one_word_line_whose_end_runs_through_the_next_pause(self) -> None:
        lines = ["alpha one", "yes", "charlie three"]
        audio = np.concatenate([tone(1.0), silence(0.5), tone(0.4), silence(0.8), tone(1.0), silence(0.3)])
        heard = [{"text": "alpha", "start": 0.0, "end": 0.5}, {"text": "one", "start": 0.5, "end": 1.0},
                 {"text": "yes", "start": 1.5, "end": 2.7},  # stretched to the next word's start
                 {"text": "charlie", "start": 2.7, "end": 3.2}, {"text": "three", "start": 3.2, "end": 3.7}]
        pieces = SplitByAlignment.split(self, audio, lines, heard)
        self.assertIsNotNone(pieces)
        for piece, spoken in zip(pieces, [1.0, 0.4, 1.0], strict=True):
            self.assertAlmostEqual(len(piece) / RATE, spoken, delta=0.1)


class Voiced(unittest.TestCase):
    def test_a_single_loud_frame_after_a_line_does_not_extend_it(self) -> None:
        audio = np.concatenate([tone(1.0), silence(0.8), tone(0.01), silence(0.2)])
        on = synthesize.voiced(audio)
        last = len(on) - int(np.argmax(on[::-1]))
        self.assertAlmostEqual(last * synthesize.FRAME / RATE, 1.0, delta=0.02)


class Layout(unittest.TestCase):
    def test_one_speaker_never_overlaps_their_own_previous_line(self) -> None:
        turns = [{"speaker": "S01", "kind": "turn"}, {"speaker": "S01", "kind": "interrupt"},
                 {"speaker": "S02", "kind": "turn"}, {"speaker": "S02", "kind": "backchannel"},
                 {"speaker": "S01", "kind": "turn"}, {"speaker": "S01", "kind": "turn"}]
        script = {"turns": [dict(t, text="words here") for t in turns]}
        clips = {s: [tone(3.0)] * 4 for s in ("S01", "S02")}
        for seed in range(20):
            _, placed = synthesize.layout(script, clips, seed, talk_over=1.0)
            ends = {}
            for line in placed:
                self.assertGreaterEqual(line["start"], ends.get(line["speaker"], 0.0), "seed %d" % seed)
                ends[line["speaker"]] = line["end"]


class VoiceCache(unittest.TestCase):
    def test_a_voice_file_from_other_words_is_not_reused(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "S01.wav"
            with mock.patch.object(synthesize.gemini, "speech", return_value=b"first") as speech:
                self.assertEqual(synthesize.cached_speech(path, "model", "Kore", "hello"), b"first")
                self.assertEqual(synthesize.cached_speech(path, "model", "Kore", "hello"), b"first")
                self.assertEqual(speech.call_count, 1)
                with self.assertRaises(SystemExit):
                    synthesize.cached_speech(path, "model", "Kore", "goodbye")


if __name__ == "__main__":
    unittest.main()
