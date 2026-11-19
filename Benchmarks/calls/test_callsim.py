"""Tests for the call simulator.

    uv run --with numpy --with scipy --with soundfile python -m unittest discover -s Benchmarks/calls

They use short synthetic channels and the committed manifest, never the corpus
audio, so they run without a download. The codec tests skip when ffmpeg is not
installed.
"""

import hashlib
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parent))

import callsim  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
RATE = callsim.RATE
HAS_FFMPEG = shutil.which("ffmpeg") is not None


def talker(rng: np.random.Generator, seconds: float, bursts: list[tuple[float, float]]) -> np.ndarray:
    """Noise with a syllable-rate envelope inside each burst, silence elsewhere."""
    samples = int(seconds * RATE)
    out = np.zeros(samples, dtype=np.float32)
    for start, end in bursts:
        a, b = int(start * RATE), int(end * RATE)
        t = np.arange(b - a) / RATE
        syllables = 0.55 + 0.45 * np.sin(2 * np.pi * rng.uniform(3, 5) * t + rng.uniform(0, 6))
        out[a:b] = (rng.standard_normal(b - a) * syllables * 0.1).astype(np.float32)
    return out


def words_in(agent: str, speaker: str, bursts: list[tuple[float, float]]) -> list[dict]:
    words = []
    for start, end in bursts:
        position = start
        while position + 0.3 <= end:
            words.append({"agent": agent, "speaker": speaker, "start": position, "end": position + 0.3, "text": "word"})
            position += 0.4
    return words


def synthetic_meeting(directory: Path, seconds: float = 40.0):
    """Four channels where each person talks in their own bursts, and the truth."""
    rng = np.random.default_rng(7)
    bursts = {
        "A": [(2.0, 8.0), (30.0, 36.0)],
        "B": [(9.0, 15.0), (24.0, 28.0)],
        "C": [(16.0, 22.0)],
        "D": [(5.0, 7.0), (36.5, 39.0)],
    }
    truth = {"windowStart": None, "windowSeconds": seconds, "agentToSpeaker": {}, "words": []}
    channels = {}
    for agent, spans in bursts.items():
        speaker = "SPK_" + agent
        truth["agentToSpeaker"][agent] = speaker
        truth["words"] += words_in(agent, speaker, spans)
        audio = talker(rng, seconds, spans)
        # Every channel hears a little of the others, as a close-talk mic does.
        for other, other_spans in bursts.items():
            if other != agent:
                audio += 0.05 * talker(rng, seconds, other_spans)
        path = directory / ("channel-%s.wav" % agent)
        sf.write(path, audio, RATE, subtype="FLOAT")
        channels[agent] = path
    return truth, channels


class SelectionTests(unittest.TestCase):
    def test_the_manifest_names_the_agent_the_seed_picks(self):
        manifest = json.loads((ROOT / "Benchmarks/manifest.json").read_text())["calls"]
        for meeting, entry in manifest["meetings"].items():
            truth = json.loads((ROOT / "Benchmarks/ground-truth" / ("%s.json" % meeting)).read_text())
            self.assertEqual(
                entry["localAgent"], callsim.choose_local_agent(manifest["seed"], meeting, truth), meeting
            )

    def test_the_pick_depends_on_the_seed_and_the_meeting_only(self):
        truth = {"words": [{"agent": a} for a in "ABCD" for _ in range(10)]}
        picks = {callsim.choose_local_agent(seed, "M", truth) for seed in range(40)}
        self.assertGreater(len(picks), 1, "the seed changes nothing")
        self.assertEqual(callsim.choose_local_agent(5, "M", truth), callsim.choose_local_agent(5, "M", truth))

    def test_a_person_with_almost_no_words_is_never_the_local_person(self):
        truth = {"words": [{"agent": "A"}] * 50 + [{"agent": "B"}] * 48 + [{"agent": "C"}] * 2}
        picks = {callsim.choose_local_agent(seed, "M", truth) for seed in range(60)}
        self.assertEqual(picks, {"A", "B"})

    def test_only_held_out_meetings_are_in_the_suite(self):
        manifest = json.loads((ROOT / "Benchmarks/manifest.json").read_text())
        for meeting in manifest["calls"]["meetings"]:
            self.assertIn(manifest["partition"][meeting], {"ami-eval", "clean"}, meeting)

    def test_every_speaker_has_a_pinned_channel(self):
        manifest = json.loads((ROOT / "Benchmarks/manifest.json").read_text())["calls"]
        for meeting, entry in manifest["meetings"].items():
            truth = json.loads((ROOT / "Benchmarks/ground-truth" / ("%s.json" % meeting)).read_text())
            self.assertEqual(set(entry["channels"]), set(truth["agentToSpeaker"]), meeting)
            channels = [c["channel"] for c in entry["channels"].values()]
            self.assertEqual(len(set(channels)), len(channels), "%s shares a channel" % meeting)
            for channel in entry["channels"].values():
                self.assertEqual(len(channel["sha256"]), 64)


