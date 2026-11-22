#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10,<3.14"
# dependencies = ["numpy>=1.26", "scipy>=1.11", "soundfile>=0.12"]
# ///
"""Voice a synthetic meeting script with Gemini TTS and lay it out as a meeting.

    GEMINI_API_KEY=... Benchmarks/synthetic/synthesize.py Benchmarks/synthetic/scripts/SYN001.json

Writes under ~/Library/Caches/pipit-bench/synthetic/<meeting>/:

- `voices/<speaker>.wav`, each participant's lines in one TTS request, kept so a
  layout change needs no new requests;
- `<meeting>.<speaker>.wav`, each participant's own track on the meeting's
  timeline, the stand-in for a close-talk headset;
- `<meeting>.truth.json`, the ground truth in `Benchmarks/ground-truth` form.

Lines of one speaker are joined with pauses in one request, so every speaker
costs one request and keeps one voice. The reply is cut back into lines by
transcribing it with `pipit-eval asr` (Parakeet), matching the recognised words
to the script, and cutting in the longest silence near each line boundary. The
recogniser only places the cuts; the reference text is the script. Word times
spread each line's words over its voiced span by length: against Parakeet's word times the median
error is about 0.3 s and about 7% of words are more than 1 s off, inside
the 5 s collar tcpWER scores with.
"""

import argparse
import difflib
import hashlib
import io
import itertools
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import scipy.signal
import soundfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gemini

RATE = 16000
CACHE = Path("~/Library/Caches/pipit-bench/synthetic").expanduser()
# Prebuilt voices, alternating so neighbours in the roster differ.
VOICES = ["Kore", "Puck", "Charon", "Aoede", "Fenrir", "Leda", "Orus", "Zephyr", "Iapetus", "Callirrhoe",
          "Enceladus", "Autonoe", "Umbriel", "Despina", "Algenib", "Erinome", "Rasalgethi", "Laomedeia"]
SEPARATOR = " <long pause> <long pause> "
FRAME = 160  # 10 ms
# Fast speech runs near 0.2 s a word, so half that is a line that was not said in full.
MIN_SECONDS_PER_WORD = 0.1


def voiced(audio: np.ndarray, floor_db: float = -45.0) -> np.ndarray:
    frames = len(audio) // FRAME
    power = np.mean(audio[: frames * FRAME].reshape(frames, FRAME).astype(np.float64) ** 2, axis=1)
    level = 10 * np.log10(power + 1e-12)
    on = level > max(floor_db, np.percentile(level, 95) - 40)
    # A loud frame or two alone in a pause is a click or noise, not speech:
    # drop it so it does not stretch a line. Short runs next to speech are the
    # quiet ends of words and stay.
    edges = np.flatnonzero(np.diff(np.concatenate([[0], on.astype(np.int8), [0]])))
    starts, ends = edges[::2], edges[1::2]
    for index, (start, end) in enumerate(zip(starts, ends, strict=True)):
        # The edges of the audio are cuts, not speech, so they count as silence.
        gap_before = start - ends[index - 1] if index > 0 else len(on)
        gap_after = starts[index + 1] - end if index + 1 < len(starts) else len(on)
        if end - start < 3 and gap_before >= 20 and gap_after >= 20:
            on[start:end] = False
    return on


PIPIT_EVAL = Path(os.environ.get("PIPIT_EVAL", Path(__file__).resolve().parents[2] / ".build/out/Products/Release/pipit-eval"))


def tokens(text: str) -> list[str]:
    return re.sub(r"[^a-z0-9' ]", " ", text.lower().replace("<laugh>", " ")).split()


