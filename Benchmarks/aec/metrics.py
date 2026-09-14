"""Scores for one cleaned clip.

Signal scores need only the audio. Transcript scores need parakeet output for
the clip, the far end, and the near-end truth, produced in one batch by
``pipit-eval asr --json`` so the model loads once per candidate.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

import numpy as np

RATE = 16000
WINDOW = 4000  # 0.25 s, the grid Pipit measures on


def window_db(audio: np.ndarray, window: int = WINDOW) -> np.ndarray:
    count = len(audio) // window
    if count == 0:
        return np.array([])
    frames = audio[: count * window].reshape(count, window)
    return 20 * np.log10(np.sqrt(np.mean(frames * frames, axis=1)) + 1e-9)


def echo_removed_db(mic: np.ndarray, out: np.ndarray, ref: np.ndarray, far_floor_db: float = -60.0) -> float:
    """Median level drop over windows where the far end was playing.

    Measured on the audio, not the canceller's own report. On a far-end-only
    clip this is ERLE.
    """
    n = min(len(mic), len(out), len(ref))
    before, after, far = window_db(mic[:n]), window_db(out[:n]), window_db(ref[:n])
    active = far > far_floor_db
    if active.sum() == 0:
        return float("nan")
    return float(np.median(before[active] - after[active]))


def residual_correlation(out: np.ndarray, ref: np.ndarray, max_lag_s: float = 0.5) -> float:
    """Peak normalised cross-correlation of the output with the far end.

    Near zero when nothing of the far end is left; the raw microphone on a
    loud-speaker call reads 0.4 to 0.6.
    """
    from scipy.signal import fftconvolve

    n = min(len(out), len(ref))
    a = out[:n] - out[:n].mean()
    b = ref[:n] - ref[:n].mean()
    norm = np.linalg.norm(a) * np.linalg.norm(b)
    if norm == 0:
        return 0.0
    c = fftconvolve(a, b[::-1], mode="full")
    mid = len(b) - 1
    lag = int(max_lag_s * RATE)
    return float(np.abs(c[mid - lag : mid + lag + 1]).max() / norm)


def aligned(estimate: np.ndarray, target: np.ndarray, max_lag_s: float = 0.1) -> np.ndarray:
    """The estimate shifted onto the target's clock.

    A canceller adds its own block delay (32 ms for DTLN-aec), and a
    sample-level score against the clean target would charge that delay as
    distortion.
    """
    from scipy.signal import fftconvolve

    n = min(len(estimate), len(target))
    a = estimate[:n] - estimate[:n].mean()
    b = target[:n] - target[:n].mean()
    if np.linalg.norm(a) == 0 or np.linalg.norm(b) == 0:
        return estimate
    c = fftconvolve(a, b[::-1], mode="full")
    mid = len(b) - 1
    lag = int(max_lag_s * RATE)
    shift = int(np.argmax(c[mid - lag : mid + lag + 1])) - lag  # estimate lags target by shift
    if shift > 0:
        return np.concatenate([estimate[shift:], np.zeros(shift, estimate.dtype)])
    if shift < 0:
        return np.concatenate([np.zeros(-shift, estimate.dtype), estimate[:shift]])
    return estimate


def si_sdr_db(estimate: np.ndarray, target: np.ndarray) -> float:
    """Scale-invariant SDR of the output against the clean near-end, after
    removing the canceller's own delay."""
    estimate = aligned(estimate, target)
    n = min(len(estimate), len(target))
    e, t = estimate[:n].astype(np.float64), target[:n].astype(np.float64)
    if np.dot(t, t) == 0:
        return float("nan")
    scale = np.dot(e, t) / np.dot(t, t)
    projection = scale * t
    noise = e - projection
    if np.dot(noise, noise) == 0:
        return float("inf")
    return float(10 * np.log10(np.dot(projection, projection) / np.dot(noise, noise)))


# --- transcript scores ------------------------------------------------------

_TOKEN = re.compile(r"[a-z0-9']+")


def tokens(text: str) -> list[str]:
    return _TOKEN.findall(text.lower())


@dataclass
class Word:
    text: str
    start: float
    end: float


def words_from(result: dict) -> list[Word]:
    out = []
    for w in result.get("words", []):
        for token in tokens(w["text"]):
            out.append(Word(token, float(w["start"]), float(w["end"])))
    return out


@dataclass
class TranscriptScore:
    output_words: int = 0
    truth_words: int = 0
    far_words: int = 0
    leaked: int = 0
    lost: int = 0
    kept: int = 0
    leaked_examples: list = field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "outputWords": self.output_words,
            "truthWords": self.truth_words,
            "farWords": self.far_words,
            "leaked": self.leaked,
            "lost": self.lost,
            "kept": self.kept,
        }


def _near(word: Word, pool: list[Word], seconds: float) -> bool:
    return any(p.text == word.text and abs(p.start - word.start) <= seconds for p in pool)


def transcript_score(
    output: list[Word], far: list[Word], truth: list[Word] | None, window_s: float = 3.0
) -> TranscriptScore:
    """Leaked and lost words for one clip.

    A leaked word is in the output and in the far end's own transcript within
    ``window_s``, and not in the near-end truth within the same window. A lost
    word is in the truth and nowhere in the output within the window. Short
    function words are skipped for leaks because the far end and the user
    both say them.
    """
    score = TranscriptScore(output_words=len(output), far_words=len(far), truth_words=len(truth or []))
    skip = {"a", "an", "the", "and", "or", "of", "to", "in", "on", "it", "is", "i", "you", "we", "so", "uh", "um", "yeah", "okay", "ok", "yes", "no", "like", "that", "this"}
    for word in output:
        if word.text in skip or len(word.text) < 3:
            continue
        if _near(word, far, window_s) and not (truth and _near(word, truth, window_s)):
            score.leaked += 1
            if len(score.leaked_examples) < 5:
                score.leaked_examples.append((round(word.start, 1), word.text))
    if truth is not None:
        for word in truth:
            if _near(word, output, window_s):
                score.kept += 1
            else:
                score.lost += 1
    return score