class GateTests(unittest.TestCase):
    def test_the_channel_is_silent_away_from_the_owners_words(self):
        words = [{"start": 5.0, "end": 6.0}, {"start": 6.2, "end": 7.0}, {"start": 20.0, "end": 21.0}]
        mask = callsim.speech_mask(words, 30 * RATE)
        at = lambda seconds: mask[int(seconds * RATE)]
        self.assertEqual(at(5.5), 1.0)
        self.assertEqual(at(6.1), 1.0, "a pause inside a phrase was cut")
        self.assertEqual(at(2.0), 0.0)
        self.assertEqual(at(12.0), 0.0)
        self.assertEqual(at(20.5), 1.0)
        self.assertEqual(at(25.0), 0.0)

    def test_words_are_padded_and_edges_are_soft(self):
        mask = callsim.speech_mask([{"start": 10.0, "end": 11.0}], 20 * RATE)
        self.assertGreater(mask[int((10.0 - callsim.GATE_PAD_SECONDS / 2) * RATE)], 0.99)
        edge = mask[int((10.0 - callsim.GATE_PAD_SECONDS) * RATE) - 40 : int((10.0 - callsim.GATE_PAD_SECONDS) * RATE) + 40]
        self.assertTrue(np.any((edge > 0.05) & (edge < 0.95)), "the gate has a hard edge")


class MeasureTests(unittest.TestCase):
    def test_identical_envelopes_read_one_and_a_delayed_copy_reads_its_delay(self):
        rng = np.random.default_rng(1)
        signal = talker(rng, 60, [(1, 9), (12, 20), (25, 33), (40, 55)])
        value, lag = callsim.echo_correlation(signal, signal)
        self.assertAlmostEqual(value, 1.0, places=6)
        delayed = np.concatenate([np.zeros(int(0.12 * RATE), dtype=np.float32), signal])[: len(signal)]
        value, lag = callsim.echo_correlation(delayed, signal)
        self.assertGreater(value, 0.99)
        self.assertAlmostEqual(lag, 0.12, places=2)

    def test_unrelated_audio_reads_low(self):
        rng = np.random.default_rng(2)
        a = talker(rng, 120, [(5, 20), (60, 80)])
        b = talker(rng, 120, [(30, 50), (90, 110)])
        value, _ = callsim.echo_correlation(a, b)
        self.assertLess(value, 0.35)


@unittest.skipUnless(HAS_FFMPEG, "ffmpeg is not installed")
class CodecTests(unittest.TestCase):
    def test_the_round_trip_keeps_length_and_timing(self):
        rng = np.random.default_rng(3)
        signal = talker(rng, 20, [(1, 6), (8, 12), (14, 19)])
        coded = callsim.opus_round_trip(signal)
        self.assertEqual(len(coded), len(signal))
        self.assertGreater(float(np.max(np.abs(coded))), 0.05, "the codec removed the speech")
        self.assertFalse(np.array_equal(coded, signal), "the codec changed nothing")
        value, lag = callsim.echo_correlation(coded, signal)
        self.assertGreater(value, 0.95)
        self.assertLess(abs(lag), 0.011, "the codec moved the audio")


