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

Run score and diarizers with the scoring dependencies available, for example
`uv run --python 3.12 --with meeteval==0.4.3 --with whisper-normalizer==0.1.12
python Benchmarks/audit/audit.py score` (the versions are PINNED below). Output
goes under --work (default ~/Library/Caches/pipit-bench/audit), never into a git
repository. Printed output holds a meeting's index and short key, counts and
rates, never its title. Every command ends with an ok/failed/skipped summary and exits 1 on a failure.
"""

import argparse
import json
import os
import subprocess
import sys
import traceback
from importlib import metadata
from itertools import combinations
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from integrity import (  # noqa: E402
    Tally, enclosing_repository, label, meeting_key, staged, truncation, with_keys, write_atomic,
)
from sources import (  # noqa: E402
    LOADERS, normalise, pipit_segments, pipit_words, split_parts, split_segments, teacher_segments,
)

DEFAULT_WORK = Path.home() / "Library" / "Caches" / "pipit-bench" / "audit"
TRACK_FILES = {"mixed": "recording.m4a", "mic": "raw/audio/mic.cleaned.m4a", "system": "raw/audio/system.m4a"}
# Reference preference: separate-track runs first, since they keep overlapping speech
# and cannot mix up the local person with a remote one.
REFERENCES = ["split-vibevoice", "split-moss", "mixed-moss", "mixed-vibevoice", "mixed-gemini"]

# The Python packages the audit runs and the models it asks for. A reference is only
# comparable across runs when these stay fixed, so a change is a deliberate edit here.
# `teach` writes them to provenance.json and `score` copies them into every result.
PINNED = {"mlx-audio": "0.6.4", "google-genai": "3.4.0", "meeteval": "0.4.3", "whisper-normalizer": "0.1.12"}
# The packages score and diarizers import. The normaliser decides which words count
# as the same, so a different version changes every error rate.
SCORING = ["meeteval", "whisper-normalizer"]
VIBEVOICE_MODEL = "mlx-community/VibeVoice-ASR-4bit"
GEMINI_MODEL = "gemini-3.5-flash-lite"
PYTHON = "3.12"


def uv_with(package: str) -> list[str]:
    return ["--with", f"{package}=={PINNED[package]}"]


class UnusableReference(Exception):
    """A teacher's output exists but cannot be read; the message names the reference."""


def describe(error: BaseException) -> str:
    """What to print about a failure. Exception text can quote an identifier or a path
    (a failed `pipit` call prints its whole command), so only our own messages and the
    type go to the terminal; the traceback goes to a log under the work folder.
    """
    return f"{type(error).__name__}: {error}" if isinstance(error, UnusableReference) else type(error).__name__


def record_failure(work: Path, tally: Tally, what: str, meeting: dict, error: BaseException) -> None:
    tally.failed += 1
    log = work / "logs" / f"{what}-{meeting['key']}.error.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text("".join(traceback.format_exception(error)))
    print(f"  failed {label(meeting)}: {describe(error)}; traceback in {log}", file=sys.stderr)


def finish(tally: Tally, what: str) -> None:
    print(tally.summary(what))
    sys.exit(tally.exit_code)


def pipit_json(*args: str) -> dict:
    return json.loads(subprocess.check_output(["pipit", *args, "--json"]))


def meetings(work: Path) -> list[dict]:
    path = work / "meetings.json"
    if not path.exists():
        sys.exit(f"no {path}; run prepare first")
    return with_keys(json.loads(path.read_text()))


# prepare ---------------------------------------------------------------------------

