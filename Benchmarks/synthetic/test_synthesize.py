"""Tests for synthesize.py that need no network and no speech model.

    uv run --with numpy --with scipy --with soundfile python -m unittest Benchmarks/synthetic/test_synthesize.py
"""

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import make_cases
import synthesize
import write_script

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


    def test_a_one_word_line_timed_early_is_not_cut_as_silence(self) -> None:
        # The recogniser puts "yes" and the word after it about 0.4 s before they are said, which leaves
        # the pause after "yes" outside the usual cutting window.
        lines = ["alpha one", "yes", "charlie three"]
        audio = np.concatenate([tone(1.0), silence(0.6), tone(0.3), silence(0.6), tone(1.0), silence(0.3)])
        heard = [{"text": "alpha", "start": 0.0, "end": 0.5}, {"text": "one", "start": 0.5, "end": 1.0},
                 {"text": "yes", "start": 1.2, "end": 1.6},
                 {"text": "charlie", "start": 2.15, "end": 2.6}, {"text": "three", "start": 2.6, "end": 3.1}]
        pieces = SplitByAlignment.split(self, audio, lines, heard)
        self.assertIsNotNone(pieces)
        for piece, spoken in zip(pieces, [1.0, 0.3, 1.0], strict=True):
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


class VoiceCacheWithoutKey(unittest.TestCase):
    def test_a_voice_file_with_no_key_is_reused_with_a_warning(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "S01.wav"
            path.write_bytes(b"old")
            warning = io.StringIO()
            with mock.patch.object(synthesize.gemini, "speech") as speech, contextlib.redirect_stderr(warning):
                self.assertEqual(synthesize.cached_speech(path, "model", "Kore", "hello"), b"old")
            speech.assert_not_called()
            self.assertIn("S01.wav", warning.getvalue())
            self.assertIn("unverified", warning.getvalue())


class SpeechReply(unittest.TestCase):
    def reply(self, finish: str | None) -> dict:
        candidate: dict = {"content": {"parts": [{"inlineData": {"mimeType": "audio/L16;codec=pcm;rate=24000", "data": "AAAA"}}]}}
        if finish is not None:
            candidate["finishReason"] = finish
        return {"candidates": [candidate]}

    def test_audio_cut_off_at_an_output_limit_is_an_error(self) -> None:
        with mock.patch.object(synthesize.gemini, "_post", return_value=self.reply("MAX_TOKENS")):
            with self.assertRaisesRegex(RuntimeError, "MAX_TOKENS"):
                synthesize.gemini.speech("model", "words", "Kore")

    def test_audio_that_finished_is_returned(self) -> None:
        for finish in ("STOP", None):
            with self.subTest(finish=finish), mock.patch.object(synthesize.gemini, "_post", return_value=self.reply(finish)):
                self.assertTrue(synthesize.gemini.speech("model", "words", "Kore").startswith(b"RIFF"))


class OverwriteGuard(unittest.TestCase):
    def test_a_different_truth_is_not_replaced_unless_asked(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "M.truth.json"
            path.write_text(json.dumps({"words": [1]}))
            with self.assertRaises(SystemExit):
                synthesize.guard_overwrite(path, {"words": [2]}, overwrite=False)
            synthesize.guard_overwrite(path, {"words": [2]}, overwrite=True)

    def test_the_same_truth_or_no_truth_passes(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "M.truth.json"
            synthesize.guard_overwrite(path, {"words": [1]}, overwrite=False)
            path.write_text(json.dumps({"words": [1.5]}))
            synthesize.guard_overwrite(path, {"words": [1.5]}, overwrite=False)


class ScriptChecks(unittest.TestCase):
    def script(self, ids: list[str], turn_speakers: list[str]) -> dict:
        return {"participants": [{"id": i} for i in ids],
                "turns": [{"speaker": s, "text": "words", "kind": "turn"} for s in turn_speakers]}

    def test_a_script_with_the_requested_speakers_passes(self) -> None:
        self.assertEqual(write_script.problems(self.script(["S01", "S02", "S03"], ["S01", "S02", "S03"]), 3), [])

    def test_fewer_participants_than_requested_is_a_problem(self) -> None:
        found = write_script.problems(self.script(["S01", "S02"], ["S01", "S02"]), 3)
        self.assertTrue(any("2 participants" in p for p in found), found)

    def test_ids_outside_the_numbering_are_a_problem(self) -> None:
        found = write_script.problems(self.script(["S01", "S02", "S07"], ["S01", "S02", "S07"]), 3)
        self.assertTrue(any("S07" in p for p in found), found)

    def test_a_participant_with_no_turns_is_a_problem(self) -> None:
        found = write_script.problems(self.script(["S01", "S02", "S03"], ["S01", "S02"]), 3)
        self.assertTrue(any("S03" in p for p in found), found)


class VoiceChoice(unittest.TestCase):
    speakers = ["S01", "S02", "S03"]

    def test_the_default_roster_is_used_in_speaker_order(self) -> None:
        self.assertEqual(synthesize.assign_voices(self.speakers, None),
                         dict(zip(self.speakers, synthesize.VOICES, strict=False)))

    def test_chosen_voices_go_to_speakers_in_order(self) -> None:
        chosen = ["Umbriel", "Kore", "Despina"]
        self.assertEqual(synthesize.assign_voices(self.speakers, chosen), dict(zip(self.speakers, chosen, strict=True)))

    def test_a_repeated_unknown_or_miscounted_choice_is_refused(self) -> None:
        for chosen in (["Kore", "Kore", "Puck"], ["Kore", "Puck", "Nobody"], ["Kore", "Puck"]):
            with self.subTest(chosen=chosen), self.assertRaises(SystemExit):
                synthesize.assign_voices(self.speakers, chosen)

    def test_more_speakers_than_voices_is_refused(self) -> None:
        with self.assertRaises(SystemExit):
            synthesize.assign_voices(["S%02d" % n for n in range(1, len(synthesize.VOICES) + 2)], None)


class RejectedSpeech(unittest.TestCase):
    def test_a_reply_that_stopped_early_is_kept_beside_the_cache(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "S01.wav"
            early = synthesize.gemini.IncompleteSpeech("stopped", b"partial")
            with mock.patch.object(synthesize.gemini, "speech", side_effect=early):
                with self.assertRaises(RuntimeError):
                    synthesize.cached_speech(path, "model", "Kore", "hello")
            self.assertEqual((Path(scratch) / "S01.rejected.wav").read_bytes(), b"partial")
            self.assertFalse(path.exists())
            self.assertFalse(path.with_suffix(".key").exists())


class CaseOverwrite(unittest.TestCase):
    def test_only_files_that_differ_from_what_is_there_are_reported(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            staged, bench = Path(scratch) / "staged", Path(scratch) / "bench"
            for root, content in ((staged, b"new"), (bench, b"old")):
                (root / "calls" / "M-a").mkdir(parents=True)
                (root / "calls" / "M-a" / "mic.wav").write_bytes(content)
            (staged / "calls" / "M-a" / "remote.wav").write_bytes(b"first time")
            (staged / "calls" / "M-a" / "case.json").write_text("{}")
            (bench / "calls" / "M-a" / "case.json").write_text("{\"changed\": true}")
            self.assertEqual(make_cases.changed_files(staged, bench), ["calls/M-a/mic.wav"])


if __name__ == "__main__":
    unittest.main()
