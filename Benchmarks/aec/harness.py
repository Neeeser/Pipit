"""Echo canceller bake-off.

Runs every candidate in ``candidates.py`` over one tier of recordings, scores
each output, and writes a JSON result and a Markdown table.

Tiers:
  synthetic   AEC Challenge synthetic validation clips (clean near-end known)
  real        AEC Challenge 2021 real-device blind clips (no clean target)
  meetings    Pipit meeting folders read in place (private, never copied
              anywhere but --work)
  mixes       far-end-only stretches of one private meeting plus user-only
              stretches of another, so the user target is known

Usage:
  python3 harness.py --tier synthetic --work WORK [--candidates a,b] [--limit N]
  python3 harness.py --tier meetings --meetings DIR --work WORK [--seconds 300]
  python3 harness.py --tier mixes --mixes mixes.json --work WORK

Audio is fetched by fetch.py into ~/Library/Caches/pipit-bench/aec. Nothing
here writes into a meeting folder.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass, asdict
from pathlib import Path

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parent))
import candidates as cand  # noqa: E402
import metrics  # noqa: E402

CACHE = Path(os.environ.get("PIPIT_AEC_DATA", "~/Library/Caches/pipit-bench/aec")).expanduser()
RATE = 16000


@dataclass
class Case:
    id: str
    tier: str
    mic: Path
    ref: Path
    truth: Path | None  # clean near-end, when known
    talk_type: str  # st, nst, dt
    seconds: float


# --- case lists ---------------------------------------------------------------


def synthetic_cases(limit: int | None) -> list[Case]:
    rows = json.load(open(CACHE / "synthetic_rows.json"))
    cases = []
    for row in rows[:limit]:
        fid = row["fileid"]
        mic = CACHE / "synthetic/nearend_mic_signal" / f"nearend_mic_fileid_{fid}.wav"
        ref = CACHE / "synthetic/farend_speech" / f"farend_speech_fileid_{fid}.wav"
        truth = CACHE / "synthetic/nearend_speech" / f"nearend_speech_fileid_{fid}.wav"
        if not (mic.exists() and ref.exists() and truth.exists()):
            continue
        cases.append(Case(f"syn{fid}", "synthetic", mic, ref, truth, "dt", 10.0))
    return cases


def real_cases(limit: int | None) -> list[Case]:
    root = CACHE / "real/clean"
    cases = []
    devices = sorted({p.name.split("_")[0] for p in root.glob("*_mic.wav")})
    for device in devices[:limit]:
        for scenario, talk in (("farend_singletalk", "st"), ("nearend_singletalk", "nst"), ("doubletalk", "dt")):
            mic = root / f"{device}_{scenario}_mic.wav"
            ref = root / f"{device}_{scenario}_lpb.wav"
            if not (mic.exists() and ref.exists()):
                continue
            seconds = sf.info(mic).duration
            # Near-end single talk holds no echo, so the untouched microphone is the truth.
            cases.append(Case(f"{device}_{talk}", "real", mic, ref, mic if talk == "nst" else None, talk, seconds))
    return cases


def decode(source: Path, dest: Path, start: float | None = None, seconds: float | None = None) -> Path:
    if dest.exists():
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    command = ["ffmpeg", "-v", "error", "-y"]
    if start is not None:
        command += ["-ss", str(start)]
    if seconds is not None:
        command += ["-t", str(seconds)]
    command += ["-i", str(source), "-ac", "1", "-ar", str(RATE), "-f", "wav", str(dest)]
    subprocess.run(command, check=True)
    return dest


def meeting_cases(meetings: Path, work: Path, start: float, seconds: float | None) -> list[Case]:
    cases = []
    for folder in sorted(meetings.rglob("raw/metadata.json")):
        meeting = folder.parent.parent
        metadata = json.load(open(folder))
        if metadata.get("cleaningOutcome") != "cleaned":
            continue
        mic = meeting / "raw/audio/mic.m4a"
        ref = meeting / "raw/audio/system.m4a"
        if not (mic.exists() and ref.exists()):
            continue
        key = hashlib.sha1(str(meeting).encode()).hexdigest()[:10]
        stem = f"m{key}"
        mic_wav = decode(mic, work / "input" / f"{stem}.mic.wav", start, seconds)
        ref_wav = decode(ref, work / "input" / f"{stem}.ref.wav", start, seconds)
        cases.append(Case(stem, "meetings", mic_wav, ref_wav, None, "dt", sf.info(mic_wav).duration))
    return cases


def mix_cases(spec: Path, work: Path) -> list[Case]:
    """Each entry: {"id", "echo": {"meeting", "start", "seconds"}, "user": {"meeting", "start"}}.

    The echo stretch supplies the far end and its echo in the microphone. The
    user stretch supplies the microphone of a moment where only the user
    spoke. Their sum is the mixed microphone; the user stretch is the truth.
    """
    cases = []
    for entry in json.load(open(spec)):
        if "mic" in entry:
            # Already prepared: microphone, far end and user truth as files.
            cases.append(Case(entry["id"], "mixes", Path(entry["mic"]), Path(entry["ref"]), Path(entry["truth"]), "dt", sf.info(entry["mic"]).duration))
            continue
        seconds = float(entry["echo"]["seconds"])
        echo_dir = Path(entry["echo"]["meeting"])
        user_dir = Path(entry["user"]["meeting"])
        stem = entry["id"]
        echo_mic = decode(echo_dir / "raw/audio/mic.m4a", work / "input" / f"{stem}.echo.wav", entry["echo"]["start"], seconds)
        ref = decode(echo_dir / "raw/audio/system.m4a", work / "input" / f"{stem}.ref.wav", entry["echo"]["start"], seconds)
        user = decode(user_dir / "raw/audio/mic.m4a", work / "input" / f"{stem}.user.wav", entry["user"]["start"], seconds)
        mixed = work / "input" / f"{stem}.mic.wav"
        if not mixed.exists():
            a = cand.read(echo_mic)
            b = cand.read(user)
            n = min(len(a), len(b))
            cand.write(mixed, a[:n] + b[:n])
        cases.append(Case(stem, "mixes", mixed, ref, user, "dt", seconds))
    return cases


# --- transcription ------------------------------------------------------------


def transcribe(files: list[Path], work: Path, tag: str) -> dict[str, dict]:
    """parakeet over every file not already in the cache, one process."""
    cache_dir = work / "asr"
    cache_dir.mkdir(parents=True, exist_ok=True)
    results: dict[str, dict] = {}
    pending = []
    for file in files:
        key = hashlib.sha1(file.read_bytes()).hexdigest()
        cached = cache_dir / f"{key}.json"
        if cached.exists():
            results[str(file)] = json.load(open(cached))
        else:
            pending.append((file, cached))
    if pending:
        out = work / f"asr-{tag}-{int(time.time())}.json"
        command = [str(cand.PIPIT_EVAL), "asr", "--engine", "parakeet", "--json", str(out)]
        for file, _ in pending:
            command += ["--audio", str(file)]
        subprocess.run(command, check=True, capture_output=True)
        by_path = {r["file"]: r for r in json.load(open(out))}
        for file, cached in pending:
            result = by_path[str(file)]
            json.dump(result, open(cached, "w"))
            results[str(file)] = result
        out.unlink()
    return results


# --- scoring ------------------------------------------------------------------


def score_case(case: Case, out: Path, asr: dict, aecmos, skip_seconds: float = 0.0) -> dict:
    mic, ref, output = cand.read(case.mic), cand.read(case.ref), cand.read(out)
    n = min(len(mic), len(ref), len(output))
    mic, ref, output = mic[:n], ref[:n], output[:n]
    row: dict = {"case": case.id, "tier": case.tier, "talk": case.talk_type, "seconds": case.seconds}
    truth = cand.read(case.truth)[:n] if case.truth else None
    if truth is not None and case.talk_type != "nst":
        # Echo-only windows: far end playing and the near end quiet.
        far, near = metrics.window_db(ref), metrics.window_db(truth)
        mask = (far > -60) & (near < -60)
        before, after = metrics.window_db(mic), metrics.window_db(output)
        row["echoRemovedDB"] = float(np.median(before[mask] - after[mask])) if mask.sum() else None
        row["siSdrDB"] = metrics.si_sdr_db(output, truth)
    elif case.talk_type == "st":
        row["echoRemovedDB"] = metrics.echo_removed_db(mic, output, ref)
    elif case.talk_type == "nst":
        row["userLevelChangeDB"] = float(np.median(metrics.window_db(mic) - metrics.window_db(output)))
    else:
        row["echoRemovedDB"] = metrics.echo_removed_db(mic, output, ref)
    row["residualCorrelation"] = metrics.residual_correlation(output, ref)
    if aecmos is not None:
        echo, other = aecmos.score(ref, mic, output, case.talk_type)
        row["aecmosEcho"], row["aecmosOther"] = echo, other
    # A canceller needs a few seconds to find the echo path, and a meeting
    # pays that once. `skip_seconds` keeps a short clip's opening out of the
    # transcript scores.
    def after_start(words):
        return [w for w in words if w.start >= skip_seconds]

    out_words = after_start(metrics.words_from(asr[str(out)]))
    far_words = metrics.words_from(asr[str(case.ref)])
    truth_words = after_start(metrics.words_from(asr[str(case.truth)])) if case.truth else None
    if case.tier == "meetings":
        # No clean target. The user's own words are the microphone's words
        # that the far end did not also say nearby.
        mic_words = after_start(metrics.words_from(asr[str(case.mic)]))
        truth_words = [w for w in mic_words if not metrics._near(w, far_words, 3.0)]
    ts = metrics.transcript_score(out_words, far_words, truth_words)
    row.update(ts.as_dict())
    row["leakedExamples"] = ts.leaked_examples
    return row


def aggregate(rows: list[dict]) -> dict:
    minutes = sum(r["seconds"] for r in rows) / 60
    def med(key):
        values = [r[key] for r in rows if r.get(key) is not None and not np.isnan(r[key])]
        return float(np.median(values)) if values else None
    def mean(key):
        values = [r[key] for r in rows if r.get(key) is not None and not np.isnan(r[key])]
        return float(np.mean(values)) if values else None
    leaked = sum(r["leaked"] for r in rows)
    lost = sum(r["lost"] for r in rows)
    kept = sum(r["kept"] for r in rows)
    return {
        "cases": len(rows),
        "minutes": round(minutes, 1),
        "leakedPerMinute": round(leaked / minutes, 2) if minutes else None,
        "lostPerMinute": round(lost / minutes, 2) if minutes else None,
        "keptShare": round(kept / (kept + lost), 3) if kept + lost else None,
        "echoRemovedMedianDB": med("echoRemovedDB"),
        "siSdrMeanDB": mean("siSdrDB"),
        "userLevelChangeDB": med("userLevelChangeDB"),
        "residualCorrelation": med("residualCorrelation"),
        "aecmosEcho": mean("aecmosEcho"),
        "aecmosOther": mean("aecmosOther"),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tier", required=True, choices=["synthetic", "real", "meetings", "mixes"])
    parser.add_argument("--work", required=True, type=Path)
    parser.add_argument("--candidates", default="all")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--meetings", type=Path)
    parser.add_argument("--mixes", type=Path)
    parser.add_argument("--start", type=float, default=300.0, help="meetings: excerpt start")
    parser.add_argument("--seconds", type=float, help="meetings: excerpt length, whole meeting if unset")
    parser.add_argument("--offset-shift", type=float, default=0.0, help="shift the reference by this many seconds before every candidate")
    parser.add_argument("--no-aecmos", action="store_true")
    parser.add_argument("--skip-seconds", type=float, default=0.0, help="leave each clip's opening out of the transcript scores")
    args = parser.parse_args()

    work = args.work / args.tier
    work.mkdir(parents=True, exist_ok=True)
    if args.tier == "synthetic":
        cases = synthetic_cases(args.limit)
    elif args.tier == "real":
        cases = real_cases(args.limit)
    elif args.tier == "meetings":
        cases = meeting_cases(args.meetings, work, args.start, args.seconds)
        if args.limit:
            cases = cases[: args.limit]
    else:
        cases = mix_cases(args.mixes, work)
    if not cases:
        print("no cases", file=sys.stderr)
        return 1

    if args.offset_shift:
        shifted = []
        for case in cases:
            ref = cand.read(case.ref)
            shift = int(args.offset_shift * RATE)
            moved = np.concatenate([np.zeros(shift, np.float32), ref])[: len(ref)] if shift > 0 else np.concatenate([ref[-shift:], np.zeros(-shift, np.float32)])
            path = work / "input" / f"{case.id}.ref.shift{args.offset_shift}.wav"
            cand.write(path, moved)
            shifted.append(Case(case.id, case.tier, case.mic, path, case.truth, case.talk_type, case.seconds))
        cases = shifted

    # Outputs are cached by path, so a shifted run keeps its own outputs.
    if args.offset_shift:
        work = work / f"shift{args.offset_shift}"
        work.mkdir(parents=True, exist_ok=True)

    everything = cand.all_candidates()
    chosen = everything if args.candidates == "all" else {k: everything[k] for k in args.candidates.split(",")}
    aecmos = None if args.no_aecmos or args.tier in ("meetings", "mixes") else __import__("aecmos").AECMOS()

    static_files = [c.ref for c in cases] + [c.truth for c in cases if c.truth] + ([c.mic for c in cases] if args.tier == "meetings" else [])
    asr = transcribe(sorted(set(static_files)), args.work, "inputs")

    results = {}
    for name, run in chosen.items():
        out_dir = work / "out" / name
        started = time.time()
        outputs = []
        for case in cases:
            out = out_dir / f"{case.id}.wav"
            if not out.exists():
                run(case.mic, case.ref, out)
            outputs.append(out)
        elapsed = time.time() - started
        asr.update(transcribe(outputs, args.work, name))
        rows = [score_case(case, out, asr, aecmos, args.skip_seconds) for case, out in zip(cases, outputs)]
        summary = aggregate(rows)
        summary["processingSeconds"] = round(elapsed, 1)
        results[name] = {"summary": summary, "rows": rows}
        print(f"{name:28s} " + " ".join(f"{k}={v}" for k, v in summary.items()), flush=True)

    tag = f"{args.tier}{'-shift' + str(args.offset_shift) if args.offset_shift else ''}{'-skip' + str(args.skip_seconds) if args.skip_seconds else ''}"
    # A run over a few candidates adds to what earlier runs wrote.
    result_file = args.work / f"results-{tag}.json"
    if result_file.exists():
        merged = json.load(open(result_file))
        merged.update(results)
        results = merged
    json.dump(results, open(result_file, "w"), indent=1)
    with open(args.work / f"results-{tag}.md", "w") as f:
        keys = ["cases", "minutes", "leakedPerMinute", "lostPerMinute", "keptShare", "echoRemovedMedianDB", "siSdrMeanDB", "userLevelChangeDB", "residualCorrelation", "aecmosEcho", "aecmosOther", "processingSeconds"]
        f.write("| candidate | " + " | ".join(keys) + " |\n|" + "---|" * (len(keys) + 1) + "\n")
        for name, r in results.items():
            f.write(f"| {name} | " + " | ".join("" if r["summary"].get(k) is None else (f"{r['summary'][k]:.2f}" if isinstance(r["summary"][k], float) else str(r["summary"][k])) for k in keys) + " |\n")
    print("wrote", args.work / f"results-{tag}.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