def prepare(args) -> None:
    work = args.work
    tally = Tally()
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
    chosen: list[dict] = []
    for meeting_id in ids:
        if len(chosen) >= args.limit:
            break
        key = meeting_key(meeting_id)
        try:
            shown = pipit_json("meetings", "show", meeting_id)
            recordings = shown["recordings"]
            # A rejoined call has several recordings with separate timelines; scoring
            # one timeline against another would count every word as wrong.
            if len(recordings) != 1:
                tally.skipped += 1
                continue
            directory = Path(recordings[0]["directory"])
            if not all((directory / f).exists() for f in [*TRACK_FILES.values(), "raw/transcript.json"]):
                tally.skipped += 1
                continue
            for track, name in TRACK_FILES.items():
                out = work / "audio" / track / f"{key}.wav"
                out.parent.mkdir(parents=True, exist_ok=True)
                if out.exists() and out.stat().st_size:
                    continue
                with staged(out) as target:
                    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(directory / name),
                                    "-ac", "1", "-ar", "16000", str(target)],
                                   check=True, stdin=subprocess.DEVNULL)
            meta = shown["meeting"]
            # The identifier carries the title slug, so this file is the only place
            # that connects a short key to a meeting.
            chosen.append({"id": meeting_id, "key": key, "index": len(chosen) + 1,
                           "directory": str(directory), "source": meta.get("source"),
                           "minutes": round((meta.get("durationSeconds") or 0) / 60, 1)})
            tally.ok += 1
        except Exception as error:
            record_failure(work, tally, "prepare", {"key": key, "index": len(chosen) + 1}, error)
    write_atomic(work / "meetings.json", json.dumps(chosen, indent=2))
    print(f"{len(chosen)} meetings prepared in {work}")
    for m in chosen:
        print(f"  {label(m)}  {m['source']}  {m['minutes']} min")
    finish(tally, "prepare")


# teach -----------------------------------------------------------------------------

def file_sha256(path: str) -> str:
    import hashlib
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while block := handle.read(1 << 22):
            digest.update(block)
    return digest.hexdigest()


def vibevoice_revision(model: str) -> str | None:
    """The cached snapshot of the model, when Hugging Face has one on disk."""
    snapshots = Path.home() / ".cache" / "huggingface" / "hub" / f"models--{model.replace('/', '--')}" / "snapshots"
    found = sorted(p.name for p in snapshots.iterdir()) if snapshots.is_dir() else []
    return found[-1] if found else None


def record_provenance(work: Path, teacher: str, details: dict) -> None:
    path = work / "provenance.json"
    known = json.loads(path.read_text()) if path.exists() else {}
    known[teacher] = details
    write_atomic(path, json.dumps(known, indent=2))


def teach(args) -> None:
    work = args.work
    tracks = args.tracks.split(",")
    if args.teacher == "gemini" and not args.allow_cloud:
        sys.exit("the gemini teacher uploads meeting audio to Google; pass --allow-cloud to agree")
    if args.teacher == "moss":
        if not (args.moss_cli and args.moss_model):
            sys.exit("moss needs --moss-cli (transcribe.cpp's transcribe-cli) and --moss-model (GGUF)")
        record_provenance(work, "moss", {"model": Path(args.moss_model).name,
                                         "modelSha256": file_sha256(args.moss_model)})
    elif args.teacher == "vibevoice":
        record_provenance(work, "vibevoice", {"python": PYTHON, "mlx-audio": PINNED["mlx-audio"],
                                              "model": args.vibevoice_model,
                                              "modelSnapshot": vibevoice_revision(args.vibevoice_model)})
    else:
        record_provenance(work, "gemini", {"python": PYTHON, "google-genai": PINNED["google-genai"],
                                           "model": args.gemini_model})
    tally = Tally()
    loader = LOADERS[args.teacher][0]
    for m in meetings(work):
        for track in tracks:
            wav = work / "audio" / track / f"{m['key']}.wav"
            suffix = ".txt" if args.teacher == "moss" else ".json"
            out = work / "teachers" / f"{args.teacher}-{track}" / f"{m['key']}{suffix}"
            # Gemini's timestamps drift by minutes, so a split-track pairing would
            # put the local person's words at the wrong time against the call.
            if (args.teacher == "gemini" and track != "mixed") or (out.exists() and out.stat().st_size):
                tally.skipped += 1
                continue
            out.parent.mkdir(parents=True, exist_ok=True)
            log = work / "logs" / f"{args.teacher}-{track}-{m['key']}.log"
            log.parent.mkdir(parents=True, exist_ok=True)
            print(f"{args.teacher} {track} {label(m)}", flush=True)
            try:
                with staged(out) as target:
                    stdout_to_target = False
                    if args.teacher == "vibevoice":
                        command = ["uv", "run", "-q", "--python", PYTHON, *uv_with("mlx-audio"), "python", "-m",
                                   "mlx_audio.stt.generate", "--model", args.vibevoice_model, "--audio", str(wav),
                                   "--output-path", str(target.with_suffix("")), "--format", "json",
                                   "--max-tokens", "32768"]
                    elif args.teacher == "moss":
                        command = [args.moss_cli, "-m", args.moss_model, "--diarize", "-l", "en",
                                   "--timestamps", "segment", "-q", str(wav)]
                        stdout_to_target = True
                    else:
                        command = ["uv", "run", "-q", "--python", PYTHON, *uv_with("google-genai"), "python",
                                   str(Path(__file__).with_name("gemini.py")), str(wav), str(target),
                                   "--model", args.gemini_model]
                    with open(log, "w") as log_file:
                        if stdout_to_target:
                            with open(target, "w") as handle:
                                result = subprocess.run(command, stdout=handle, stderr=log_file,
                                                        stdin=subprocess.DEVNULL)
                        else:
                            result = subprocess.run(command, stdout=log_file, stderr=log_file,
                                                    stdin=subprocess.DEVNULL)
                    if result.returncode != 0:
                        raise RuntimeError(f"{args.teacher} exited with {result.returncode}")
                    # An output that does not parse is a failed run, not a reference. The
                    # moss text format has no empty form: a silent track writes nothing,
                    # which `staged` already rejects, so text with no segment is garbage.
                    if not loader(target) and args.teacher == "moss":
                        raise ValueError("no transcript lines in the output")
                tally.ok += 1
            except Exception as error:
                record_failure(work, tally, f"teach-{args.teacher}-{track}", m, error)
                print(f"    run log: {log}", file=sys.stderr)
    finish(tally, f"teach {args.teacher}")


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


