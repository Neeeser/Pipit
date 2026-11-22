#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10,<3.14"
# dependencies = ["numpy>=1.26", "soundfile>=0.12", "whisper-normalizer==0.1.12"]
# ///
"""Have a Gemini model transcribe each speaker's voiced lines and compare them with the script.

    GEMINI_API_KEY=... Benchmarks/synthetic/check_audio.py SYN001

The ground truth takes its words from the script, so a line the speech model
skipped, garbled, cut short or padded with words that were never written turns
into a reference error that every engine is charged for. This sends each
speaker's lines, cut from their track at the times in the truth, to a cheap
model that accepts audio, without the script, and aligns its transcript with
the script here. Each line gets a verdict: match, minor (one or two words
differ, and no more than a quarter of the line), mismatch, missing, or
unscored (no words left once normalised, such as "Mm-hmm"). The listener makes mistakes of its own, so a
flagged line is a line to listen to, not proof the audio is wrong.

It uses one request per speaker and writes `<meeting>.audio-check.json` beside
the voices. A rerun sends nothing for a speaker whose audio, lines, model and
prompt are unchanged, and redoes the comparison from the stored transcript.
"""

import argparse
import difflib
import hashlib
import io
import itertools
import json
import re
import sys
from pathlib import Path

import numpy as np
import soundfile

sys.path.insert(0, str(Path(__file__).parent))
# Appended, not prepended: the audit folder has a gemini.py of its own.
sys.path.append(str(Path(__file__).parents[1] / "audit"))
import gemini

from sources import normalise

CACHE = Path("~/Library/Caches/pipit-bench/synthetic").expanduser()
GAP_SECONDS = 1.0
# "unscored": the line has no words once normalised (such as "Mm-hmm"), so the
# comparison cannot judge it.
VERDICTS = ["match", "minor", "mismatch", "missing", "unscored"]
SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "transcript": {"type": "STRING"},
        "problems": {"type": "ARRAY", "items": {"type": "STRING"}},
    },
    "required": ["transcript", "problems"],
}
# The model does not see the script. Shown the script, a model tends to copy it
# back as what it heard, which would pass audio that does not match. Nor is it
# told how many lines to expect: asked for a set number, it fits the speech to
# that number and leaves the rest out.
PROMPT = """Transcribe this audio for a speech recognition benchmark. It is synthetic speech by one voice.

Write everything that is said, from the first word to the last, in order: every word, including filler words,
repetitions and false starts. Do not summarise or leave anything out. If someone laughs, write [laughs].

In problems, name anything a listener would notice besides the words: a word cut off at the start or end, a
sudden change of voice, noise or a click, or speech that is not English. Leave it empty if none.
"""
HOLD = "\x00"
# A line differs this much from the script before it counts as more than a slip.
MINOR_TOKENS = 2


def tokens(text: str) -> list[str]:
    # The audit's normaliser, so number style ("65K", "sixty five k") and
    # punctuation do not count as differences.
    # The normaliser writes amounts as "$98000" whether or not "dollars" was said.
    text = re.sub(r"<[^>]*>", " ", text)
    # "11:00" and "eleven" are the same words; the normaliser would make "1100".
    text = re.sub(r"\b(\d{1,2}):00\b", r"\1", text)
    text = re.sub(r"\ball right\b", "alright", text, flags=re.IGNORECASE)
    return [token.lstrip("$") for token in normalise(text)]


def verdict(differing: int, length: int, heard_any: bool) -> str:
    if length == 0:
        return "unscored"
    if not heard_any:
        return "missing"
    if differing == 0:
        return "match"
    # A slip in a long line is minor; the same count in a short line changes what it says.
    return "minor" if differing <= MINOR_TOKENS and differing * 4 <= length else "mismatch"


def differing_words(lines: list[str], heard: str) -> tuple[list[int], list[bool]]:
    """How many words differ in each script line, and whether any of its words were heard.

    The model numbers what it hears its own way (often by sentence), so the
    whole transcript is aligned with the whole script and each difference is
    charged to the script line it falls in.
    """
    expected, line_of = [], []
    for index, line in enumerate(lines):
        # A line with no words once normalised ("Mm-hmm") holds its place with
        # a token nothing matches, so words heard there are charged to it.
        words = tokens(line) or [HOLD]
        expected += words
        line_of += [index] * len(words)
    got = tokens(heard)
    differing, heard_any = [0] * len(lines), [False] * len(lines)
    matcher = difflib.SequenceMatcher(None, expected, got, autojunk=False)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        # "all right" against "alright" is the same speech written two ways.
        if tag == "equal" or "".join(expected[i1:i2]) == "".join(got[j1:j2]):
            for i in range(i1, i2):
                heard_any[line_of[i]] = True
            continue
        for i in range(i1, i2):
            differing[line_of[i]] += 1
            # Words heard in place of this line's words: it was said, differently.
            if j2 > j1:
                heard_any[line_of[i]] = True
        # Extra heard words go to the line they follow (or the first line).
        extra = (j2 - j1) - (i2 - i1)
        if extra > 0:
            differing[line_of[max(0, min(i2, len(line_of)) - 1)] if line_of else 0] += extra
    return differing, heard_any


