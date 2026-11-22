#!/usr/bin/env python3
"""Write a synthetic meeting script with a Gemini text model.

    GEMINI_API_KEY=... Benchmarks/synthetic/write_script.py --meeting SYN001 \
        --speakers 10 --minutes 12 --out Benchmarks/synthetic/scripts/SYN001.json

The script is the meeting's ground truth: who says what, in order, and which
turns start before the previous one ends. Everything in it is invented.
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import gemini

TURN_SCHEMA = {
    "type": "object",
    "properties": {
        "speaker": {"type": "string"},
        "text": {"type": "string"},
        "kind": {"type": "string", "enum": ["turn", "interrupt", "backchannel"]},
    },
    "required": ["speaker", "text", "kind"],
}
SCRIPT_SCHEMA = {
    "type": "object",
    "properties": {
        "topic": {"type": "string"},
        "participants": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"id": {"type": "string"}, "name": {"type": "string"}, "role": {"type": "string"}},
                "required": ["id", "name", "role"],
            },
        },
        "turns": {"type": "array", "items": TURN_SCHEMA},
    },
    "required": ["topic", "participants", "turns"],
}

PROMPT = """Write the transcript of an invented work meeting, as it would really sound when spoken.
It is for testing speech recognition and speaker separation, so it must be hard in the ways real meetings are hard.

- {speakers} participants with ids S01 to S{speakers:02d}. Invent first names and roles. S01 is the person whose
  laptop records the call; the others join remotely.
- About {words} spoken words in total, which is about {minutes} minutes.
- Topic: {topic}
- Speak like people really talk: fillers (um, uh, like, you know), false starts and self-corrections
  ("we should, well, we could"), repeated words, trailing off, laughing at something, numbers, dates, money,
  percentages, product names and acronyms said out loud, and a few names of the participants.
- Uneven talk time: two people dominate, most speak sometimes, one person says almost nothing until the last
  quarter of the meeting, and one joins the conversation only in the second half.
- kind "turn" is a normal turn after the previous one ends. kind "interrupt" starts while the previous speaker
  is still talking. kind "backchannel" is a short reply ("yeah", "mm-hmm", "right", "okay", "sure") said over
  someone else's turn. Use about 12% interrupts and 15% backchannels, spread through the meeting, and include
  stretches where several people talk over each other.
- Write words only: no stage directions, brackets, emoji or markup, except the tag <laugh> where someone laughs.
"""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--meeting", required=True)
    parser.add_argument("--speakers", type=int, default=10)
    parser.add_argument("--minutes", type=float, default=12)
    parser.add_argument("--topic", default="planning the next quarter's launch of a software product, with a budget dispute")
    parser.add_argument("--model", default="gemini-3.8-flash")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    prompt = PROMPT.format(speakers=args.speakers, words=int(args.minutes * 150), minutes=args.minutes, topic=args.topic)
    script = json.loads(gemini.text(args.model, prompt, SCRIPT_SCHEMA))
    ids = {p["id"] for p in script["participants"]}
    script["turns"] = [t for t in script["turns"] if t["speaker"] in ids and t["text"].strip()]
    if not any(t["speaker"] == "S01" for t in script["turns"]):
        raise SystemExit("the script gives S01, the local speaker, no turns; write it again")
    script.update({"meeting": args.meeting, "localSpeaker": "S01", "writer": args.model, "prompt": prompt})
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(script, indent=1) + "\n")
    words = sum(len(t["text"].split()) for t in script["turns"])
    kinds = {k: sum(t["kind"] == k for t in script["turns"]) for k in ("turn", "interrupt", "backchannel")}
    print("%s: %d participants, %d turns, %d words, %s" % (args.meeting, len(ids), len(script["turns"]), words, kinds))


if __name__ == "__main__":
    main()