def pipit_track(pipit: list[dict], track: str) -> list[dict]:
    return [s for s in pipit if (s.get("track") == "mic") == (track == "mic")]


def references(work: Path, key: str, pipit: list[dict]) -> tuple[dict[str, list[dict]], dict[str, str]]:
    """The usable references, and the reasons the others were set aside.

    A reference that stops well before Pipit's transcript does (a token cap, a
    Gemini finish reason, a meeting longer than the model handles) would score its
    missing tail as Pipit's mistakes, so it is set aside. A teacher file that
    cannot be read raises UnusableReference.
    """
    found: dict[str, list[dict]] = {}
    rejected: dict[str, str] = {}
    for name in REFERENCES:
        kind, teacher = name.split("-", 1)
        try:
            if kind == "split":
                parts = split_parts(work, teacher, key)
                if parts is None:
                    continue
                mic, call = parts
                reason = truncation(mic, pipit_track(pipit, "mic")) or truncation(call, pipit_track(pipit, "system"))
                segs = split_segments(work, teacher, key)
            else:
                segs = teacher_segments(work, teacher, "mixed", key)
                if segs is None:
                    continue
                reason = truncation(segs, pipit)
        except (ValueError, KeyError, TypeError, OSError) as error:
            raise UnusableReference(f"{name} output cannot be read ({type(error).__name__})") from error
        if reason:
            rejected[name] = f"looks truncated: {reason}"
        else:
            found[name] = segs
    return found, rejected


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


def triangle(pairs: dict, a: str, b: str, metric: str = "wer") -> dict | None:
    """Each source's own error from the three pairwise disagreements, assuming the
    sources make independent mistakes: d(x, y) is roughly e(x) + e(y).

    A negative estimate means the disagreements break that assumption (the two
    references share mistakes, or a source is truncated or mislabelled). It is
    reported as is, with the sources named in "violates", never clamped to zero.
    """
    try:
        pb, pa, ab = (pairs[f"pipit vs {b}"][metric], pairs[f"pipit vs {a}"][metric],
                      pairs[f"{b} vs {a}"][metric])
    except KeyError:
        return None
    estimate = {"pipit": (pa + pb - ab) / 2, a: (pa + ab - pb) / 2, b: (pb + ab - pa) / 2}
    return {**estimate, "using": [a, b], "metric": metric,
            "violates": [name for name, value in estimate.items() if value < 0]}


def teacher_model(name: str) -> str:
    return name.split("-", 1)[1]


def check_scoring_packages() -> None:
    command = f"`uv run --python {PYTHON} " + " ".join(f"--with {p}=={PINNED[p]}" for p in SCORING) + " python ...`"
    for package in SCORING:
        try:
            installed = metadata.version(package)
        except metadata.PackageNotFoundError:
            sys.exit(f"{package} is not installed; run it with {command}")
        if installed != PINNED[package]:
            sys.exit(f"{package} {installed} is installed and the audit pins {PINNED[package]}; run it with {command}")


