"""Run one of Pipit's own engines on every input through `pipit-eval asr`.

    python3 Benchmarks/engines/run_pipit_engine.py parakeet|whisper [--only GROUPWORD]

Writes out/pipit-<engine>.json. Inputs already in the file are skipped.
"""

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).parent
RUN = Path(os.environ.get("ENGINE_RUN", "~/Library/Caches/pipit-bench/engines")).expanduser()
BIN = HERE.parents[1] / ".build/out/Products/Release/pipit-eval"
engine = sys.argv[1]
only = sys.argv[3] if len(sys.argv) > 3 and sys.argv[2] == "--only" else None
out_path = RUN / "out" / (f"pipit-{engine}.json")
out_path.parent.mkdir(exist_ok=True)
done = json.loads(out_path.read_text()) if out_path.exists() else {}
for item in json.loads((RUN / "inputs.json").read_text()):
    if item["id"] in done or (only and only not in item["group"]):
        continue
    with tempfile.TemporaryDirectory() as scratch:
        result = Path(scratch) / "asr.json"
        # Timed around the whole process, so it includes start-up and model load,
        # which the mlx-audio runner leaves out.
        started = time.monotonic()
        subprocess.run([str(BIN), "asr", "--engine", engine, "--audio", item["wav"], "--json", str(result)],
                       check=True, capture_output=True)
        elapsed = time.monotonic() - started
        words = json.loads(result.read_text())[0]["words"]
    segments = [{"start": w["start"], "end": w["end"], "text": w["text"]} for w in words]
    done[item["id"]] = {"segments": segments, "processingSeconds": elapsed}
    out_path.write_text(json.dumps(done))
    print("%s %s: %d segments, %.0f s" % (engine, item["id"], len(segments), elapsed), flush=True)
