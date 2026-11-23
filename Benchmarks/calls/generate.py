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
everyone else after an Opus round trip. The variants that misalign the
tracks take the `laptop` echo level and change the call audio: it starts late,
with nothing played before it, or its file loses short runs of audio. The echo gain of each variant is chosen
so Pipit's own measure of how much echo a microphone holds lands on the
variant's target. `--verify` runs the shipped echo pass over the finished
files and prints the figure it reads, which should match. The figure recorded
in `case.json` is read back from the 16-bit files, and generation exits with an
error when it is more than 0.003 from the target, when more than 0.01% of a
track's samples clip, or when the mute that takes other voices off the local
channel touched a sample of the local person's own words.

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
    rejected: list[str] = []
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
        local = prepared.local_channel
        print(
            "%s local channel: %.1f s where only others speak inside the gate, %.1f s kept after the mute,"
            " %.1f s of others under the local person's words"
            % (meeting, local["otherSpeechSecondsInGate"], local["otherSpeechSecondsKept"], local["otherSpeechSecondsUnderOwnerWords"])
        )
        for spec in variants:
            heard = callsim.late_remote(prepared, spec.get("remoteStartSeconds", 0.0))
            variant = callsim.render_variant(heard, spec["name"], spec["echoCorrelation"])
            directory = out / callsim.case_id(meeting, spec["name"])
            sensors = None
            if spec.get("sensors"):
                sensors = callsim.simulate_sensors(seed, meeting, truth, prepared.local_speaker, spec["sensors"])
            remote_recording = None
            if spec.get("remoteStartSeconds") or spec.get("remoteDropouts"):
                dropouts = []
                if spec.get("remoteDropouts"):
                    dropouts = callsim.plan_dropouts(seed, meeting, truth["windowSeconds"], spec["remoteDropouts"])
                remote_recording = callsim.RemoteRecording(spec.get("remoteStartSeconds", 0.0), dropouts)
            info = callsim.write_case(directory, heard, variant, seed, truth, sensors, remote_recording)
            echo = info["echo"]
            target = "none" if variant.target_correlation is None else "%.2f" % variant.target_correlation
            ratio = "" if variant.echo_to_voice_db is None else "%+.1f dB" % variant.echo_to_voice_db
            line = "%-24s %8s %8.3f %8.4f %9s" % (
                callsim.case_id(meeting, spec["name"]), target, echo["correlation"], variant.gain, ratio,
            )
            if remote_recording is not None:
                moved = info["farEnd"]
                line += "  call audio starts %.2f s late, loses %.0f ms, reads %.3f as recorded" % (
                    moved["startSeconds"], moved["lostSeconds"] * 1000, moved["correlationAsRecorded"],
                )
            for problem in callsim.problems(info):
                line += "  REJECTED: " + problem
                rejected.append("%s: %s" % (callsim.case_id(meeting, spec["name"]), problem))
            if args.verify:
                line += "  pipit-eval aec reads %.3f" % verify(directory)
            print(line, flush=True)
    if rejected:
        raise SystemExit("%d problem(s) in the written cases; do not benchmark them:\n  %s" % (len(rejected), "\n  ".join(rejected)))


if __name__ == "__main__":
    main()
