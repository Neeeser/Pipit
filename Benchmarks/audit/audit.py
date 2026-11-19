#!/usr/bin/env python3
"""Audit Pipit's transcripts of your own meetings against reference transcribers.

There is no human transcript of a real meeting, so this compares Pipit with
strong reference models ("teachers") and with each other. Where two independent
references agree, their reading is likely right; where Pipit alone differs, the
error is likely Pipit's. Everything runs on this Mac unless you pass
--allow-cloud to the gemini teacher. See Benchmarks/audit/README.md.

    audit.py prepare --since 2026-10-01 --limit 10
    audit.py teach --teacher vibevoice --tracks mic,system
    audit.py teach --teacher moss --tracks mixed,mic,system
    audit.py score
    audit.py report
    audit.py diarizers --fluidaudio-cli PATH      # optional

Run it with the scoring dependency available, for example
`uv run --python 3.12 --with meeteval Benchmarks/audit/audit.py score`.
Output goes under --work (default ~/Library/Caches/pipit-bench/audit), never
into the repository. Printed output holds only counts and rates.
"""

import argparse
import json
import os
import subprocess
import sys
from itertools import combinations
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from sources import normalise, pipit_segments, pipit_words, split_segments, teacher_segments  # noqa: E402

DEFAULT_WORK = Path.home() / "Library" / "Caches" / "pipit-bench" / "audit"
TRACK_FILES = {"mixed": "recording.m4a", "mic": "raw/audio/mic.cleaned.m4a", "system": "raw/audio/system.m4a"}
# Reference preference: separate-track runs first, since they keep overlapping speech
# and cannot mix up the local person with a remote one.
REFERENCES = ["split-vibevoice", "split-moss", "mixed-moss", "mixed-vibevoice", "mixed-gemini"]


def pipit_json(*args: str) -> dict:
    return json.loads(subprocess.check_output(["pipit", *args, "--json"]))


def meetings(work: Path) -> list[dict]:
    path = work / "meetings.json"
    if not path.exists():
        sys.exit(f"no {path}; run prepare first")
    return json.loads(path.read_text())


# prepare ---------------------------------------------------------------------------

def prepare(args) -> None:
    work = args.work
    if args.ids:
        ids = args.ids.split(",")
    else:
        query = ["meetings", "list", "--limit", str(args.limit * 4)]
        if args.since:
            query += ["--since", args.since]
        listing = pipit_json(*query)
        items = listing if isinstance(listing, list) else listing["meetings"]
        ids = [m["id"] for m in items
               if m.get("processingState") == "complete"
               and (m.get("durationSeconds") or 0) >= args.min_minutes * 60]
    chosen = []
    for meeting_id in ids:
        if len(chosen) >= args.limit:
            break
        shown = pipit_json("meetings", "show", meeting_id)
        recordings = shown["recordings"]
        # A rejoined call has several recordings with separate timelines; scoring
        # one timeline against another would count every word as wrong.
        if len(recordings) != 1:
            continue
        directory = Path(recordings[0]["directory"])
        if not all((directory / f).exists() for f in [*TRACK_FILES.values(), "raw/transcript.json"]):
            continue
        for track, name in TRACK_FILES.items():
            out = work / "audio" / track / f"{meeting_id}.wav"
            out.parent.mkdir(parents=True, exist_ok=True)
            if not out.exists():
                subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(directory / name),
                                "-ac", "1", "-ar", "16000", str(out)], check=True)
        meta = shown["meeting"]
        chosen.append({"id": meeting_id, "directory": str(directory), "source": meta.get("source"),
                       "minutes": round((meta.get("durationSeconds") or 0) / 60, 1)})
    work.mkdir(parents=True, exist_ok=True)
    (work / "meetings.json").write_text(json.dumps(chosen, indent=2))
    print(f"{len(chosen)} meetings prepared in {work}")
    for m in chosen:
        print(f"  {m['id']}  {m['source']}  {m['minutes']} min")


# teach -----------------------------------------------------------------------------