def split_by_alignment(audio: np.ndarray, lines: list[str]) -> list[np.ndarray] | None:
    """Cut a speaker's joined lines apart using where the recogniser heard each line.

    Each cut goes in the longest silence between the start of one line's last
    matched word and just after the start of the next matched line's first
    word. Word ends are not used because the recogniser often stretches a
    word's end across the pause after it. Lines with no matched word take their share of the longest
    silences between the matched lines around them.
    """
    if not PIPIT_EVAL.exists():
        raise SystemExit("%s is not built; run ./scripts/build.sh release, or set PIPIT_EVAL" % PIPIT_EVAL)
    with tempfile.TemporaryDirectory(prefix="pipit-synthetic-") as scratch:
        wav, result = Path(scratch) / "voice.wav", Path(scratch) / "asr.json"
        soundfile.write(wav, audio, RATE, subtype="PCM_16")
        subprocess.run([str(PIPIT_EVAL), "asr", "--engine", "parakeet", "--audio", str(wav), "--json", str(result)],
                       check=True, capture_output=True)
        heard = json.loads(result.read_text())[0]["words"]
    hyp, times = [], []
    for word in heard:
        for token in tokens(word["text"]):
            hyp.append(token)
            times.append((word["start"], word["end"]))
    ref, line_of = [], []
    for index, line in enumerate(lines):
        for token in tokens(line):
            ref.append(token)
            line_of.append(index)
    first: list[tuple[float, float] | None] = [None] * len(lines)  # (start, end) of the first matched word
    last: list[tuple[float, float] | None] = [None] * len(lines)
    for block in difflib.SequenceMatcher(None, ref, hyp, autojunk=False).get_matching_blocks():
        for k in range(block.size):
            line = line_of[block.a + k]
            first[line] = first[line] or times[block.b + k]
            last[line] = times[block.b + k]
    matched = [i for i in range(len(lines)) if first[i] is not None]
    if len(matched) < 0.8 * len(lines):
        return None
    active = voiced(audio)
    speech_start = int(np.argmax(active))
    speech_end = len(active) - int(np.argmax(active[::-1]))
    cuts = [0]
    # Each stretch runs from one matched line (or the start) to the next (or the end).
    for before, after in itertools.pairwise([None, *matched, None]):
        # The cuts between consecutive lines from `before` to `after`, counting
        # the first and last line when the stretch is open at that end.
        boundaries = (len(lines) - 1 if after is None else after) - (0 if before is None else before)
        if boundaries == 0:
            continue
        a = speech_start if before is None else int(last[before][0] * 100)
        # Word starts are reliable, so the window ends just after the next
        # line's first word starts, before a stretched end can reach the pause after it.
        b = speech_end if after is None else max(a + 1, int(first[after][0] * 100) + 10)
        frames = longest_silences(active, a, b, boundaries)
        if frames is None:
            return None
        cuts += [frame * FRAME for frame in frames]
    cuts.append(len(audio))
    if any(b <= a for a, b in itertools.pairwise(cuts)):
        return None
    pieces = trimmed(audio, cuts)
    for index in range(len(lines)):
        # A line the recogniser did not hear may be one the speech model never
        # said; a piece far too short for its words means the truth would hold
        # words the audio does not.
        if pieces is not None and first[index] is None:
            if len(pieces[index]) / RATE < MIN_SECONDS_PER_WORD * len(tokens(lines[index])):
                print("  line %d seems to be missing from the audio: %r" % (index + 1, lines[index]), flush=True)
                return None
    return pieces


def trimmed(audio: np.ndarray, cuts: list[int]) -> list[np.ndarray] | None:
    """The audio between consecutive cuts, each trimmed to its voiced span; None if one is silent."""
    pieces = []
    for a, b in itertools.pairwise(cuts):
        piece = audio[a:b]
        on = voiced(piece) if len(piece) >= FRAME else np.zeros(0, dtype=bool)
        if not on.any():
            return None
        lo, hi = int(np.argmax(on)), len(on) - int(np.argmax(on[::-1]))
        pieces.append(piece[max(0, lo - 3) * FRAME: (hi + 3) * FRAME])
    return pieces