def score_meeting(work: Path, m: dict, provenance: dict) -> dict | None:
    directory = Path(m["directory"])
    pipit = pipit_segments(directory)
    refs, rejected = references(work, m["key"], pipit)
    for name, reason in rejected.items():
        print(f"  {label(m)}: set aside {name}, {reason}")
    if not refs:
        return None
    sources = {"pipit": pipit, **refs}
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
    one_stream = triangle(pairs, *independent[0], metric="wer") if independent else None
    attributed = triangle(pairs, *independent[0], metric="cpwer") if independent else None
    call = next((s for t in ("moss", "vibevoice")
                 if (s := teacher_segments(work, t, "system", m["key"]))), None)
    return {
        "meeting": m["key"], "index": m["index"], "source": m["source"], "minutes": m["minutes"],
        "pipitSpeakers": len({s["speaker"] for s in pipit}),
        "referenceSpeakers": {n: len({s["speaker"] for s in segs}) for n, segs in refs.items()},
        "rejectedReferences": rejected,
        "pairs": pairs, "wordErrorEstimate": one_stream, "cpWerEstimate": attributed,
        "echoLeak": echo_leak(directory, call) if call else None,
        "provenance": {**{p: PINNED[p] for p in SCORING}, "teachers": provenance},
    }


def score(args) -> None:
    work = args.work
    check_scoring_packages()
    (work / "results").mkdir(parents=True, exist_ok=True)
    provenance_file = work / "provenance.json"
    provenance = json.loads(provenance_file.read_text()) if provenance_file.exists() else {}
    tally = Tally()
    for m in meetings(work):
        result_file = work / "results" / f"{m['key']}.json"
        # A result from an earlier run must not outlive a run that could not redo it.
        result_file.unlink(missing_ok=True)
        try:
            result = score_meeting(work, m, provenance)
        except Exception as error:
            record_failure(work, tally, "score", m, error)
            continue
        if result is None:
            print(f"{label(m)}: no usable reference")
            tally.skipped += 1
            continue
        write_atomic(result_file, json.dumps(result, indent=2))
        tally.ok += 1
        best = next(iter(result["referenceSpeakers"]))
        pair = result["pairs"][f"pipit vs {best}"]
        line = f"{label(m)}  vs {best}: words {pair['wer']:.1%}, words+speaker {pair['cpwer']:.1%}"
        for title, est in (("word error", result["wordErrorEstimate"]), ("cpWER", result["cpWerEstimate"])):
            if est:
                line += f"  estimated Pipit {title} {fmt_estimate(est)}"
        print(line)
    finish(tally, "score")


# report ----------------------------------------------------------------------------

def fmt_estimate(est: dict | None) -> str:
    if not est:
        return "n/a"
    text = f"{est['pipit']:.1%}"
    return f"{text} (assumption violated by {', '.join(est['violates'])})" if est["violates"] else text


def report(args) -> None:
    work = args.work
    rows = [json.loads(p.read_text()) for p in sorted((work / "results").glob("*.json"))]
    if not rows:
        sys.exit("no results; run score first")
    rows.sort(key=lambda r: r.get("index", 0))
    lines = ["| Meeting | Source | Min | Pipit word error (est., one stream) | Pipit cpWER (est.) | "
             "Words+speaker vs best reference | Speakers Pipit / reference | Echo leak |",
             "|---|---|---:|---:|---:|---:|---|---:|"]
    notes = []
    for r in rows:
        best = next(iter(r["referenceSpeakers"]))
        leak = r["echoLeak"]
        leak_share = f"{leak['share']:.1%}" if leak and leak["share"] is not None else "n/a"
        attributed = r["pairs"][f"pipit vs {best}"]["cpwer"]
        name = f"#{r['index']} {r['meeting']}"
        lines.append(f"| {name} | {r['source']} | {r['minutes']} | {fmt_estimate(r['wordErrorEstimate'])} | "
                     f"{fmt_estimate(r.get('cpWerEstimate'))} | {attributed:.1%} ({best}) | "
                     f"{r['pipitSpeakers']} / {r['referenceSpeakers'][best]} | {leak_share} |")
        notes += [f"- {name}: set aside {ref}, {why}" for ref, why in r.get("rejectedReferences", {}).items()]

    def median(kind: str) -> str:
        valid = sorted(r[kind]["pipit"] for r in rows if r.get(kind) and not r[kind]["violates"])
        broken = sum(1 for r in rows if r.get(kind) and r[kind]["violates"])
        text = f"{valid[len(valid) // 2]:.1%} over {len(valid)} meetings" if valid else "n/a"
        return text + (f"; {broken} more violate the independence assumption and are left out" if broken else "")

    summary = (f"\nMedian estimated Pipit word error (one stream): {median('wordErrorEstimate')}\n"
               f"Median estimated Pipit cpWER: {median('cpWerEstimate')}\n")
    text = "\n".join(lines) + "\n" + summary + ("\n" + "\n".join(notes) + "\n" if notes else "")
    write_atomic(work / "report.md", text)
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