@unittest.skipUnless(HAS_FFMPEG, "ffmpeg is not installed")
class CaseTests(unittest.TestCase):
    def build(self, directory: Path, out: Path, targets=(None, 0.6)):
        truth, channels = synthetic_meeting(directory)
        prepared = callsim.prepare_meeting(11, "SYN", truth, "A", channels)
        infos = []
        for name, target in zip(("headphones", "laptop"), targets):
            variant = callsim.render_variant(prepared, name, target)
            infos.append(callsim.write_case(out / name, prepared, variant, 11, truth))
        return prepared, infos

    def test_a_rebuild_writes_the_same_audio(self):
        with tempfile.TemporaryDirectory() as scratch:
            scratch = Path(scratch)
            (scratch / "in").mkdir()
            _, first = self.build(scratch / "in", scratch / "one")
            _, second = self.build(scratch / "in", scratch / "two")
        for one, two in zip(first, second):
            self.assertEqual(one["files"], two["files"])
            self.assertEqual(one["echo"], two["echo"])

    def test_the_local_person_is_on_the_microphone_and_the_others_on_the_far_end(self):
        with tempfile.TemporaryDirectory() as scratch:
            scratch = Path(scratch)
            (scratch / "in").mkdir()
            prepared, _ = self.build(scratch / "in", scratch / "out")
            mic, _ = sf.read(scratch / "out/headphones/mic.wav", dtype="float32")
            remote, _ = sf.read(scratch / "out/headphones/remote.wav", dtype="float32")

        def loud(audio, start, end):
            return float(np.sqrt(np.mean(audio[int(start * RATE) : int(end * RATE)] ** 2)))

        # Agent A is local and talks 2-8 s and 30-36 s; the others never do.
        self.assertGreater(loud(mic, 3, 7), 20 * loud(mic, 12, 14), "the local person is missing from the microphone")
        self.assertLess(loud(remote, 3, 4), 0.1 * loud(remote, 10, 14), "the local person leaked into the far end")
        self.assertGreater(loud(remote, 10, 14), 0.01)
        self.assertEqual(prepared.local_speaker, "SPK_A")

    def test_an_echo_variant_reads_its_target_and_headphones_read_low(self):
        with tempfile.TemporaryDirectory() as scratch:
            scratch = Path(scratch)
            (scratch / "in").mkdir()
            _, infos = self.build(scratch / "in", scratch / "out", targets=(None, 0.6))
        headphones, laptop = (info["echo"] for info in infos)
        self.assertLess(headphones["correlation"], 0.3)
        self.assertTrue(laptop["reachedTarget"])
        self.assertAlmostEqual(laptop["correlation"], 0.6, delta=0.02)
        self.assertGreater(laptop["gain"], 0)

    def test_the_description_names_the_files_it_wrote(self):
        with tempfile.TemporaryDirectory() as scratch:
            scratch = Path(scratch)
            (scratch / "in").mkdir()
            _, infos = self.build(scratch / "in", scratch / "out")
            for info, name in zip(infos, ("headphones", "laptop")):
                on_disk = json.loads((scratch / "out" / name / "case.json").read_text())
                self.assertEqual(on_disk["case"], "SYN-%s" % name)
                for track in ("mic", "remote"):
                    path = scratch / "out" / name / on_disk["files"][track]["name"]
                    self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), on_disk["files"][track]["sha256"])
                    audio, rate = sf.read(path)
                    self.assertEqual(rate, RATE)
                    self.assertEqual(audio.ndim, 1)
                self.assertEqual(info["localSpeaker"], "SPK_A")


if __name__ == "__main__":
    unittest.main()