def clips_for(truth: dict, script: dict, folder: Path, speaker: str) -> tuple[list[dict], np.ndarray, int]:
    """The speaker's lines in script order, and one audio file of them with gaps between."""
    if len(truth["turns"]) != len(script["turns"]):
        raise SystemExit("the truth has %d turns and the script %d" % (len(truth["turns"]), len(script["turns"])))
    track, rate = soundfile.read(folder / ("{}.{}.wav".format(truth["meeting"], speaker)), dtype="float32")
    gap = np.zeros(int(GAP_SECONDS * rate), dtype=np.float32)
    lines, pieces = [], []
    for placed, written in zip(truth["turns"], script["turns"]):
        if placed["speaker"] != speaker:
            continue
        if written["speaker"] != speaker:
            raise SystemExit("truth and script disagree on who speaks a line")
        lines.append({"line": len(lines) + 1, "text": written["text"], "kind": written["kind"],
                      "start": placed["start"], "end": placed["end"]})
        pieces += [track[int(placed["start"] * rate): int(placed["end"] * rate)], gap]
    return lines, np.concatenate(pieces), rate


def flac(audio: np.ndarray, rate: int) -> bytes:
    buffer = io.BytesIO()
    soundfile.write(buffer, audio, rate, format="FLAC")
    return buffer.getvalue()


def compare(lines: list[dict], heard: str) -> None:
    """Give each line its verdict against the model's transcript of the speaker."""
    differing, heard_any = differing_words([x["text"] for x in lines], heard)
    for line, count, any_heard in zip(lines, differing, heard_any, strict=True):
        line.update(differingWords=count, verdict=verdict(count, len(tokens(line["text"])), any_heard))


def check_speaker(truth: dict, script: dict, folder: Path, speaker: str, model: str) -> dict:
    lines, audio, rate = clips_for(truth, script, folder, speaker)
    answer = json.loads(gemini.text(model, PROMPT, SCHEMA, audio=(flac(audio, rate), "audio/flac"), temperature=0.0))
    for line in lines:
        line["speaker"] = speaker
    compare(lines, answer["transcript"])
    return {"lines": lines, "heard": answer["transcript"], "problems": answer["problems"]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("meeting")
    parser.add_argument("--model", default="gemini-3.5-flash-lite")
    parser.add_argument("--script-dir", type=Path, default=Path(__file__).parent / "scripts")
    parser.add_argument("--out", type=Path, default=CACHE)
    args = parser.parse_args()

    folder = args.out / args.meeting
    truth = json.loads((folder / (f"{args.meeting}.truth.json")).read_text())
    script = json.loads((args.script_dir / (f"{args.meeting}.json")).read_text())
    report_path = folder / f"{args.meeting}.audio-check.json"
    report = json.loads(report_path.read_text()) if report_path.exists() else {"speakers": {}}
    for speaker in truth["speakers"]:
        # A transcript holds only for the model, prompt, script lines, line
        # times, gap and audio it was made from.
        track = folder / f"{args.meeting}.{speaker}.wav"
        lines = [t["text"] for t in script["turns"] if t["speaker"] == speaker]
        times = [(t["start"], t["end"]) for t in truth["turns"] if t["speaker"] == speaker]
        for number, (before, after) in enumerate(itertools.pairwise(times), start=2):
            if after[0] < before[1]:
                print("  %s line %d starts before line %d ends, so their clips share audio"
                      % (speaker, number, number - 1), flush=True)
        recipe = json.dumps([args.model, PROMPT, lines, times, GAP_SECONDS]).encode()
        key = hashlib.sha256(recipe + track.read_bytes()).hexdigest()
        if report["speakers"].get(speaker, {}).get("key") == key:
            # The transcript is reused; the comparison is local and is redone
            # each run so a change to it needs no new requests.
            compare(report["speakers"][speaker]["lines"], report["speakers"][speaker]["heard"])
            continue
        report["speakers"][speaker] = {"key": key, "model": args.model,
                                       **check_speaker(truth, script, folder, speaker, args.model)}
        report_path.write_text(json.dumps(report, indent=1) + "\n")
    # Written again so verdicts redone from stored transcripts are saved too.
    report_path.write_text(json.dumps(report, indent=1) + "\n")

    print("%-6s %6s" % ("voice", "lines") + "".join("%10s" % v for v in VERDICTS) + "%10s" % "problems")
    for speaker, entry in report["speakers"].items():
        lines = entry["lines"]
        counts = [sum(1 for x in lines if x["verdict"] == v) for v in VERDICTS]
        flagged = len(entry["problems"])
        print("%-6s %6d" % (speaker, len(lines)) + "".join("%10d" % c for c in counts) + "%10d" % flagged)
    print("%d requests; details in %s" % (gemini.calls_made, report_path))


if __name__ == "__main__":
    main()
