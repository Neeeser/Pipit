#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10,<3.14"
# dependencies = ["numpy>=1.26", "scipy>=1.11", "soundfile>=0.12"]
# ///
"""Render a voiced synthetic meeting as benchmark cases, one per meeting type.

    Benchmarks/synthetic/make_cases.py SYN001

Reads what `synthesize.py` wrote under ~/Library/Caches/pipit-bench/synthetic/<meeting>
and writes a benchmark root beside it, `.../synthetic/bench/`, that
`pipit-eval bench --benchmarks` and `--audio-dir` can point at:

- `calls/<meeting>-headphones` and `calls/<meeting>-laptop`: the local person on
  the microphone and everyone else on the remote track, through the same
  simulator as the AMI call suite (`Benchmarks/calls/callsim.py`), with its
  Opus round trip, laptop-speaker echo and microphone noise;
- `ground-truth/<meeting>.json` and `<meeting>.mix.wav`: an in-person meeting,
  everyone in one room on one laptop microphone, each voice through its own
  synthetic room response at its own distance, plus room noise.
"""

import argparse
import json
import shutil
import sys
import tempfile
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Benchmarks" / "calls"))
import callsim

CACHE = Path("~/Library/Caches/pipit-bench/synthetic").expanduser()
VARIANTS = [{"name": "headphones", "echoCorrelation": None}, {"name": "laptop", "echoCorrelation": 0.69}]
ROOM_NOISE_DB = -55.0


def in_person(meeting: str, folder: Path, truth: dict, seed: int) -> np.ndarray:
    rng = callsim.seeded(seed, meeting, "room")
    mix = None
    for speaker in truth["speakers"]:
        voice = callsim.read_channel(folder / (f"{meeting}.{speaker}.wav"), None, None)
        room = callsim.make_echo_path(rng)
        # The impulse starts with a playback delay meant for a laptop speaker;
        # a person in the room is heard at once, so start at the direct path.
        impulse = room.impulse[int(room.delay_seconds * callsim.RATE):]
        heard = callsim.scipy.signal.oaconvolve(voice, impulse)[: len(voice)]
        heard *= 10 ** (float(rng.uniform(-9.0, 0.0)) / 20)  # distance from the laptop
        mix = heard if mix is None else mix + heard
    mix = mix + callsim.pink_noise(rng, len(mix), ROOM_NOISE_DB)
    return (mix * (0.5 / max(1e-6, float(np.max(np.abs(mix)))))).astype(np.float32)


def changed_files(staged: Path, bench: Path) -> list[str]:
    """Audio and truth files under `staged` that already exist under `bench` with other bytes.

    `case.json` is left out: results record checksums of the audio and the truth.
    """
    changed = []
    for path in sorted(staged.rglob("*")):
        relative = path.relative_to(staged)
        if not path.is_file() or path.name == "case.json" or path.suffix not in (".wav", ".json"):
            continue
        existing = bench / relative
        if existing.exists() and existing.read_bytes() != path.read_bytes():
            changed.append(relative.as_posix())
    return changed


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("meeting")
    parser.add_argument("--out", type=Path, default=CACHE)
    parser.add_argument("--overwrite", action="store_true",
                        help="replace case audio and truth already written when they differ")
    args = parser.parse_args()

    meeting, folder = args.meeting, args.out / args.meeting
    truth = json.loads((folder / (f"{meeting}.truth.json")).read_text())
    seed = truth["synthetic"]["seed"]
    local = truth["synthetic"]["localSpeaker"]
    bench = args.out / "bench"
    bench.mkdir(parents=True, exist_ok=True)

    # Render into a staging folder first, so a changed simulator cannot replace
    # audio that recorded results carry checksums of before anyone notices.
    with tempfile.TemporaryDirectory(dir=bench) as staging_name:
        staged = Path(staging_name)
        (staged / "ground-truth").mkdir()
        (staged / "ground-truth" / (f"{meeting}.json")).write_text(json.dumps(truth, indent=1) + "\n")
        channels = {s: folder / (f"{meeting}.{s}.wav") for s in truth["speakers"]}
        prepared = callsim.prepare_meeting(seed, meeting, truth, local, channels)
        for spec in VARIANTS:
            variant = callsim.render_variant(prepared, spec["name"], spec["echoCorrelation"])
            info = callsim.write_case(staged / "calls" / callsim.case_id(meeting, spec["name"]), prepared, variant, seed, truth)
            print("{}: echo correlation {:.3f} {}".format(info["case"], info["echo"]["correlation"], callsim.problems(info) or "ok"))
        callsim.write_pcm16(staged / "ground-truth" / truth["source"], in_person(meeting, folder, truth, seed))

        if changed := changed_files(staged, bench):
            if not args.overwrite:
                raise SystemExit("this would replace files that differ from the ones in %s: %s; pass --overwrite to replace them, "
                                 "or --out to write elsewhere" % (bench, ", ".join(changed)))
        shutil.copytree(staged, bench, dirs_exist_ok=True)

    # Keep the meetings made before, so their cases stay runnable.
    existing = bench / "manifest.json"
    meetings = json.loads(existing.read_text())["calls"]["meetings"] if existing.exists() else {}
    manifest = json.loads((ROOT / "Benchmarks" / "manifest.json").read_text())
    manifest["calls"]["meetings"] = {**meetings, meeting: {"localAgent": local, "channels": {}}}
    manifest["calls"]["variants"] = VARIANTS
    (bench / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("{} in person: {}".format(meeting, bench / "ground-truth" / truth["source"]))


if __name__ == "__main__":
    main()
