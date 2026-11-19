#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10,<3.14"
# dependencies = ["numpy>=1.26", "scipy>=1.11", "soundfile>=0.12"]
# ///
"""Generate the two-track call suite's audio under ~/Library/Caches/pipit-bench/calls.

    scripts/fetch-bench-audio.sh calls
    Benchmarks/calls/generate.py
    Benchmarks/calls/generate.py --meeting EN2002a --variant laptop --verify

Each case is a directory holding `mic.wav`, `remote.wav` and `case.json`. The
microphone is the local person plus, in the echo variants, the other
participants' call audio replayed over laptop speakers. The remote track is
everyone else after an Opus round trip. The echo gain of each variant is chosen
so Pipit's own measure of how much echo a microphone holds lands on the
variant's target. `--verify` runs the shipped echo pass over the finished
files and prints the figure it reads, which should match.

Nothing is written into the repository, and a rerun with the same inputs writes
the same samples.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import callsim  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
CACHE = Path("~/Library/Caches/pipit-bench").expanduser()


def verify(directory: Path) -> float:
    """What the shipped pass reads as the correlation at the best alignment."""
    binary = Path(os.environ.get("PIPIT_EVAL", ROOT / ".build/debug/pipit-eval"))
    with tempfile.TemporaryDirectory(prefix="pipit-calls-verify-") as scratch:
        report = Path(scratch) / "report.json"
        subprocess.run(
            [
                str(binary), "aec",
                "--mic", str(directory / "mic.wav"),
                "--reference", str(directory / "remote.wav"),
                "--out", str(Path(scratch) / "cleaned.wav"),
                "--json", str(report),
            ],
            check=True, capture_output=True,
        )
        return json.loads(report.read_text())["alignmentCorrelation"]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--meeting", action="append", help="limit to this meeting (repeatable)")
    parser.add_argument("--variant", action="append", help="limit to this variant (repeatable)")
    parser.add_argument("--audio-dir", type=Path, default=CACHE)
    parser.add_argument("--out", type=Path, default=None, help="default: <audio-dir>/calls")
    parser.add_argument("--verify", action="store_true", help="read the finished files with pipit-eval aec")
    args = parser.parse_args()
    out = args.out or args.audio_dir / "calls"

    manifest = json.loads((ROOT / "Benchmarks" / "manifest.json").read_text())
    calls = manifest["calls"]
    seed = calls["seed"]
    variants = [v for v in calls["variants"] if not args.variant or v["name"] in args.variant]
    if not variants:
        raise SystemExit("no variant matches %s" % args.variant)

    print("%-24s %8s %8s %8s %9s" % ("case", "target", "measured", "gain", "echo/voice"))
    for meeting, entry in calls["meetings"].items():
        if args.meeting and meeting not in args.meeting:
            continue
        truth = json.loads((ROOT / "Benchmarks" / "ground-truth" / ("%s.json" % meeting)).read_text())
        agent = callsim.choose_local_agent(seed, meeting, truth)
        if agent != entry["localAgent"]:
            raise SystemExit("%s: the manifest names agent %s, the seed picks %s" % (meeting, entry["localAgent"], agent))
        channels = {}
        for letter, channel in entry["channels"].items():
            path = args.audio_dir / ("%s.Headset-%d.wav" % (meeting, channel["channel"]))
            if not path.exists():
                raise SystemExit("missing %s: run scripts/fetch-bench-audio.sh calls" % path.name)
            channels[letter] = path
        prepared = callsim.prepare_meeting(seed, meeting, truth, agent, channels)
        for spec in variants:
            variant = callsim.render_variant(prepared, spec["name"], spec["echoCorrelation"])
            directory = out / callsim.case_id(meeting, spec["name"])
            callsim.write_case(directory, prepared, variant, seed, truth)
            target = "none" if variant.target_correlation is None else "%.2f" % variant.target_correlation
            ratio = "" if variant.echo_to_voice_db is None else "%+.1f dB" % variant.echo_to_voice_db
            line = "%-24s %8s %8.3f %8.4f %9s" % (
                callsim.case_id(meeting, spec["name"]), target, variant.correlation, variant.gain, ratio,
            )
            if not variant.reached_target:
                line += "  (target not reachable)"
            if args.verify:
                line += "  pipit-eval aec reads %.3f" % verify(directory)
            print(line, flush=True)


if __name__ == "__main__":
    main()
