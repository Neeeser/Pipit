"""Speaker-labelled segments from Pipit and from each reference transcriber.

Every loader returns a list of {"speaker", "start", "end", "text"} dicts, so the
scorer compares any two sources the same way.
"""

import json
import re
from pathlib import Path


def pipit_segments(meeting_dir: Path) -> list[dict]:
    """Pipit's final transcript, each speaker key resolved to the person the app shows.

    Several diarizer clusters and meeting-platform sensors can map to one person,
    and the person is what a reader sees, so scoring uses the display name.
    """
    raw = meeting_dir / "raw"
    utterances = json.loads((raw / "transcript.json").read_text())["utterances"]
    map_file = raw / "speakers.map.json"
    entries = json.loads(map_file.read_text()).get("entries", {}) if map_file.exists() else {}
    names = {key: value.get("displayName") or key for key, value in entries.items()}
    return [
        {
            "speaker": names.get(u.get("speakerKey"), u.get("speakerKey") or "unknown"),
            "start": float(u["start"]),
            "end": float(u["end"]),
            "text": u["text"],
        }
        for u in utterances
        if u.get("text", "").strip()
    ]


def pipit_words(meeting_dir: Path) -> list[dict]:
    """Pipit's words with their own timings and the track each came from."""
    utterances = json.loads((meeting_dir / "raw" / "transcript.json").read_text())["utterances"]
    out = []
    for u in utterances:
        for w in u.get("words") or [{"start": u["start"], "end": u["end"], "text": u["text"]}]:
            out.append({"track": u.get("track"), "start": w["start"], "end": w["end"], "text": w["text"]})
    return out


def vibevoice_segments(path: Path) -> list[dict]:
    data = json.loads(Path(path).read_text())
    # mlx-audio writes the model's own JSON list as a string under "text".
    items = json.loads(data["text"]) if isinstance(data, dict) else data
    out = []
    for item in items:
        text = item.get("Content") or item.get("text") or ""
        # Bracketed tags such as [Noise] mark non-speech and carry no speaker.
        if "Speaker" not in item or re.fullmatch(r"\s*\[[^\]]*\]\s*", text):
            continue
        out.append({"speaker": str(item["Speaker"]), "start": float(item["Start"]),
                    "end": float(item["End"]), "text": text})
    return out


def moss_segments(path: Path) -> list[dict]:
    """transcribe-cli text output, lines like "[   8.53 ->   10.19] S1: text"."""
    out = []
    for line in Path(path).read_text().splitlines():
        m = re.match(r"\s*\[\s*([\d.]+)\s*->\s*([\d.]+)\]\s*(S\d+):\s*(.*)", line)
        if m and m.group(4).strip():
            out.append({"speaker": m.group(3), "start": float(m.group(1)),
                        "end": float(m.group(2)), "text": m.group(4)})
    return out


def _clock(value) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    seconds = 0.0
    for part in str(value).strip().split(":"):
        seconds = seconds * 60 + float(part)
    return seconds


def gemini_segments(path: Path) -> list[dict]:
    data = json.loads(Path(path).read_text())
    out = []
    for item in data["segments"]:
        if item.get("text", "").strip():
            start = _clock(item.get("start", 0))
            out.append({"speaker": str(item.get("speaker", "?")), "start": start,
                        "end": _clock(item.get("end", start)), "text": item["text"]})
    return out


LOADERS = {"vibevoice": (vibevoice_segments, ".json"), "moss": (moss_segments, ".txt"),
           "gemini": (gemini_segments, ".json")}


def teacher_segments(work: Path, teacher: str, track: str, meeting_id: str) -> list[dict] | None:
    loader, suffix = LOADERS[teacher]
    path = work / "teachers" / f"{teacher}-{track}" / f"{meeting_id}{suffix}"
    return loader(path) if path.exists() and path.stat().st_size else None


def split_segments(work: Path, teacher: str, meeting_id: str) -> list[dict] | None:
    """A teacher run on each track alone: the cleaned mic is the local person and
    the call track holds everyone else. Overlapping speech survives because nothing
    was mixed, and the local person cannot be confused with a remote one.
    """
    mic = teacher_segments(work, teacher, "mic", meeting_id)
    call = teacher_segments(work, teacher, "system", meeting_id)
    if mic is None or call is None:
        return None
    return ([dict(s, speaker="local person") for s in mic]
            + [dict(s, speaker=f"call {s['speaker']}") for s in call])


FILLERS = {"um", "uh", "uhm", "umm", "hmm", "mm", "mhm", "ah", "er", "erm", "eh", "huh", "oh"}
ONES = ("zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen "
        "fifteen sixteen seventeen eighteen nineteen").split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()


def spell_number(n: int) -> str:
    """Digits as words so "20" and "twenty" compare equal; years and larger stay digits."""
    if n < 20:
        return ONES[n]
    if n < 100:
        return TENS[n // 10] + ("" if n % 10 == 0 else " " + ONES[n % 10])
    if n < 1000:
        rest = n % 100
        return ONES[n // 100] + " hundred" + ("" if rest == 0 else " " + spell_number(rest))
    return str(n)


def normalise(text: str) -> list[str]:
    """Lowercase words without punctuation, hesitation sounds or formatting choices.

    Transcribers disagree on fillers, punctuation, number style and acronym spacing
    far more than on content, and none of those change what a reader understands.
    """
    text = text.lower().replace("-", " ").replace("’", "'").replace("%", " percent")
    text = re.sub(r"(?<=\d),(?=\d{3})", "", text)
    text = re.sub(r"\d+", lambda m: spell_number(int(m.group())), text)
    words = [w.strip("'") for w in re.findall(r"[a-z0-9']+", text)]
    words = [w for w in words if w and w not in FILLERS]
    # Spelled-out acronyms ("g c p") and written ones ("gcp") should match.
    joined: list[str] = []
    for w in words:
        single = len(w) == 1 and w not in {"a", "i"}
        if single and joined and joined[-1].endswith("\0"):
            joined[-1] = joined[-1][:-1] + w + "\0"
        else:
            joined.append(w + "\0" if single else w)
    return [w.rstrip("\0") for w in joined]
