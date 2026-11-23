"""Build inputs.json: the tracks every engine transcribes, with their references.

AMI calls: the four six-minute meetings, far-end track from the `laptop` case
and the local microphone from the `headphones` case (no echo). Synthetic pilot:
the same two tracks plus the in-person room microphone, when they exist.
"""

import json
import os
from pathlib import Path

import soundfile

HERE = Path(__file__).parent
RUN = Path(os.environ.get("ENGINE_RUN", "~/Library/Caches/pipit-bench/engines")).expanduser()
ROOT = HERE.parents[1]
CACHE = Path("~/Library/Caches/pipit-bench").expanduser()


def reference(words, keep):
    return [{"start": w["start"], "end": w["end"], "text": w["text"]} for w in words if keep(w)]


def add(items, ident, group, wav, words):
    items.append({"id": ident, "group": group, "wav": str(wav), "seconds": soundfile.info(wav).duration,
                  "reference": words})


items = []
for meeting in ["EN2002a", "EN2002b", "EN2002d", "IS1009a"]:
    truth = json.loads((ROOT / (f"Benchmarks/ground-truth/{meeting}.json")).read_text())
    case = json.loads((CACHE / (f"calls/{meeting}-laptop/case.json")).read_text())
    local = case["localSpeaker"]
    add(items, meeting + "-far-end", "ami far end", CACHE / (f"calls/{meeting}-laptop/remote.wav"),
        reference(truth["words"], lambda w: w["speaker"] != local))
    add(items, meeting + "-mic", "ami local mic", CACHE / (f"calls/{meeting}-headphones/mic.wav"),
        reference(truth["words"], lambda w: w["speaker"] == local))

bench = CACHE / "synthetic/bench"
for truth_path in sorted((bench / "ground-truth").glob("*.json")):
    truth = json.loads(truth_path.read_text())
    meeting, local = truth["meeting"], truth["synthetic"]["localSpeaker"]
    add(items, meeting + "-far-end", "synthetic far end", bench / (f"calls/{meeting}-laptop/remote.wav"),
        reference(truth["words"], lambda w: w["speaker"] != local))
    add(items, meeting + "-mic", "synthetic local mic", bench / (f"calls/{meeting}-headphones/mic.wav"),
        reference(truth["words"], lambda w: w["speaker"] == local))
    add(items, meeting + "-room", "synthetic in person", bench / "ground-truth" / truth["source"],
        reference(truth["words"], lambda w: True))

(RUN / "inputs.json").write_text(json.dumps(items, indent=1))
print("%d tracks, %.0f minutes" % (len(items), sum(i["seconds"] for i in items) / 60))
