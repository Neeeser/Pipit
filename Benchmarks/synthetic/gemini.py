"""Small Gemini API client for the synthetic meeting generator.

Reads the key from GEMINI_API_KEY and never prints it. Free-tier quotas are
low and not published, so every call waits `MIN_GAP_SECONDS` after the last
one and backs off on a 429 using the server's retry delay.
"""

import base64
import http.client
import io
import json
import os
import re
import time
import urllib.error
import urllib.request
import wave

API = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
MIN_GAP_SECONDS = 12.0
_last_call = 0.0
calls_made = 0


def _post(model: str, body: dict, attempts: int = 6, resend_lost: bool = True) -> dict:
    global _last_call, calls_made
    key = os.environ["GEMINI_API_KEY"]
    for attempt in range(attempts):
        wait = MIN_GAP_SECONDS - (time.monotonic() - _last_call)
        if wait > 0:
            time.sleep(wait)
        request = urllib.request.Request(
            API.format(model=model), data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json", "x-goog-api-key": key},
        )
        _last_call = time.monotonic()
        calls_made += 1
        try:
            with urllib.request.urlopen(request, timeout=600) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            if error.code not in (429, 500, 503) or attempt == attempts - 1:
                raise RuntimeError("Gemini %s returned %d: %s" % (model, error.code, detail[:600])) from None
            if error.code == 429 and "PerDay" in detail:
                raise RuntimeError(f"Gemini daily quota reached: {detail[:600]}") from None
            delay = re.search(r'"retryDelay":\s*"(\d+)', detail)
            pause = int(delay.group(1)) + 2 if delay else 30 * (attempt + 1)
            print("  Gemini %d, waiting %d s" % (error.code, pause), flush=True)
            time.sleep(pause)
        except (TimeoutError, ConnectionError, http.client.HTTPException, urllib.error.URLError) as error:
            # The server may have finished and counted the request anyway.
            if attempt == attempts - 1 or not resend_lost:
                raise RuntimeError(f"Gemini {model} unreachable: {error}") from None
            print(f"  Gemini unreachable ({error}), retrying in 30 s", flush=True)
            time.sleep(30)
    raise AssertionError("unreachable")


def text(model: str, prompt: str, schema: dict | None = None, audio: tuple[bytes, str] | None = None,
         temperature: float = 1.0) -> str:
    """The model's text answer. `audio` is (file bytes, MIME type), sent before the prompt."""
    config: dict = {"temperature": temperature}
    if schema is not None:
        config.update({"responseMimeType": "application/json", "responseSchema": schema})
    parts: list[dict] = []
    if audio is not None:
        parts.append({"inlineData": {"mimeType": audio[1], "data": base64.b64encode(audio[0]).decode()}})
    parts.append({"text": prompt})
    reply = _post(model, {"contents": [{"parts": parts}], "generationConfig": config})
    return "".join(p.get("text", "") for p in reply["candidates"][0]["content"]["parts"])


def speech(model: str, words: str, voice: str) -> bytes:
    """A WAV file's bytes, 16-bit mono.

    Every attempt may count against the small daily quota. A request the server
    refused (429, 500, 503) is tried once more; a lost connection is reported
    rather than resent, since the lost request may have been counted.
    """
    reply = _post(model, {
        "contents": [{"parts": [{"text": words}]}],
        "generationConfig": {
            "responseModalities": ["AUDIO"],
            "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": voice}}},
        },
    }, attempts=2, resend_lost=False)
    candidate = (reply.get("candidates") or [{}])[0]
    parts = [p for p in candidate.get("content", {}).get("parts", []) if "inlineData" in p]
    if not parts:
        raise RuntimeError("Gemini %s returned no audio (finish reason %s)" % (model, candidate.get("finishReason")))
    finish = candidate.get("finishReason")
    if finish not in (None, "STOP"):
        # A reply cut off at a limit still carries audio, and the cache would keep it.
        raise RuntimeError("Gemini %s stopped before finishing the audio (finish reason %s)" % (model, finish))
    data, mime = base64.b64decode(parts[0]["inlineData"]["data"]), parts[0]["inlineData"].get("mimeType", "")
    if data[:4] == b"RIFF":
        return data
    # The API documents raw 16-bit PCM, such as "audio/L16;codec=pcm;rate=24000".
    rate = re.search(r"rate=(\d+)", mime)
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(int(rate.group(1)) if rate else 24000)
        out.writeframes(data)
    return buffer.getvalue()
