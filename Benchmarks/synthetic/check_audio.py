#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10,<3.14"
# dependencies = ["numpy>=1.26", "soundfile>=0.12"]
# ///
"""Have a Gemini model listen to each voiced line and say whether it matches the script.

    GEMINI_API_KEY=... Benchmarks/synthetic/check_audio.py SYN001

The ground truth takes its words from the script, so a line the speech model
skipped, garbled, cut short or padded with words that were never written turns
into a reference error that every engine is charged for. This sends each
speaker's lines, cut from their track at the times in the truth, to a cheap
model that accepts audio and asks it to compare what it hears with the script.
It uses one request per speaker and writes `<meeting>.audio-check.json` beside
the voices.
"""

import argparse
import hashlib
import io
import json
import sys
from pathlib import Path

import numpy as np
import soundfile

sys.path.insert(0, str(Path(__file__).parent))
import gemini

CACHE = Path("~/Library/Caches/pipit-bench/synthetic").expanduser()
GAP_SECONDS = 1.0
VERDICTS = ["match", "minor", "mismatch", "missing"]
SCHEMA = {
    "type": "OBJECT",
    "properties": {"lines": {"type": "ARRAY", "items": {
        "type": "OBJECT",
        "properties": {
            "line": {"type": "INTEGER"},
            "verdict": {"type": "STRING", "enum": VERDICTS},
            "heard": {"type": "STRING"},
            "problems": {"type": "ARRAY", "items": {"type": "STRING"}},
        },
        "required": ["line", "verdict", "heard", "problems"],
    }}},
    "required": ["lines"],
}
PROMPT = """You are checking synthetic speech for a speech recognition benchmark.

The audio holds {count} numbered lines spoken by one voice, in order, with about one second of silence between lines.
The script for each line is below. For every line, write down what you hear, then compare it with the script:

- match: the same words.
- minor: one or two filler words or a repeated word differ, and nothing else.
- mismatch: words that change the content were dropped, added, or replaced, or the line is cut off.
- missing: you cannot find this line in the audio.

In problems, name anything else a listener would notice: a word cut off at the start or end, a markup tag such as
<laugh> read out as a word, a sudden change of voice, noise, or speech that is not English. Leave it empty if none.

Script:
{lines}
"""


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


def check_speaker(truth: dict, script: dict, folder: Path, speaker: str, model: str) -> list[dict]:
    lines, audio, rate = clips_for(truth, script, folder, speaker)
    prompt = PROMPT.format(count=len(lines), lines="\n".join("%d. %s" % (x["line"], x["text"]) for x in lines))
    answer = json.loads(gemini.text(model, prompt, SCHEMA, audio=(flac(audio, rate), "audio/flac"), temperature=0.0))
    verdicts = {a["line"]: a for a in answer["lines"]}
    for line in lines:
        found = verdicts.get(line["line"], {"verdict": "missing", "heard": "", "problems": ["no answer for this line"]})
        line.update(speaker=speaker, verdict=found["verdict"], heard=found["heard"], problems=found["problems"])
    return lines


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("meeting")
    parser.add_argument("--model", default="gemini-3.8-flash-lite")
    parser.add_argument("--script-dir", type=Path, default=Path(__file__).parent / "scripts")
    parser.add_argument("--out", type=Path, default=CACHE)
    args = parser.parse_args()

    folder = args.out / args.meeting
    truth = json.loads((folder / (f"{args.meeting}.truth.json")).read_text())
    script = json.loads((args.script_dir / (f"{args.meeting}.json")).read_text())
    report_path = folder / f"{args.meeting}.audio-check.json"
    report = json.loads(report_path.read_text()) if report_path.exists() else {"speakers": {}}
    for speaker in truth["speakers"]:
        # A verdict holds only for the model, script lines and audio it was made from.
        track = folder / f"{args.meeting}.{speaker}.wav"
        lines = [t["text"] for t in script["turns"] if t["speaker"] == speaker]
        key = hashlib.sha256(json.dumps([args.model, lines]).encode() + track.read_bytes()).hexdigest()
        if report["speakers"].get(speaker, {}).get("key") == key:
            continue
        report["speakers"][speaker] = {"key": key, "model": args.model,
                                       "lines": check_speaker(truth, script, folder, speaker, args.model)}
        report_path.write_text(json.dumps(report, indent=1) + "\n")

    print("%-6s %6s" % ("voice", "lines") + "".join("%10s" % v for v in VERDICTS) + "%10s" % "problems")
    for speaker, entry in report["speakers"].items():
        lines = entry["lines"]
        counts = [sum(1 for x in lines if x["verdict"] == v) for v in VERDICTS]
        flagged = sum(1 for x in lines if x["problems"])
        print("%-6s %6d" % (speaker, len(lines)) + "".join("%10d" % c for c in counts) + "%10d" % flagged)
    print("%d requests; details in %s" % (gemini.calls_made, report_path))


if __name__ == "__main__":
    main()
