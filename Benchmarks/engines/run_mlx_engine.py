"""Run an mlx-audio speech engine on every input in inputs.json.

    .venv-stt/bin/python run_mlx_engine.py qwen3-asr|granite-5-2b|granite-470m|nemotron-3.5

Writes out/<engine>.json (input id -> segments, processing seconds, peak memory)
and prints one line per track to progress.log for the heartbeat. Inputs already
done are skipped, so a killed run resumes.
"""

import json
import os
import sys
import time
from pathlib import Path

import mlx.core as mx
import numpy as np
import soundfile
from mlx_audio.stt import load

HERE = Path(__file__).parent
RUN = Path(os.environ.get("ENGINE_RUN", "~/Library/Caches/pipit-bench/engines")).expanduser()
VERBATIM = ("Audio transcription. Language: as spoken. Wording: verbatim, including fillers and "
            "repetitions. Formatting: punctuation and capitalization. Output: transcript only.")
ENGINES = {
    "qwen3-asr": {"model": "mlx-community/Qwen3-ASR-1.7B-8bit", "chunk": None,
                  "kwargs": {"language": "English", "max_tokens": 65536}},
    "granite-5-2b": {"model": "ibm-granite/granite-speech-5.0-2b", "chunk": 90.0,
                     "kwargs": {"language": None, "punctuate": True, "max_tokens": 2048}},
    "granite-470m": {"model": "ibm-granite/granite-speech-5.0-470m-turboctc", "chunk": 90.0, "kwargs": {}},
    "nemotron-3.5": {"model": "nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B-NVFP4", "chunk": None,
                     "kwargs": {"task": "asr", "prompt": VERBATIM, "word_timestamps": True,
                                "max_tokens": 65536}},
}
RATE = 16000


def segments_of(result, offset: float, seconds: float) -> list[dict]:
    found = []
    for s in getattr(result, "segments", None) or []:
        text = s.get("text", "") if isinstance(s, dict) else getattr(s, "text", "")
        start = s.get("start", 0.0) if isinstance(s, dict) else getattr(s, "start", 0.0)
        end = s.get("end", start) if isinstance(s, dict) else getattr(s, "end", start)
        if text and text.strip():
            found.append({"start": float(start) + offset, "end": float(end) + offset, "text": text})
    if not found and (result.text or "").strip():
        found.append({"start": offset, "end": offset + seconds, "text": result.text})
    return found


def chunks(audio: np.ndarray, seconds: float) -> list[tuple[np.ndarray, float]]:
    """Cut at the quietest 100 ms within the last 15 s of each piece."""
    pieces, at, size = [], 0, int(seconds * RATE)
    while at < len(audio):
        end = min(len(audio), at + size)
        if end < len(audio):
            window = audio[end - 15 * RATE: end]
            frames = len(window) // 1600
            energy = np.mean(window[: frames * 1600].reshape(frames, 1600) ** 2, axis=1)
            end = end - 15 * RATE + int(np.argmin(energy)) * 1600 + 800
        pieces.append((audio[at:end], at / RATE))
        at = end
    return pieces


def main() -> None:
    name = sys.argv[1]
    spec = ENGINES[name]
    out_path = RUN / "out" / (f"{name}.json")
    out_path.parent.mkdir(exist_ok=True)
    done = json.loads(out_path.read_text()) if out_path.exists() else {}
    log = open(RUN / "progress.log", "a")
    model = load(spec["model"])
    for item in json.loads((RUN / "inputs.json").read_text()):
        if item["id"] in done:
            continue
        mx.reset_peak_memory()
        started = time.monotonic()
        audio, rate = soundfile.read(item["wav"], dtype="float32")
        assert rate == RATE
        segments = []
        if spec["chunk"]:
            for piece, offset in chunks(audio, spec["chunk"]):
                result = model.generate(mx.array(piece), **spec["kwargs"])
                segments += segments_of(result, offset, len(piece) / RATE)
        else:
            result = model.generate(item["wav"], **spec["kwargs"])
            segments = segments_of(result, 0.0, item["seconds"])
        elapsed = time.monotonic() - started
        peak = mx.get_peak_memory() / 2**30
        done[item["id"]] = {"segments": segments, "processingSeconds": elapsed, "peakGB": round(peak, 2)}
        out_path.write_text(json.dumps(done))
        line = "DONE %s %s %d segments %.0f s peak %.1f GB" % (name, item["id"], len(segments), elapsed, peak)
        print(line, flush=True)
        log.write(line + "\n")
        log.flush()
    del model
    log.write(f"ENGINE-END {name}\n")
    log.flush()


if __name__ == "__main__":
    main()