def teach(args) -> None:
    work = args.work
    tracks = args.tracks.split(",")
    if args.teacher == "gemini" and not args.allow_cloud:
        sys.exit("the gemini teacher uploads meeting audio to Google; pass --allow-cloud to agree")
    for m in meetings(work):
        for track in tracks:
            wav = work / "audio" / track / f"{m['id']}.wav"
            suffix = ".txt" if args.teacher == "moss" else ".json"
            out = work / "teachers" / f"{args.teacher}-{track}" / f"{m['id']}{suffix}"
            if out.exists() and out.stat().st_size:
                continue
            out.parent.mkdir(parents=True, exist_ok=True)
            log = work / "logs" / f"{args.teacher}-{track}-{m['id']}.log"
            log.parent.mkdir(parents=True, exist_ok=True)
            print(f"{args.teacher} {track} {m['id']}", flush=True)
            if args.teacher == "vibevoice":
                command = ["uv", "run", "-q", "--python", "3.12", "--with", "mlx-audio", "python", "-m",
                           "mlx_audio.stt.generate", "--model", args.vibevoice_model, "--audio", str(wav),
                           "--output-path", str(out.with_suffix("")), "--format", "json",
                           "--max-tokens", "32768"]
                stdout = None
            elif args.teacher == "moss":
                if not (args.moss_cli and args.moss_model):
                    sys.exit("moss needs --moss-cli (transcribe.cpp's transcribe-cli) and --moss-model (GGUF)")
                command = [args.moss_cli, "-m", args.moss_model, "--diarize", "-l", "en",
                           "--timestamps", "segment", "-q", str(wav)]
                stdout = out
            else:
                if track != "mixed":
                    # Gemini's timestamps drift by minutes, so a split-track pairing would
                    # put the local person's words at the wrong time against the call.
                    continue
                command = ["uv", "run", "-q", "--python", "3.12", "--with", "google-genai", "python",
                           str(Path(__file__).with_name("gemini.py")), str(work / "audio" / "mixed" / f"{m['id']}.wav"),
                           str(out), "--model", args.gemini_model]
                stdout = None
            with open(log, "w") as log_file:
                target = open(stdout, "w") if stdout else log_file
                result = subprocess.run(command, stdout=target, stderr=log_file)
                if stdout:
                    target.close()
            if result.returncode != 0:
                print(f"  failed, see {log}")
                out.unlink(missing_ok=True)


# score -----------------------------------------------------------------------------

def seglst(segments: list[dict], one_speaker: bool = False):
    from meeteval.io import SegLST
    rows = []
    for seg in sorted(segments, key=lambda s: s["start"]):
        words = " ".join(normalise(seg["text"]))
        if words:
            rows.append({"session_id": "m", "speaker": "all" if one_speaker else seg["speaker"],
                         "start_time": seg["start"], "end_time": max(seg["end"], seg["start"] + 0.01),
                         "words": words})
    return SegLST(rows)


def error_rate(fn, ref, hyp, **kwargs) -> float:
    return next(iter(fn(ref, hyp, **kwargs).values())).error_rate


def compare(ref: list[dict], hyp: list[dict]) -> dict:
    from meeteval.wer import cpwer
    return {"wer": error_rate(cpwer, seglst(ref, True), seglst(hyp, True)),
            "cpwer": error_rate(cpwer, seglst(ref), seglst(hyp))}


def references(work: Path, meeting_id: str) -> dict[str, list[dict]]:
    found = {}
    for name in REFERENCES:
        kind, teacher = name.split("-", 1)
        segs = (split_segments(work, teacher, meeting_id) if kind == "split"
                else teacher_segments(work, teacher, "mixed", meeting_id))
        if segs:
            found[name] = segs
    return found


def echo_leak(meeting_dir: Path, call: list[dict], window: float = 5.0) -> dict:
    """Mic words that also appear, as a run of three or more, in a teacher's transcript
    of the call track alone within the window: far-end speech that got through as yours.
    Single words are not counted, since "yeah" and "the" match by chance.
    """
    def trigrams(words):
        return {tuple(words[i:i + 3]) for i in range(len(words) - 2)}

    utterances = json.loads((meeting_dir / "raw" / "transcript.json").read_text())["utterances"]
    far = [(s["start"], s["end"], normalise(s["text"])) for s in call]
    total = leaked = 0
    for u in (u for u in utterances if u.get("track") == "mic"):
        words = normalise(u["text"])
        total += len(words)
        nearby = set()
        for start, end, far_words in far:
            if start - window <= u["end"] and end + window >= u["start"]:
                nearby |= trigrams(far_words)
        hit = [False] * len(words)
        for i in range(len(words) - 2):
            if tuple(words[i:i + 3]) in nearby:
                hit[i] = hit[i + 1] = hit[i + 2] = True
        leaked += sum(hit)
    return {"micWords": total, "leakedWords": leaked, "share": leaked / total if total else None}


