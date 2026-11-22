"""Speaker-labelled segments from Pipit and from each reference transcriber.

Every loader returns a list of {"speaker", "start", "end", "text"} dicts, so the
scorer compares any two sources the same way.
"""

import json
import re
from functools import cache
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
            "track": u.get("track"),
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


def split_parts(work: Path, teacher: str, meeting_id: str) -> tuple[list[dict], list[dict]] | None:
    """A teacher's mic and call-track transcripts, or None when either is missing."""
    mic = teacher_segments(work, teacher, "mic", meeting_id)
    call = teacher_segments(work, teacher, "system", meeting_id)
    return None if mic is None or call is None else (mic, call)


def split_segments(work: Path, teacher: str, meeting_id: str) -> list[dict] | None:
    """A teacher run on each track alone: the cleaned mic is the local person and
    the call track holds everyone else. Overlapping speech survives because nothing
    was mixed, and the local person cannot be confused with a remote one.
    """
    parts = split_parts(work, teacher, meeting_id)
    if parts is None:
        return None
    mic, call = parts
    return ([dict(s, speaker="local person") for s in mic]
            + [dict(s, speaker=f"call {s['speaker']}") for s in call])


# Hesitation sounds Whisper's normaliser keeps. It already drops hmm, mm, mhm, mmm,
# uh and um.
FILLERS = {"uhm", "umm", "ah", "er", "erm", "eh", "huh"}
# Whisper turns the letter "o" into a zero, so "O.K." would become "0 k".
SPELLINGS = {"ok": "okay"}
# Whisper reads every "oh" as a zero. Before a digit it is one ("one oh one" is
# 101); anywhere else it is the interjection, which is dropped like a filler.
INTERJECTION_OH = re.compile(r"\boh\b(?!\s+(?:\d|zero|one|two|three|four|five|six|seven|eight|nine)\b)",
                             re.IGNORECASE)
# Single letters joined into one word, while case and dots still show an acronym:
# "A.P.I." and "E.O.D" (a dot between letters), "A. P. I.", "A P I" and "A-P-I"
# (capitals), and "g c p" (lowercase, leaving the words "a" and "i" alone). Only a
# plain space or hyphen joins, so "plan B. C is next" keeps two letters.
ACRONYMS = [re.compile(r"\b[A-Za-z](?:\.[A-Za-z])+\b\.?"), re.compile(r"\b[A-Z]\.(?: [A-Z]\.)+"),
            re.compile(r"\b[A-Z](?:[ -][A-Z])+\b"), re.compile(r"\b[b-hj-z](?: [b-hj-z])+\b")]


@cache
def _whisper():
    # Imported on first use so prepare and teach run without the package.
    from whisper_normalizer.english import EnglishTextNormalizer
    return EnglishTextNormalizer()


def _join_letters(match: re.Match) -> str:
    return re.sub(r"[.\s-]", "", match.group())


def normalise(text: str) -> list[str]:
    """Lowercase words without punctuation, hesitation sounds or formatting choices.

    Transcribers disagree on number style, contractions, spelling and acronym
    spacing far more than on content, and none of those change what a reader
    understands. Whisper's English normaliser writes numbers, ordinals, years,
    money and percentages as digits ("twenty five" and "25" both become "25"),
    expands contractions, uses American spelling, and drops bracketed tags and
    punctuation. Acronyms are joined first, while case and dots still show them.
    """
    for pattern in ACRONYMS:
        text = pattern.sub(_join_letters, text)
    text = INTERJECTION_OH.sub(" ", text)
    # Whisper only knows the straight apostrophe, so "it’s" would split in two.
    text = text.replace("’", "'")
    # Whisper reads "three thirty" as 330 and "3:30" as two numbers.
    text = re.sub(r"\b(\d{1,2}):(\d{2})\b", r"\1\2", text)
    return [SPELLINGS.get(w, w) for w in _whisper()(text).split() if w not in FILLERS]
