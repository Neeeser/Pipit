"""Re-score the stored Whisper size and decode-setting runs from their transcripts.

    uv run --python 3.12 --with meeteval==0.4.3 --with whisper-normalizer==0.1.12 \
        python Benchmarks/engines/rescore_whisper_runs.py

Reads `pipeline-transcripts.json.gz` and `whisper-runs.json` in the results
folder of 2026-11-22 (or the folder given as the first argument), scores each
AMI call transcript with speaker-attributed cpWER against
`Benchmarks/ground-truth`, and compares with the stored `rescored` numbers.
`cpwer_plain` lowercases and keeps letters, digits and apostrophes, like the
bench scorer; `cpwer_audit` uses the meeting audit's normaliser. Every run in
that folder reproduces its stored numbers to the last digit. Prints the largest
difference and the runs that exceed the tolerance, and exits 1 if any do.
"""

import gzip
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Benchmarks/audit"))
from meeteval.io import SegLST  # noqa: E402
from meeteval.wer import cpwer  # noqa: E402
from sources import normalise as audit_normalise  # noqa: E402

DEFAULT_FOLDER = ROOT / "Benchmarks/results/2026-11-22-engines-and-synthetic-pilot"
TOLERANCE = 1e-9


def plain_normalise(text: str) -> list[str]:
    text = text.lower().replace("’", "'")
    return re.sub(r"[^a-z0-9']", " ", text).split()


def seglst(segments: list[dict], normalise) -> SegLST:
    rows = []
    for s in segments:
        words = " ".join(normalise(s["text"]))
        if words:
            rows.append({"session_id": "m", "speaker": s["speaker"], "start_time": s["start"],
                         "end_time": max(s["end"], s["start"] + 0.01), "words": words})
    return SegLST(rows)


def reference(meeting: str) -> list[dict]:
    truth = json.loads((ROOT / f"Benchmarks/ground-truth/{meeting}.json").read_text())
    segments: list[dict] = []
    for w in sorted(truth["words"], key=lambda w: w["start"]):
        last = segments[-1] if segments else None
        if last and last["speaker"] == w["speaker"] and w["start"] - last["end"] < 1.0:
            last["text"] += " " + w["text"]
            last["end"] = w["end"]
        else:
            segments.append({"speaker": w["speaker"], "start": w["start"], "end": w["end"], "text": w["text"]})
    return segments


def rate(ref: list[dict], hyp: list[dict], normalise) -> float:
    return next(iter(cpwer(seglst(ref, normalise), seglst(hyp, normalise)).values())).error_rate


def main() -> int:
    folder = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_FOLDER
    transcripts = json.loads(gzip.open(folder / "pipeline-transcripts.json.gz").read())
    stored = {(r["engine"], r["case"]): r for r in json.loads((folder / "whisper-runs.json").read_text())["rescored"]}
    worst, failures = 0.0, []
    for (engine, case), want in sorted(stored.items()):
        hyp = transcripts.get(f"{case}/{engine}")
        if hyp is None:
            failures.append((engine, case, "no stored transcript"))
            continue
        ref = reference(case.split("-")[0])
        for field, norm in (("cpwer_plain", plain_normalise), ("cpwer_audit", audit_normalise)):
            diff = abs(rate(ref, hyp, norm) - want[field])
            worst = max(worst, diff)
            if diff > TOLERANCE:
                failures.append((engine, case, f"{field} differs by {diff:.4f}"))
    print(f"{len(stored)} runs re-scored; largest difference {worst:.2e}")
    for f in failures:
        print("FAIL", *f)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