def triangle(pairs: dict, a: str, b: str) -> dict | None:
    """Each source's own error from the three pairwise disagreements, assuming the
    sources make independent mistakes: d(x, y) is roughly e(x) + e(y).
    """
    try:
        pb, pa, ab = pairs[f"pipit vs {b}"]["wer"], pairs[f"pipit vs {a}"]["wer"], pairs[f"{b} vs {a}"]["wer"]
    except KeyError:
        return None
    return {"pipit": max(0.0, (pa + pb - ab) / 2), a: max(0.0, (pa + ab - pb) / 2),
            b: max(0.0, (pb + ab - pa) / 2), "using": [a, b]}


def teacher_model(name: str) -> str:
    return name.split("-", 1)[1]


def score(args) -> None:
    work = args.work
    (work / "results").mkdir(parents=True, exist_ok=True)
    for m in meetings(work):
        directory = Path(m["directory"])
        refs = references(work, m["id"])
        if not refs:
            print(f"{m['id']}: no teacher output yet")
            continue
        sources = {"pipit": pipit_segments(directory), **refs}
        # Keys read "hypothesis vs reference". Pipit is listed first in sources, so it is
        # always the hypothesis; between two references the earlier one is the reference.
        pairs = {}
        for (first, first_segs), (second, second_segs) in combinations(sources.items(), 2):
            if first == "pipit":
                pairs[f"pipit vs {second}"] = compare(second_segs, first_segs)
            else:
                pairs[f"{second} vs {first}"] = compare(first_segs, second_segs)
        names = list(refs)
        independent = [(a, b) for a, b in combinations(names, 2) if teacher_model(a) != teacher_model(b)]
        estimate = triangle(pairs, *independent[0]) if independent else None
        call = next((teacher_segments(work, t, "system", m["id"]) for t in ("moss", "vibevoice")
                     if teacher_segments(work, t, "system", m["id"])), None)
        result = {
            "meeting": m["id"], "source": m["source"], "minutes": m["minutes"],
            "pipitSpeakers": len({s["speaker"] for s in sources["pipit"]}),
            "referenceSpeakers": {n: len({s["speaker"] for s in segs}) for n, segs in refs.items()},
            "pairs": pairs, "wordErrorEstimate": estimate,
            "echoLeak": echo_leak(directory, call) if call else None,
        }
        (work / "results" / f"{m['id']}.json").write_text(json.dumps(result, indent=2))
        best = names[0]
        line = f"{m['id']}  vs {best}: words {pairs[f'pipit vs {best}']['wer']:.1%}, words+speaker {pairs[f'pipit vs {best}']['cpwer']:.1%}"
        if estimate:
            line += f"  estimated Pipit word error {estimate['pipit']:.1%}"
        print(line)


# report ----------------------------------------------------------------------------

def report(args) -> None:
    work = args.work
    rows = [json.loads(p.read_text()) for p in sorted((work / "results").glob("*.json"))]
    if not rows:
        sys.exit("no results; run score first")
    lines = ["| Meeting | Source | Min | Pipit word error (est.) | Words+speaker vs best reference | "
             "Speakers Pipit / reference | Echo leak |", "|---|---|---:|---:|---:|---|---:|"]
    for r in rows:
        best = next(iter(r["referenceSpeakers"]))
        est = r["wordErrorEstimate"]
        leak = r["echoLeak"]
        estimate = f"{est['pipit']:.1%}" if est else "n/a"
        leak_share = f"{leak['share']:.1%}" if leak and leak["share"] is not None else "n/a"
        attributed = r["pairs"][f"pipit vs {best}"]["cpwer"]
        lines.append(f"| {r['meeting']} | {r['source']} | {r['minutes']} | {estimate} | "
                     f"{attributed:.1%} ({best}) | {r['pipitSpeakers']} / {r['referenceSpeakers'][best]} | "
                     f"{leak_share} |")
    estimates = sorted(r["wordErrorEstimate"]["pipit"] for r in rows if r["wordErrorEstimate"])
    summary = (f"\nMedian estimated Pipit word error over {len(estimates)} meetings: "
               f"{estimates[len(estimates) // 2]:.1%}" if estimates else "")
    text = "\n".join(lines) + summary + "\n"
    (work / "report.md").write_text(text)
    print(text)
    print(f"written to {work / 'report.md'}")


# diarizers -------------------------------------------------------------------------