def label_turn(start: float, end: float, turns) -> str:
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


def diarize_meeting(args, m: dict) -> bool:
    """Returns False when the meeting had no split reference to score against."""
    from meeteval.wer import cpwer
    work = args.work
    pipit = pipit_segments(Path(m["directory"]))
    found, rejected = references(work, m["key"], pipit)
    for name, reason in rejected.items():
        print(f"  {label(m)}: set aside {name}, {reason}")
    refs = {n: s for n, s in found.items() if n.startswith("split-")}
    if not refs:
        return False
    rows = {"pipit as shipped": pipit}
    for name, build in DIARIZERS.items():
        suffix = ".rttm" if name.startswith("nemotron") else ".json"
        out = work / "diarizers" / name / f"{m['key']}{suffix}"
        out.parent.mkdir(parents=True, exist_ok=True)
        if not (out.exists() and out.stat().st_size):
            log = work / "logs" / f"diarizer-{name}-{m['key']}.log"
            log.parent.mkdir(parents=True, exist_ok=True)
            with staged(out) as target, open(log, "w") as log_file:
                subprocess.run(build(args.fluidaudio_cli, str(work / "audio" / "system" / f"{m['key']}.wav"),
                                     str(target)),
                               check=True, stdin=subprocess.DEVNULL, stdout=log_file, stderr=log_file)
        turns = diarizer_turns(out)
        rows[name] = [{"speaker": "local" if w["track"] == "mic" else "call " + label_turn(w["start"], w["end"], turns),
                       "start": w["start"], "end": w["end"], "text": w["text"]}
                      for w in pipit_words(Path(m["directory"]))]
    for ref_name, ref in refs.items():
        scores = {n: error_rate(cpwer, seglst(ref), seglst(s)) for n, s in rows.items()}
        print(f"{label(m)} vs {ref_name}  " + "  ".join(f"{n} {v:.1%}" for n, v in scores.items()))
    return True


def diarizers(args) -> None:
    """Hold Pipit's words fixed and relabel the call-track words with each diarizer, so
    the differences in speaker-attributed error come from the speaker labels alone.
    Mirrors a call with no meeting-app speaker data (Zoom, unknown apps).
    """
    check_scoring_packages()
    tally = Tally()
    for m in meetings(args.work):
        try:
            if diarize_meeting(args, m):
                tally.ok += 1
            else:
                print(f"{label(m)}: no usable split reference")
                tally.skipped += 1
        except Exception as error:
            record_failure(args.work, tally, "diarizers", m, error)
    finish(tally, "diarizers")


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
    t.add_argument("--vibevoice-model", default=VIBEVOICE_MODEL)
    t.add_argument("--moss-cli", default=os.environ.get("TRANSCRIBE_CLI"))
    t.add_argument("--moss-model", default=os.environ.get("MOSS_MODEL"))
    t.add_argument("--gemini-model", default=GEMINI_MODEL)
    t.add_argument("--allow-cloud", action="store_true")
    sub.add_parser("score", help="compare Pipit with every reference")
    sub.add_parser("report", help="summarise scored meetings")
    d = sub.add_parser("diarizers", help="relabel Pipit's call words with other diarizers")
    d.add_argument("--fluidaudio-cli", required=True, help="a built fluidaudiocli from FluidAudio 0.18.2")
    args = parser.parse_args()
    repository = enclosing_repository(args.work)
    if repository:
        sys.exit(f"--work {args.work} is inside the git repository {repository}. The audit writes decoded "
                 "meeting audio and transcripts there; choose a folder outside every repository.")
    {"prepare": prepare, "teach": teach, "score": score, "report": report, "diarizers": diarizers}[args.command](args)


if __name__ == "__main__":
    main()
