"""Engine-only comparison: every engine on the same tracks, scored on words alone.

    uv run --python 3.12 --with meeteval==0.4.3 --with whisper-normalizer==0.1.12 \
        python Benchmarks/engines/score.py

Inputs (`inputs.json`, built by `make_inputs.py`) are single tracks: a call's
remote track, a call's local microphone without echo, and an in-person room
microphone. Each engine's output is `out/<engine>.json`, a map from input id to
segments with start, end and text. Word error is one stream per track in time
order (no speaker labels), with the audit's normaliser, so number and acronym
style does not count. Prints a table; writes per-track numbers to scores.json.
"""

import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).parent
RUN = Path(os.environ.get("ENGINE_RUN", "~/Library/Caches/pipit-bench/engines")).expanduser()
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / "Benchmarks/audit"))
from meeteval.io import SegLST
from meeteval.wer import cpwer

from sources import normalise


def seglst(segments):
    """One segment holding the whole track in time order, normalised as one text.

    The normaliser joins spoken numbers only when it sees them together
    ("three point two million" becomes 3200000), so normalising word by word
    would leave reference tokens no engine that writes digits can match.
    """
    text = " ".join(s["text"] for s in sorted(segments, key=lambda s: s["start"]))
    end = max((s["end"] for s in segments), default=0.01)
    return SegLST([{"session_id": "m", "speaker": "x", "start_time": 0.0, "end_time": end,
                    "words": " ".join(normalise(text))}])


def score(ref, hyp):
    result = next(iter(cpwer(seglst(ref), seglst(hyp)).values()))
    return {"wer": result.error_rate, "deletions": result.deletions, "insertions": result.insertions,
            "substitutions": result.substitutions, "length": result.length}


inputs = json.loads((RUN / "inputs.json").read_text())
rows = []
for path in sorted((RUN / "out").glob("*.json")):
    engine = path.stem
    outputs = json.loads(path.read_text())
    for item in inputs:
        if item["id"] in outputs:
            s = score(item["reference"], outputs[item["id"]]["segments"])
            rows.append({"engine": engine, "id": item["id"], "group": item["group"],
                         "seconds": item["seconds"], "rtfx": item["seconds"] / max(outputs[item["id"]]["processingSeconds"], 1e-3), **s})
(RUN / "scores.json").write_text(json.dumps(rows, indent=1))

groups = sorted({r["group"] for r in rows})
engines = sorted({r["engine"] for r in rows})
print("Word error by track type (errors / reference words, all tracks of the type pooled). Lower is better.")
print("RTFx for Pipit's engines includes starting pipit-eval and loading the model for every track.")
print("%-34s" % "engine" + "".join("%22s" % g for g in groups) + "%10s" % "RTFx")
for engine in engines:
    line = "%-34s" % engine
    for g in groups:
        rs = [r for r in rows if r["engine"] == engine and r["group"] == g]
        if rs:
            errors = sum(r["deletions"] + r["insertions"] + r["substitutions"] for r in rs)
            dels = sum(r["deletions"] for r in rs)
            n = sum(r["length"] for r in rs)
            # Error, deletions alone, and how many of the group's tracks the engine finished.
            available = sum(1 for i in inputs if i["group"] == g)
            line += "%22s" % ("%.1f%% del %.1f%% %d/%d" % (100 * errors / n, 100 * dels / n, len(rs), available))
        else:
            line += "%22s" % "-"
    rs = [r for r in rows if r["engine"] == engine]
    line += "%10.1f" % (sum(r["seconds"] for r in rs) / sum(r["seconds"] / r["rtfx"] for r in rs))
    print(line)