def diarizer_turns(path: Path) -> list[tuple[float, float, str]]:
    if path.suffix == ".rttm":
        rows = []
        for line in path.read_text().splitlines():
            parts = line.split()
            if parts and parts[0] == "SPEAKER":
                start = float(parts[3])
                rows.append((start, start + float(parts[4]), parts[7]))
        return rows
    data = json.loads(path.read_text())
    return [(s["startTimeSeconds"], s["endTimeSeconds"], s["speakerId"]) for s in data["segments"]]


def label(start: float, end: float, turns) -> str:
    best, best_overlap = None, 0.0
    for t0, t1, speaker in turns:
        overlap = min(end, t1) - max(start, t0)
        if overlap > best_overlap:
            best, best_overlap = speaker, overlap
    if best:
        return best
    mid = (start + end) / 2
    near = min(turns, key=lambda t: min(abs(mid - t[0]), abs(mid - t[1])), default=None)
    return near[2] if near and min(abs(mid - near[0]), abs(mid - near[1])) <= 1.0 else "unassigned"


DIARIZERS = {
    # Pipit's shipped offline clusterer with its tuned warm start, and Nemotron 3.
    "vbx": lambda cli, wav, out: [cli, "process", wav, "--mode", "offline", "--fa", "0.2", "--output", out],
    "nemotron3": lambda cli, wav, out: [cli, "nemotron3-diarize", wav, "--variant", "offline", "--output", out],
}


def diarizers(args) -> None:
    """Hold Pipit's words fixed and relabel the call-track words with each diarizer, so
    the differences in speaker-attributed error come from the speaker labels alone.
    Mirrors a call with no meeting-app speaker data (Zoom, unknown apps).
    """
    from meeteval.wer import cpwer
    work = args.work
    for m in meetings(work):
        refs = {n: s for n, s in references(work, m["id"]).items() if n.startswith("split-")}
        if not refs:
            continue
        rows = {"pipit as shipped": pipit_segments(Path(m["directory"]))}
        for name, build in DIARIZERS.items():
            suffix = ".rttm" if name.startswith("nemotron") else ".json"
            out = work / "diarizers" / name / f"{m['id']}{suffix}"
            out.parent.mkdir(parents=True, exist_ok=True)
            if not out.exists():
                subprocess.run(build(args.fluidaudio_cli, str(work / "audio" / "system" / f"{m['id']}.wav"), str(out)),
                               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            turns = diarizer_turns(out)
            rows[name] = [{"speaker": "local" if w["track"] == "mic" else "call " + label(w["start"], w["end"], turns),
                           "start": w["start"], "end": w["end"], "text": w["text"]}
                          for w in pipit_words(Path(m["directory"]))]
        for ref_name, ref in refs.items():
            scores = {n: error_rate(cpwer, seglst(ref), seglst(s)) for n, s in rows.items()}
            print(f"{m['id']} vs {ref_name}  " + "  ".join(f"{n} {v:.1%}" for n, v in scores.items()))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--work", type=Path, default=Path(os.environ.get("PIPIT_AUDIT_DIR", DEFAULT_WORK)))
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("prepare", help="pick meetings and decode their three tracks")
    p.add_argument("--since")
    p.add_argument("--limit", type=int, default=10)
    p.add_argument("--ids", help="comma-separated meeting identifiers instead of a listing")
    p.add_argument("--min-minutes", type=float, default=5)
    t = sub.add_parser("teach", help="run a reference transcriber")
    t.add_argument("--teacher", choices=["vibevoice", "moss", "gemini"], required=True)
    t.add_argument("--tracks", default="mixed,mic,system")
    t.add_argument("--vibevoice-model", default="mlx-community/VibeVoice-ASR-4bit")
    t.add_argument("--moss-cli", default=os.environ.get("TRANSCRIBE_CLI"))
    t.add_argument("--moss-model", default=os.environ.get("MOSS_MODEL"))
    t.add_argument("--gemini-model", default="gemini-3.5-flash-lite")
    t.add_argument("--allow-cloud", action="store_true")
    sub.add_parser("score", help="compare Pipit with every reference")
    sub.add_parser("report", help="summarise scored meetings")
    d = sub.add_parser("diarizers", help="relabel Pipit's call words with other diarizers")
    d.add_argument("--fluidaudio-cli", required=True, help="a built fluidaudiocli from FluidAudio 0.18.2")
    args = parser.parse_args()
    {"prepare": prepare, "teach": teach, "score": score, "report": report, "diarizers": diarizers}[args.command](args)


if __name__ == "__main__":
    main()
