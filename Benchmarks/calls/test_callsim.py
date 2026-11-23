"""Tests for the call simulator. Run from the repository root:

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


def synthetic_meeting(directory: Path, seconds: float = 40.0, bursts: dict | None = None):
    """Four channels where each person talks in their own bursts, and the truth."""
    rng = np.random.default_rng(7)
    bursts = bursts or {
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


class CrosstalkTests(unittest.TestCase):
    OWNER = [{"start": 2.0, "end": 3.9}, {"start": 4.5, "end": 6.5}]

    def test_another_voice_in_a_pause_of_the_owner_is_muted(self):
        samples = 10 * RATE
        other = [{"start": 4.0, "end": 4.4}]
        gate = callsim.speech_mask(self.OWNER, samples)
        keep = callsim.crosstalk_keep(self.OWNER, other, samples)
        at = lambda mask, seconds: mask[int(seconds * RATE)]
        self.assertEqual(at(gate, 4.2), 1.0, "the gate alone should keep the pause")
        self.assertEqual(at(gate * keep, 4.2), 0.0)
        self.assertEqual(at(keep, 8.0), 1.0, "a stretch nobody else speaks in was muted")

    def test_no_owner_word_loses_a_sample(self):
        samples = 10 * RATE
        # One word inside the owner's speech, and two that come closer to an
        # owner word than the fade is wide, so only the margin keeps the fade
        # off the owner's samples.
        gap = callsim.GATE_FADE_SECONDS / 4
        other = [{"start": 3.0, "end": 3.5}, {"start": 1.0, "end": 2.0 - gap}, {"start": 6.5 + gap, "end": 7.5}]
        keep = callsim.crosstalk_keep(self.OWNER, other, samples)
        for word in self.OWNER:
            span = keep[int(word["start"] * RATE) : int(word["end"] * RATE)]
            self.assertEqual(float(span.min()), 1.0)
        self.assertEqual(keep[int(7.0 * RATE)], 0.0)


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


class SensorTests(unittest.TestCase):
    SPEC = {"pollSeconds": 0.5, "holdSeconds": 1.5, "dropoutShare": 0.0}

    def truth(self, turns=None):
        if turns is None:
            turns = []
            for index in range(60):
                speaker = "SPK_" + "ABCD"[index % 4]
                turns.append({"speaker": speaker, "start": index * 10.0, "end": index * 10.0 + 6.0})
        return {
            "windowSeconds": 600.0,
            "agentToSpeaker": {letter: "SPK_" + letter for letter in "ABCD"},
            "turns": turns,
        }

    def record(self, turns=None, spec=None, seed=1):
        return callsim.simulate_sensors(seed, "SYN", self.truth(turns), "SPK_A", spec or self.SPEC)

    def names(self, record):
        by_id = {p["id"]: p["displayName"] for p in record["participants"]}
        return [(by_id[t["participantID"]], t["start"], t["end"]) for t in record["turns"]]

    def test_the_record_has_the_fields_the_app_reads(self):
        record = self.record()
        self.assertEqual(set(record), {"version", "source", "participants", "turns", "unmutedIDs", "selfIsAuthoritative"})
        self.assertEqual(record["source"], "google_meet-dom")
        self.assertFalse(record["selfIsAuthoritative"])
        known = {p["id"] for p in record["participants"]}
        self.assertTrue(all(t["participantID"] in known and t["end"] > t["start"] for t in record["turns"]))

    def test_the_local_tile_reads_you_with_the_self_flag_and_there_is_no_mute_state(self):
        record = self.record()
        marked = [p for p in record["participants"] if p["isSelf"]]
        self.assertEqual([p["displayName"] for p in marked], ["You"])
        self.assertEqual(record["unmutedIDs"], [])
        self.assertFalse(record["selfIsAuthoritative"])
        # Everyone else keeps the reference speaker's name, and the local
        # person's own name is not in the record.
        others = sorted(p["displayName"] for p in record["participants"] if not p["isSelf"])
        self.assertEqual(others, ["SPK_B", "SPK_C", "SPK_D"])

    def test_one_person_holds_the_floor_at_a_time_even_when_the_speech_overlaps(self):
        turns = [
            {"speaker": "SPK_B", "start": 10.0, "end": 20.0},
            {"speaker": "SPK_C", "start": 14.0, "end": 26.0},
            {"speaker": "SPK_D", "start": 24.0, "end": 30.0},
        ]
        record = self.record(turns)
        ordered = sorted(record["turns"], key=lambda t: t["start"])
        for before, after in zip(ordered, ordered[1:]):
            self.assertLessEqual(before["end"], after["start"] + 1e-9)

    def test_a_turn_ends_when_the_hold_runs_out_after_the_voice_stops(self):
        record = self.record([{"speaker": "SPK_B", "start": 10.0, "end": 16.0}])
        (name, start, end), = self.names(record)
        self.assertEqual(name, "SPK_B")
        self.assertTrue(10.0 <= start <= 10.5 + 1e-6)
        # The last poll that heard the voice, then the hold, then the poll that notices.
        self.assertTrue(16.0 + 1.5 <= end <= 16.0 + 1.5 + 1.0 + 1e-6)

    def test_a_hand_over_leaves_no_gap_and_a_pause_does(self):
        record = self.record(
            [
                {"speaker": "SPK_B", "start": 10.0, "end": 16.0},
                {"speaker": "SPK_C", "start": 16.2, "end": 22.0},
                {"speaker": "SPK_B", "start": 40.0, "end": 44.0},
            ]
        )
        first, second, third = sorted(record["turns"], key=lambda t: t["start"])
        self.assertEqual(first["end"], second["start"])
        self.assertGreater(third["start"], second["end"])

    def test_a_short_interjection_over_a_long_turn_does_not_take_the_floor(self):
        record = self.record(
            [
                {"speaker": "SPK_B", "start": 10.0, "end": 40.0},
                {"speaker": "SPK_C", "start": 20.0, "end": 20.8},
            ]
        )
        self.assertEqual({name for name, _, _ in self.names(record)}, {"SPK_B"})

    def test_turns_start_on_the_poll_grid(self):
        record = self.record()
        phase = record["turns"][0]["start"] % 0.5
        for turn in record["turns"]:
            for edge in (turn["start"], turn["end"]):
                offset = (edge - phase) % 0.5
                self.assertTrue(min(offset, 0.5 - offset) < 2e-3)

    def test_dropouts_remove_only_remote_track_turns(self):
        full = self.record()
        lossy = self.record(spec=dict(self.SPEC, dropoutShare=0.5))
        local_id = next(p["id"] for p in lossy["participants"] if p["isSelf"])
        count = lambda record, local: sum((t["participantID"] == local_id) == local for t in record["turns"])
        self.assertEqual(count(lossy, True), count(full, True))
        self.assertLess(count(lossy, False), count(full, False))
        self.assertGreater(count(lossy, False), 0)

    def test_the_record_depends_on_the_seed_and_the_meeting_only(self):
        one = self.record()
        self.assertEqual(one, self.record())
        self.assertNotEqual(one["turns"], self.record(seed=2)["turns"])


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


class RemoteRecordingTests(unittest.TestCase):
    SPEC = {"millisecondsPerMinute": 13.0, "buffers": [1, 2, 3, 4], "weights": [33, 18, 21, 54]}

    def test_dropouts_are_whole_capture_buffers_and_add_up_to_the_rate(self):
        dropouts = callsim.plan_dropouts(5, "SYN", 360.0, self.SPEC)
        sizes = {round(n * callsim.CAPTURE_BUFFER_FRAMES * RATE / callsim.CAPTURE_RATE) for n in self.SPEC["buffers"]}
        self.assertTrue(all(samples in sizes for _, samples in dropouts))
        lost = sum(samples for _, samples in dropouts) / RATE
        target = 13.0 / 1000 * 6
        self.assertGreaterEqual(lost, target)
        self.assertLess(lost, target + max(sizes) / RATE)
        times = [at for at, _ in dropouts]
        self.assertEqual(times, sorted(times))
        self.assertTrue(all(0 <= at < 360.0 for at in times))

    def test_the_dropouts_depend_on_the_seed_and_the_meeting_only(self):
        one = callsim.plan_dropouts(5, "SYN", 360.0, self.SPEC)
        self.assertEqual(one, callsim.plan_dropouts(5, "SYN", 360.0, self.SPEC))
        self.assertNotEqual(one, callsim.plan_dropouts(5, "OTHER", 360.0, self.SPEC))

    def test_a_late_remote_track_plays_nothing_before_it_starts(self):
        remote = np.ones(RATE * 4, dtype=np.float32) * 0.1
        prepared = callsim.Prepared(
            meeting="SYN", local_agent="A", local_speaker="S", remote=remote,
            local_voice=np.zeros_like(remote), noise=np.zeros_like(remote), echo_unit=remote.copy(),
            path=callsim.make_echo_path(np.random.default_rng(1)), levels={},
        )
        heard = callsim.late_remote(prepared, 1.5)
        cut = int(1.5 * RATE)
        self.assertFalse(np.any(heard.remote[:cut]))
        self.assertTrue(np.array_equal(heard.remote[cut:], remote[cut:]))
        # The echo starts once the call audio does, after the playback delay. The
        # convolution leaves round-off far below a 16-bit step before it.
        self.assertLess(float(np.max(np.abs(heard.echo_unit[:cut]))), 1e-6)
        self.assertTrue(np.any(heard.echo_unit[cut + int(prepared.path.delay_seconds * RATE) + 10 :]))
        self.assertIs(callsim.late_remote(prepared, 0.0), prepared)

    def test_a_late_start_drops_the_first_seconds_of_the_remote_track(self):
        played = np.arange(RATE * 4, dtype=np.float32)
        recorded = callsim.record_remote(played, callsim.RemoteRecording(start_seconds=1.5))
        self.assertEqual(len(recorded), len(played) - int(1.5 * RATE))
        self.assertTrue(np.array_equal(recorded, played[int(1.5 * RATE) :]))

    def test_after_a_dropout_the_remote_track_sits_early_by_what_was_lost(self):
        played = np.arange(RATE * 10, dtype=np.float32)
        recording = callsim.RemoteRecording(dropouts=[(2.0, 683), (6.0, 341)])
        recorded = callsim.record_remote(played, recording)
        self.assertEqual(len(recorded), len(played) - 1024)
        # Before the first loss the file matches what was played.
        self.assertEqual(recorded[RATE], played[RATE])
        # Between the two, each sample is one the speakers played 683 samples later.
        self.assertEqual(recorded[4 * RATE], played[4 * RATE + 683])
        self.assertEqual(recorded[8 * RATE], played[8 * RATE + 1024])


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

    def test_the_local_person_is_on_the_microphone_and_the_others_on_the_remote_track(self):
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
        self.assertLess(loud(remote, 3, 4), 0.1 * loud(remote, 10, 14), "the local person leaked into the call audio")
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

    def test_the_recorded_correlation_is_the_one_the_stored_samples_give(self):
        with tempfile.TemporaryDirectory() as scratch:
            scratch = Path(scratch)
            (scratch / "in").mkdir()
            _, infos = self.build(scratch / "in", scratch / "out")
            stored, _ = callsim.echo_correlation(
                callsim.read_pcm16(scratch / "out/laptop/mic.wav"), callsim.read_pcm16(scratch / "out/laptop/remote.wav")
            )
        self.assertEqual(infos[1]["echo"]["correlation"], round(stored, 4))
        self.assertEqual(callsim.problems(infos[1]), [])

    def test_a_case_off_its_target_or_with_clipped_samples_is_a_problem(self):
        with tempfile.TemporaryDirectory() as scratch:
            scratch = Path(scratch)
            (scratch / "in").mkdir()
            truth, channels = synthetic_meeting(scratch / "in")
            prepared = callsim.prepare_meeting(11, "SYN", truth, "A", channels)
            variant = callsim.render_variant(prepared, "laptop", 0.6)
            # A microphone that holds far more echo than asked for.
            off = callsim.Variant(**{**variant.__dict__, "microphone": variant.microphone + 20 * prepared.echo_unit})
            info = callsim.write_case(scratch / "off", prepared, off, 11, truth)
            self.assertFalse(info["echo"]["reachedTarget"])
            self.assertTrue(any("target" in p for p in callsim.problems(info)))
            loud = callsim.Variant(**{**variant.__dict__, "microphone": variant.microphone * 1000})
            info = callsim.write_case(scratch / "loud", prepared, loud, 11, truth)
            self.assertGreater(info["echo"]["clippedSamples"]["mic"], 0)
            self.assertTrue(any("clipped" in p for p in callsim.problems(info)))

    def test_the_microphone_is_silent_where_only_someone_else_speaks_inside_the_local_speech(self):
        # A pauses from 3.9 s to 4.5 s, short enough for the gate to keep, and
        # B says one word in it, 4.0 s to 4.3 s. Every channel hears a little of the others.
        bursts = {"A": [(2.0, 4.0), (4.5, 8.0)], "B": [(4.0, 4.4), (10.0, 14.0)], "C": [(16.0, 22.0)], "D": [(24.0, 28.0)]}
        with tempfile.TemporaryDirectory() as scratch:
            scratch = Path(scratch)
            (scratch / "in").mkdir()
            truth, channels = synthetic_meeting(scratch / "in", bursts=bursts)
            prepared = callsim.prepare_meeting(11, "SYN", truth, "A", channels)
            variant = callsim.render_variant(prepared, "headphones", None)
            info = callsim.write_case(scratch / "out", prepared, variant, 11, truth)
        voice = prepared.local_voice

        def loud(start, end):
            return float(np.sqrt(np.mean(voice[int(start * RATE) : int(end * RATE)] ** 2)))

        self.assertEqual(loud(4.05, 4.28), 0.0, "B's word is still on the local channel")
        self.assertGreater(loud(2.0, 3.9), 0.01)
        local = info["localChannel"]
        self.assertEqual(local["ownerWordSamplesMuted"], 0)
        self.assertGreater(local["otherSpeechSecondsInGate"], local["otherSpeechSecondsKept"])
        self.assertEqual(callsim.problems(info), [])

    def test_a_case_whose_mute_cut_the_owners_words_or_that_predates_the_mute_is_a_problem(self):
        with tempfile.TemporaryDirectory() as scratch:
            scratch = Path(scratch)
            (scratch / "in").mkdir()
            _, infos = self.build(scratch / "in", scratch / "out")
        info = {**infos[0], "localChannel": {**infos[0]["localChannel"], "ownerWordSamplesMuted": 5}}
        self.assertTrue(any("own words" in p for p in callsim.problems(info)))
        old = {key: value for key, value in infos[0].items() if key != "localChannel"}
        self.assertTrue(any("regenerate" in p for p in callsim.problems(old)))

    def test_a_sensor_record_is_written_beside_the_audio_and_named_in_the_description(self):
        with tempfile.TemporaryDirectory() as scratch:
            scratch = Path(scratch)
            (scratch / "in").mkdir()
            truth, channels = synthetic_meeting(scratch / "in")
            truth["turns"] = [{"speaker": "SPK_B", "start": 9.0, "end": 15.0}]
            prepared = callsim.prepare_meeting(11, "SYN", truth, "A", channels)
            variant = callsim.render_variant(prepared, "headphones", None)
            spec = {"pollSeconds": 0.5, "holdSeconds": 1.5, "dropoutShare": 0.0}
            record = callsim.simulate_sensors(11, "SYN", truth, prepared.local_speaker, spec)
            info = callsim.write_case(scratch / "out", prepared, variant, 11, truth, record)
            path = scratch / "out" / info["files"]["sensors"]["name"]
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), info["files"]["sensors"]["sha256"])
            self.assertEqual(json.loads(path.read_text()), record)
            # Rewriting the case without sensors leaves no stale record behind.
            callsim.write_case(scratch / "out", prepared, variant, 11, truth)
            self.assertFalse(path.exists())
            self.assertNotIn("sensors", json.loads((scratch / "out" / "case.json").read_text())["files"])

    def test_a_misaligned_remote_track_keeps_the_laptop_echo_and_records_what_it_changed(self):
        with tempfile.TemporaryDirectory() as scratch:
            scratch = Path(scratch)
            (scratch / "in").mkdir()
            truth, channels = synthetic_meeting(scratch / "in")
            prepared = callsim.prepare_meeting(11, "SYN", truth, "A", channels)
            variant = callsim.render_variant(prepared, "laptop", 0.6)
            aligned = callsim.write_case(scratch / "aligned", prepared, variant, 11, truth)
            heard = callsim.late_remote(prepared, 1.0)
            late_variant = callsim.render_variant(heard, "late", 0.6)
            late = callsim.write_case(
                scratch / "late", heard, late_variant, 11, truth, remote_recording=callsim.RemoteRecording(start_seconds=1.0)
            )
            gaps = callsim.RemoteRecording(dropouts=[(10.0, 683), (20.0, 683), (30.0, 683)])
            dropped = callsim.write_case(scratch / "gaps", prepared, variant, 11, truth, remote_recording=gaps)
            late_remote, _ = sf.read(scratch / "late/remote.wav")
            gaps_remote, _ = sf.read(scratch / "gaps/remote.wav")
            late_mic = callsim.read_pcm16(scratch / "late/mic.wav")
            self.assertEqual((scratch / "gaps/mic.wav").read_bytes(), (scratch / "aligned/mic.wav").read_bytes())
        self.assertNotIn("farEnd", aligned)
        # Each reaches the laptop's echo level. The target is checked against
        # what the speakers played, not against the recorded file.
        for info in (late, dropped):
            self.assertTrue(info["echo"]["reachedTarget"])
            self.assertEqual(callsim.problems(info), [])
        self.assertAlmostEqual(dropped["echo"]["correlation"], aligned["echo"]["correlation"], delta=0.001)
        # Nothing was played before the call audio started, so the microphone
        # holds only the local person and the room there.
        base = np.round(np.clip(prepared.local_voice + prepared.noise, -1, 1) * callsim.FULL_SCALE_INT16)
        self.assertLessEqual(float(np.max(np.abs(late_mic[:RATE] - base[:RATE]))), 1.0)
        self.assertEqual(len(late_remote), int(truth["windowSeconds"] * RATE) - RATE)
        self.assertEqual(late["farEnd"]["startSeconds"], 1.0)
        self.assertEqual(late["farEnd"]["lostSeconds"], 0.0)
        # Placed at its start time, the late file lines up with the microphone again.
        self.assertAlmostEqual(late["farEnd"]["correlationAsRecorded"], late["echo"]["correlation"], delta=0.02)
        self.assertEqual(len(gaps_remote), int(truth["windowSeconds"] * RATE) - 3 * 683)
        self.assertEqual(dropped["farEnd"]["lostSeconds"], round(3 * 683 / RATE, 4))
        self.assertEqual(len(dropped["farEnd"]["dropouts"]), 3)

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
