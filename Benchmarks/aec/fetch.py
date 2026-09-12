"""Fetches the public recordings the echo bake-off runs on.

Everything lands in ~/Library/Caches/pipit-bench/aec (or $PIPIT_AEC_DATA) and
nothing is committed: the AEC Challenge clips carry no dataset licence of their
own, so they are fetched from Microsoft's repository each time and verified
against the sha256 in each file's Git LFS pointer.

  synthetic/   AEC Challenge synthetic validation clips (file ids under 500,
               far end nonlinear, first 200): nearend_speech (clean target),
               farend_speech (reference), echo_signal, nearend_mic_signal
  real/clean/  AEC Challenge 2021 real-device blind set, clean half: far-end
               single talk, near-end single talk and double talk pairs
  models/      AECMOS scorer (MIT), DTLN-aec ONNX exports, LocalVQE weights

Usage: python3 fetch.py [--synthetic N] [--jobs 8]
"""

from __future__ import annotations

import argparse
import concurrent.futures as futures
import csv
import hashlib
import json
import os
import sys
import urllib.request
from pathlib import Path

ROOT = Path(os.environ.get("PIPIT_AEC_DATA", "~/Library/Caches/pipit-bench/aec")).expanduser()
RAW = "https://raw.githubusercontent.com/microsoft/AEC-Challenge/main/"
MEDIA = "https://media.githubusercontent.com/media/microsoft/AEC-Challenge/main/"
HYPRNOTE = "https://raw.githubusercontent.com/fastrepl/hyprnote/main/crates/aec/data/models/"
LOCALVQE = "https://huggingface.co/LocalAI-io/LocalVQE/resolve/main/"


def get(url: str, timeout: int = 300) -> bytes:
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return response.read()


def pointer_oid(path: str) -> str | None:
    head = get(RAW + path, 60)[:400].decode("utf-8", "replace")
    for line in head.splitlines():
        if line.startswith("oid sha256:"):
            return line.split(":", 1)[1].strip()
    return None


def fetch_lfs(path: str, dest: Path) -> str:
    if dest.exists() and dest.stat().st_size > 1000:
        return "have"
    try:
        oid = pointer_oid(path)
        data = get(MEDIA + path)
    except Exception as error:  # noqa: BLE001 - one bad file must not stop the rest
        return f"error {path}: {error}"
    if oid and hashlib.sha256(data).hexdigest() != oid:
        return f"checksum {path}"
    dest.parent.mkdir(parents=True, exist_ok=True)
    partial = dest.with_suffix(dest.suffix + ".partial")
    partial.write_bytes(data)
    partial.replace(dest)
    return "ok"


def fetch_plain(url: str, dest: Path) -> str:
    if dest.exists() and dest.stat().st_size > 1000:
        return "have"
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(get(url))
    return "ok"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--synthetic", type=int, default=200)
    parser.add_argument("--jobs", type=int, default=8)
    args = parser.parse_args()
    ROOT.mkdir(parents=True, exist_ok=True)

    meta = ROOT / "meta.csv"
    if not meta.exists():
        meta.write_bytes(get(RAW + "datasets/synthetic/meta.csv"))
    rows = [r for r in csv.DictReader(open(meta)) if int(r["fileid"]) < 500 and r["is_farend_nonlinear"] == "1"]
    rows = rows[: args.synthetic]
    json.dump(rows, open(ROOT / "synthetic_rows.json", "w"), indent=1)

    jobs = []
    for row in rows:
        fid = row["fileid"]
        for folder, stem in (
            ("nearend_speech", "nearend_speech"),
            ("farend_speech", "farend_speech"),
            ("echo_signal", "echo"),
            ("nearend_mic_signal", "nearend_mic"),
        ):
            name = f"{stem}_fileid_{fid}.wav"
            jobs.append((f"datasets/synthetic/{folder}/{name}", ROOT / "synthetic" / folder / name))

    listing = ROOT / "blind_clean_listing.txt"
    if not listing.exists():
        api = "https://api.github.com/repos/microsoft/AEC-Challenge/contents/datasets/blind_test_set/clean?per_page=1000"
        names = [entry["name"] for entry in json.loads(get(api)) if entry["name"].endswith(".wav")]
        listing.write_text("\n".join(names))
    wanted = ("_farend_singletalk_", "_nearend_singletalk_", "_doubletalk_")
    for name in listing.read_text().split():
        if any(w in name for w in wanted) and "with_movement" not in name:
            jobs.append((f"datasets/blind_test_set/clean/{name}", ROOT / "real" / "clean" / name))

    print(f"{len(jobs)} clips", flush=True)
    with futures.ThreadPoolExecutor(args.jobs) as pool:
        results = list(pool.map(lambda job: fetch_lfs(*job), jobs))
    problems = [r for r in results if r not in ("ok", "have")]
    print(f"ok {results.count('ok')} had {results.count('have')} problems {len(problems)}")
    for problem in problems[:10]:
        print(" ", problem)

    models = ROOT / "models"
    for name in ("Run_1663915512_Stage_0.onnx", "Run_1663829550_Stage_0.onnx"):
        fetch_plain(RAW + "AECMOS/AECMOS_local/" + name, models / name)
    for units in (128, 256, 512):
        for part in (1, 2):
            name = f"model_{units}_{part}.onnx"
            fetch_plain(HYPRNOTE + name, models / "dtln" / name)
    for name in (
        "localvqe-v1.4-aec-200K-f32.gguf",
        "localvqe-v1.4-aec-2.7K-f32.gguf",
        "localvqe-v1.2-1.3M-f32.gguf",
        "localvqe-v1.3-4.8M-f32.gguf",
    ):
        fetch_plain(LOCALVQE + name, models / "localvqe" / name)
    print("models ready")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