def longest_silences(active: np.ndarray, a: int, b: int, count: int) -> list[int] | None:
    """The middles of the `count` longest silent runs in frames a..b, in time order."""
    runs, start = [], None
    for offset, on in enumerate(active[a:b]):
        if not on and start is None:
            start = offset
        elif on and start is not None:
            runs.append((offset - start, a + (start + offset) // 2))
            start = None
    if start is not None:  # a silence that runs to the end of the stretch
        runs.append((b - a - start, a + (start + b - a) // 2))
    if len(runs) < count:
        return None
    return sorted(middle for _, middle in sorted(runs, reverse=True)[:count])


def load(wav: bytes) -> np.ndarray:
    audio, rate = soundfile.read(io.BytesIO(wav), dtype="float32")
    return scipy.signal.resample_poly(audio, RATE, rate).astype(np.float32)


def request_key(model: str, voice: str, words: str) -> str:
    return hashlib.sha256(json.dumps([model, voice, words]).encode()).hexdigest()


def cached_speech(path: Path, model: str, voice: str, words: str) -> bytes:
    """The voice file for `words`, from the cache when it came from the same request."""
    key_path = path.with_suffix(".key")
    key = request_key(model, voice, words)
    if path.exists():
        if not key_path.exists():
            # A voice file from before keys were stored: keep it and record its key.
            key_path.write_text(key + "\n")
        elif key_path.read_text().strip() != key:
            raise SystemExit("%s was voiced from a different script, voice or model; delete it to voice it again" % path)
        return path.read_bytes()
    wav = gemini.speech(model, words, voice)
    path.write_bytes(wav)
    key_path.write_text(key + "\n")
    return wav


def voice_speaker(script: dict, speaker: str, voice: str, folder: Path, model: str,
                  per_line: bool) -> list[np.ndarray]:
    lines = [t["text"] for t in script["turns"] if t["speaker"] == speaker]
    audio = load(cached_speech(folder / ("%s.wav" % speaker), model, voice, SEPARATOR.join(lines)))
    # Alignment checks the words. Cutting at the longest silences alone can
    # pick a pause inside a line and still return the right number of pieces.
    # One line needs no cutting, and voicing it again would repeat this request.
    pieces = trimmed(audio, [0, len(audio)]) if len(lines) == 1 else split_by_alignment(audio, lines)
    if pieces is not None:
        return pieces
    if not per_line:
        raise SystemExit("%s: %d lines did not split cleanly. Voicing them one at a time costs %d requests; "
                         "rerun with --per-line to allow it" % (speaker, len(lines), len(lines)))
    print("  %s: %d lines did not split cleanly, voicing them one at a time" % (speaker, len(lines)), flush=True)
    pieces = []
    for index, line in enumerate(lines):
        audio = load(cached_speech(folder / ("%s.%03d.wav" % (speaker, index)), model, voice, line))
        on = voiced(audio)
        lo, hi = int(np.argmax(on)), len(on) - int(np.argmax(on[::-1]))
        pieces.append(audio[max(0, lo - 3) * FRAME: (hi + 3) * FRAME])
    return pieces


def layout(script: dict, clips: dict[str, list[np.ndarray]], seed: int, talk_over: float) -> tuple[dict[str, np.ndarray], list[dict]]:
    """Place every line on one timeline. Returns each speaker's track and the placed lines.

    `talk_over` is the share of ordinary turns that also start before the
    previous speaker finishes, on top of the script's own interruptions.
    """
    rng = np.random.default_rng(seed)
    taken = {s: 0 for s in clips}
    free_at = {s: 0.0 for s in clips}  # when each speaker's previous line ends
    placed = []
    cursor = 1.0  # end of the last main turn, in seconds
    last_main = None
    for turn in script["turns"]:
        clip = clips[turn["speaker"]][taken[turn["speaker"]]]
        taken[turn["speaker"]] += 1
        seconds = len(clip) / RATE
        same = last_main is not None and last_main["speaker"] == turn["speaker"]
        if turn["kind"] == "backchannel" and last_main is not None and not same:
            # Somewhere inside the turn it answers, or just after it.
            start = float(rng.uniform(last_main["start"] + 0.3, last_main["end"] + 0.2))
        elif last_main is not None and not same and (turn["kind"] == "interrupt" or rng.random() < talk_over):
            start = max(last_main["start"] + 0.5, cursor - float(rng.uniform(0.4, 2.5)))
        else:
            start = cursor + float(rng.uniform(0.15, 0.9))
        # One voice cannot say two lines at once.
        start = max(start, free_at[turn["speaker"]] + 0.2)
        line = {"speaker": turn["speaker"], "text": turn["text"], "kind": turn["kind"],
                "start": round(start, 3), "end": round(start + seconds, 3), "clip": clip}
        placed.append(line)
        free_at[turn["speaker"]] = line["end"]
        if turn["kind"] != "backchannel":
            cursor = max(cursor, line["end"])
            last_main = line
    total = max(line["end"] for line in placed) + 1.0
    tracks = {s: np.zeros(int(total * RATE), dtype=np.float32) for s in clips}
    for line in placed:
        a = int(line["start"] * RATE)
        tracks[line["speaker"]][a: a + len(line["clip"])] += line["clip"]
    return tracks, placed


def words_of(line: dict) -> list[dict]:
    """Spread the line's words over its voiced span by character count."""
    # Tags such as <laugh> are not words, and punctuation left alone after one is not either.
    words = [w for w in re.sub(r"<[^>]*>", " ", line["text"]).split() if re.search(r"[A-Za-z0-9]", w)]
    if not words:
        return []
    on = voiced(line["clip"])
    lo, hi = int(np.argmax(on)), len(on) - int(np.argmax(on[::-1]))
    begin, span = line["start"] + lo * FRAME / RATE, max(0.05, (hi - lo) * FRAME / RATE)
    weights = np.array([len(w) + 1 for w in words], dtype=float)
    edges = np.concatenate([[0], np.cumsum(weights)]) / weights.sum() * span + begin
    return [{"agent": line["speaker"], "speaker": line["speaker"], "text": w, "truncated": False,
             "start": round(float(edges[i]), 3), "end": round(float(edges[i + 1]), 3)} for i, w in enumerate(words)]


def overlap_ratio(placed: list[dict], total: float) -> float:
    count = np.zeros(int(total * 100) + 1, dtype=np.int16)
    for line in placed:
        count[int(line["start"] * 100): int(line["end"] * 100)] += 1
    speech = np.sum(count > 0)
    return round(float(np.sum(count > 1) / max(1, speech)), 4)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("script", type=Path)
    parser.add_argument("--model", default="gemini-3.8-flash-tts")
    parser.add_argument("--seed", type=int, default=20261122)
    parser.add_argument("--talk-over", type=float, default=0.35,
                        help="share of ordinary turns that start before the previous one ends")
    parser.add_argument("--out", type=Path, default=CACHE)
    parser.add_argument("--per-line", action="store_true",
                        help="when a speaker's lines cannot be cut apart, voice each line with its own request")
    args = parser.parse_args()

    script = json.loads(args.script.read_text())
    meeting = script["meeting"]
    folder = args.out / meeting
    (folder / "voices").mkdir(parents=True, exist_ok=True)
    speakers = sorted({t["speaker"] for t in script["turns"]})
    if len(speakers) > len(VOICES):
        raise SystemExit("%d speakers but only %d distinct voices; add voices to VOICES" % (len(speakers), len(VOICES)))
    voices = dict(zip(speakers, VOICES, strict=False))
    clips = {}
    for speaker in speakers:
        clips[speaker] = voice_speaker(script, speaker, voices[speaker], folder / "voices", args.model, args.per_line)
        print("  %s (%s): %d lines voiced, %d requests so far" % (speaker, voices[speaker], len(clips[speaker]), gemini.calls_made), flush=True)

    tracks, placed = layout(script, clips, args.seed, args.talk_over)
    total = len(next(iter(tracks.values()))) / RATE
    for speaker, track in tracks.items():
        soundfile.write(folder / (f"{meeting}.{speaker}.wav"), track, RATE, subtype="PCM_16")
    words = sorted((w for line in placed for w in words_of(line)), key=lambda w: w["start"])
    turns = [{"speaker": line["speaker"], "start": line["start"], "end": line["end"]} for line in placed]
    truth = {
        "meeting": meeting, "source": f"{meeting}.mix.wav", "agentToSpeaker": {s: s for s in speakers},
        "speakers": speakers, "turns": turns, "words": words, "windowStart": 0.0, "windowSeconds": round(total, 2),
        "overlapRatio": overlap_ratio(placed, total),
        "synthetic": {"script": str(args.script), "ttsModel": args.model, "voices": voices, "seed": args.seed, "talkOver": args.talk_over,
                      "localSpeaker": script["localSpeaker"]},
    }
    (folder / (f"{meeting}.truth.json")).write_text(json.dumps(truth, indent=1) + "\n")
    print("%s: %.1f min, %d speakers, %d words, overlap %.1f%%, %d TTS requests"
          % (meeting, total / 60, len(speakers), len(words), 100 * truth["overlapRatio"], gemini.calls_made))


if __name__ == "__main__":
    main()
