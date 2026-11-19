"""Transcribe one audio file with Gemini and save speaker-labelled segments as JSON.

Usage: gemini.py AUDIO OUT_JSON [--model MODEL]
Reads GEMINI_API_KEY from the environment. This uploads the audio to Google; the
audit only calls it when --allow-cloud is given. On the free tier Google may use
what you send to improve its products.
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path

from google import genai
from google.genai import types

PROMPT = """Transcribe this meeting recording verbatim, including hesitations such as "um" and "uh".
Split the transcript into segments at every change of speaker. Label speakers consistently
for the whole recording as Speaker 1, Speaker 2, and so on, in order of first appearance.
When two people talk over each other, give each person their own segment with overlapping times.
Give start and end as MM:SS from the start of the recording.
Write only what is said. Do not summarise, skip, or invent speech."""

SCHEMA = {
    "type": "object",
    "properties": {
        "segments": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "speaker": {"type": "string"},
                    "start": {"type": "string"},
                    "end": {"type": "string"},
                    "text": {"type": "string"},
                },
                "required": ["speaker", "start", "end", "text"],
            },
        }
    },
    "required": ["segments"],
}


def load_key() -> str:
    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        sys.exit("GEMINI_API_KEY is not set")
    return key


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", type=Path)
    parser.add_argument("out", type=Path)
    parser.add_argument("--model", default="gemini-3.5-flash-lite")
    parser.add_argument("--thinking", default="default", help="thinking level: minimal, low, medium, high, or default to leave it to the model")
    args = parser.parse_args()

    # A stuck request otherwise waits forever with no socket open.
    client = genai.Client(api_key=load_key(), http_options=types.HttpOptions(timeout=900_000))
    started = time.time()
    uploaded = client.files.upload(file=args.audio)
    print(f"uploaded in {time.time() - started:.0f}s", flush=True)
    while uploaded.state and uploaded.state.name == "PROCESSING":
        time.sleep(2)
        uploaded = client.files.get(name=uploaded.name)

    response = client.models.generate_content(
        model=args.model,
        contents=[uploaded, PROMPT],
        config=types.GenerateContentConfig(
            temperature=0,
            response_mime_type="application/json",
            response_schema=SCHEMA,
            max_output_tokens=65536,
            thinking_config=None if args.thinking == "default" else types.ThinkingConfig(thinking_level=args.thinking),
        ),
    )
    client.files.delete(name=uploaded.name)

    data = json.loads(response.text)
    usage = response.usage_metadata
    data["_run"] = {
        "model": args.model,
        "seconds": round(time.time() - started, 1),
        "finish_reason": str(response.candidates[0].finish_reason),
        "input_tokens": usage.prompt_token_count,
        "output_tokens": usage.candidates_token_count,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(data, indent=2))
    segs = data["segments"]
    print(f"{args.audio.name}: {len(segs)} segments, {len({s['speaker'] for s in segs})} speakers, "
          f"{data['_run']['seconds']}s, finish {data['_run']['finish_reason']}, "
          f"tokens in {usage.prompt_token_count} out {usage.candidates_token_count}")


if __name__ == "__main__":
    main()
