"""Simulate a two-track call from a meeting recorded with one microphone per person.

A call that Pipit records has two tracks. The microphone holds the local person
and, when they listen on laptop speakers, an echo of everyone else. The system
audio track holds everyone else after the call app's codec. This module builds
both from the close-talk channels of a meeting corpus and the reference words
Pipit scores against, so the benchmark can measure speaker separation and echo
removal on a call whose answer is known.

Everything is a pure function of the inputs and a seed. The only external
program is ffmpeg, for the Opus round trip.
"""

from __future__ import annotations

import hashlib
import json
import random
import shutil
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import scipy.ndimage
import scipy.signal
import soundfile as sf

RATE = 16000
GENERATOR_VERSION = 1

# One person is the local user. A person who says almost nothing makes the
# "local words lost" number meaningless, so the pick only considers people who
# said at least this share of the words in the scored window.
MIN_LOCAL_WORD_SHARE = 0.15

# A close-talk channel keeps a little of everyone else's voice. The channel is
# silenced outside the owner's own speech, padded so word edges survive, and a
# gap shorter than this inside speech is kept so a breath between two words
# does not turn into a dropout.
GATE_PAD_SECONDS = 0.25
GATE_MERGE_GAP_SECONDS = 0.6
GATE_FADE_SECONDS = 0.02

# Active-speech levels, in dBFS RMS. Participants differ by a few dB.
REMOTE_LEVEL_DB = -23.0
LOCAL_LEVEL_DB = -28.0
LEVEL_JITTER_DB = 3.0
MIC_NOISE_DB = -62.0

# Call audio: Opus at a bitrate calls use, in the voice mode.
OPUS_BITRATE = "24k"

# How the laptop reproduces the call. It cannot play bass, it distorts a
# little at its loudest, and the sound crosses the room before the microphone
# hears it.
SPEAKER_HIGHPASS_HZ = 200.0
SPEAKER_DRIVE = 1.2
PLAYBACK_DELAY_RANGE = (0.06, 0.14)
RT60_RANGE = (0.25, 0.5)
DIRECT_TO_REVERB_DB = 12.0

ENVELOPE_WINDOW = 160  # 10 ms at 16 kHz, the window Pipit measures with
SEARCH_SECONDS = 8.0  # how far either way Pipit looks for the far end


def seeded(seed: int, *parts: object) -> np.random.Generator:
    """A generator that depends only on the seed and the named parts."""
    digest = hashlib.sha256(":".join([str(seed), *map(str, parts)]).encode()).digest()
    return np.random.default_rng(int.from_bytes(digest[:8], "big"))


def word_counts(truth: dict) -> dict[str, int]:
    counts: dict[str, int] = {}
    for word in truth["words"]:
        counts[word["agent"]] = counts.get(word["agent"], 0) + 1
    return counts


def choose_local_agent(seed: int, meeting: str, truth: dict) -> str:
    """The annotation agent who plays the local person in this meeting."""
    counts = word_counts(truth)
    total = sum(counts.values())
    eligible = sorted(a for a, n in counts.items() if n >= MIN_LOCAL_WORD_SHARE * total)
    if not eligible:
        raise ValueError("%s has no speaker with %.0f%% of the words" % (meeting, MIN_LOCAL_WORD_SHARE * 100))
    return random.Random("%s:%s" % (seed, meeting)).choice(eligible)


# --- audio helpers ---------------------------------------------------------


def read_channel(path: Path, start: float | None, seconds: float | None) -> np.ndarray:
    """Mono float32 samples of a window, or the whole file when `start` is None."""
    info = sf.info(path)
    if info.samplerate != RATE:
        raise ValueError("%s is %d Hz, the simulator takes %d Hz" % (path, info.samplerate, RATE))
    first = int(round((start or 0.0) * RATE))
    stop = None if start is None or seconds is None else first + int(round(seconds * RATE))
    audio, _ = sf.read(path, start=first, stop=stop, dtype="float32", always_2d=True)
    return audio[:, 0].copy()


def speech_mask(words: list[dict], samples: int) -> np.ndarray:
    """1 where the owner of `words` speaks, padded, with soft edges."""
    spans = sorted(
        (max(0.0, w["start"] - GATE_PAD_SECONDS), min(samples / RATE, w["end"] + GATE_PAD_SECONDS))
        for w in words
    )
    merged: list[list[float]] = []
    for start, end in spans:
        if merged and start - merged[-1][1] <= GATE_MERGE_GAP_SECONDS:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    mask = np.zeros(samples, dtype=np.float32)
    for start, end in merged:
        mask[int(start * RATE) : int(end * RATE)] = 1.0
    width = max(1, int(GATE_FADE_SECONDS * RATE))
    return scipy.ndimage.uniform_filter1d(mask, width, mode="constant").astype(np.float32)


def active_level_db(audio: np.ndarray, mask: np.ndarray) -> float:
    active = audio[mask > 0.99]
    if active.size == 0:
        return -120.0
    return float(10 * np.log10(np.mean(active.astype(np.float64) ** 2) + 1e-20))


def scaled_to(audio: np.ndarray, mask: np.ndarray, target_db: float) -> np.ndarray:
    gain = 10 ** ((target_db - active_level_db(audio, mask)) / 20)
    return (audio * gain).astype(np.float32)


def pink_noise(rng: np.random.Generator, samples: int, level_db: float) -> np.ndarray:
    """Room and preamp noise, with the tilt a real microphone has."""
    white = rng.standard_normal(samples)
    pink = scipy.signal.lfilter(
        [0.049922035, -0.095993537, 0.050612699, -0.004408786],
        [1.0, -2.494956002, 2.017265875, -0.522189400],
        white,
    )
    pink *= 10 ** (level_db / 20) / np.sqrt(np.mean(pink**2))
    return pink.astype(np.float32)


def opus_round_trip(audio: np.ndarray, bitrate: str = OPUS_BITRATE) -> np.ndarray:
    """What a call app does to a voice: encode, then decode. Same length out."""
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        raise RuntimeError("ffmpeg is needed for the codec round trip")
    with tempfile.TemporaryDirectory(prefix="pipit-calls-") as scratch:
        source, coded, decoded = (Path(scratch) / name for name in ("in.wav", "out.opus", "out.wav"))
        sf.write(source, np.clip(audio, -1, 1), RATE, subtype="FLOAT")
        quiet = [ffmpeg, "-v", "error", "-y", "-threads", "1"]
        subprocess.run(
            [*quiet, "-i", str(source), "-c:a", "libopus", "-b:a", bitrate, "-application", "voip", str(coded)],
            check=True,
        )
        subprocess.run(
            [*quiet, "-i", str(coded), "-ar", str(RATE), "-ac", "1", "-c:a", "pcm_f32le", str(decoded)],
            check=True,
        )
        out, rate = sf.read(decoded, dtype="float32", always_2d=True)
    assert rate == RATE
    out = out[:, 0]
    if len(out) < len(audio):
        out = np.pad(out, (0, len(audio) - len(out)))
    return out[: len(audio)].copy()


# --- the echo path ---------------------------------------------------------


@dataclass
class EchoPath:
    delay_seconds: float
    rt60_seconds: float
    impulse: np.ndarray = field(repr=False)


def make_echo_path(rng: np.random.Generator) -> EchoPath:
    """A synthetic room: a direct path, a few early reflections, a decaying tail."""
    delay = float(rng.uniform(*PLAYBACK_DELAY_RANGE))
    rt60 = float(rng.uniform(*RT60_RANGE))
    length = int((delay + rt60 * 1.1) * RATE)
    direct = int(delay * RATE)
    reverb = np.zeros(length)
    for _ in range(6):
        at = direct + int(rng.uniform(0.002, 0.035) * RATE)
        reverb[at] += rng.choice([-1.0, 1.0]) * rng.uniform(0.15, 0.5)
    tail_start = direct + int(0.03 * RATE)
    t = np.arange(length - tail_start) / RATE
    tail = rng.standard_normal(length - tail_start) * np.exp(-6.91 * t / rt60)
    low = scipy.signal.butter(1, 4000 / (RATE / 2), output="sos")
    reverb[tail_start:] += scipy.signal.sosfilt(low, tail)
    # Scale everything but the direct path to the energy the ratio asks for.
    reverb *= np.sqrt(10 ** (-DIRECT_TO_REVERB_DB / 10) / np.sum(reverb**2))
    impulse = reverb
    impulse[direct] += 1.0
    return EchoPath(delay, rt60, impulse.astype(np.float32))


def laptop_speaker_echo(played: np.ndarray, path: EchoPath) -> np.ndarray:
    """The call as the microphone hears it, at unit gain."""
    sos = scipy.signal.butter(2, SPEAKER_HIGHPASS_HZ / (RATE / 2), "high", output="sos")
    thin = scipy.signal.sosfilt(sos, played).astype(np.float32)
    peak = float(np.percentile(np.abs(thin), 99.5)) or 1.0
    # tanh bends only the loudest peaks, which is all a laptop speaker does at
    # a normal volume.
    bent = (peak / SPEAKER_DRIVE) * np.tanh(SPEAKER_DRIVE * thin / peak)
    return scipy.signal.oaconvolve(bent, path.impulse)[: len(played)].astype(np.float32)


# --- Pipit's own measure of how much echo a microphone holds ----------------


def envelope(audio: np.ndarray) -> np.ndarray:
    """RMS loudness per 10 ms, as `EchoCancellationPass.measureAlignment` takes it."""
    count = len(audio) // ENVELOPE_WINDOW
    frames = audio[: count * ENVELOPE_WINDOW].astype(np.float64).reshape(count, ENVELOPE_WINDOW)
    return np.sqrt(np.mean(frames**2, axis=1))


def echo_correlation(microphone: np.ndarray, reference: np.ndarray) -> tuple[float, float]:
    """Best agreement between the two loudness curves, and the lag it sits at.

    Mirrors what Pipit stores as `cleanedMic.echoCorrelationBefore`: Pearson
    agreement of the 10 ms envelopes, searched eight seconds either way, with
    both curves centred and divided by their whole-recording magnitudes.
    Returns (correlation, seconds the far end has to move).
    """
    near, far = envelope(microphone), envelope(reference)
    count = min(len(near), len(far))
    a = near[:count] - near[:count].mean()
    b = far[:count] - far[:count].mean()
    scale = np.sqrt(np.sum(a * a) * np.sum(b * b))
    if scale == 0:
        return 0.0, 0.0
    span = int(round(SEARCH_SECONDS / (ENVELOPE_WINDOW / RATE)))
    size = 1 << int(np.ceil(np.log2(count + span + 1)))
    product = np.fft.rfft(a, size) * np.conj(np.fft.rfft(b, size))
    cross = np.fft.irfft(product, size)  # cross[l] = sum_i a[i + l] * b[i]
    lags = np.arange(-span, span + 1)
    values = cross[lags % size] / scale
    best = int(np.argmax(values))
    return float(values[best]), float(lags[best] * ENVELOPE_WINDOW / RATE)


# --- the case --------------------------------------------------------------


@dataclass
class Prepared:
    """What every variant of one meeting shares."""

    meeting: str
    local_agent: str
    local_speaker: str
    remote: np.ndarray
    local_voice: np.ndarray
    noise: np.ndarray
    echo_unit: np.ndarray = field(repr=False)
    path: EchoPath
    levels: dict[str, float]


def prepare_meeting(
    seed: int,
    meeting: str,
    truth: dict,
    local_agent: str,
    channels: dict[str, Path],
) -> Prepared:
    """Cut, gate, level and mix one meeting. Variants differ only in echo gain."""
    rng = seeded(seed, meeting)
    start = truth.get("windowStart")
    seconds = truth["windowSeconds"]
    speaker_of = truth["agentToSpeaker"]
    # A whole-meeting truth scores the first `seconds`; the headset files run a
    # little past the last annotated word, and that tail has no words to score.
    audio = {agent: read_channel(path, start or 0.0, seconds) for agent, path in sorted(channels.items())}
    samples = min(len(a) for a in audio.values())
    if samples / RATE < seconds - 1.0:
        raise ValueError("%s: the truth scores %.1f s but the channels run %.1f s" % (meeting, seconds, samples / RATE))

    masks: dict[str, np.ndarray] = {}
    gated: dict[str, np.ndarray] = {}
    levels: dict[str, float] = {}
    for agent in sorted(audio):
        words = [w for w in truth["words"] if w["agent"] == agent]
        masks[agent] = speech_mask(words, samples)
        voice = audio[agent][:samples] * masks[agent]
        jitter = float(rng.uniform(-LEVEL_JITTER_DB, LEVEL_JITTER_DB))
        target = (LOCAL_LEVEL_DB if agent == local_agent else REMOTE_LEVEL_DB) + jitter
        gated[agent] = scaled_to(voice, masks[agent], target)
        levels[speaker_of[agent]] = round(target, 2)

    others = [a for a in sorted(audio) if a != local_agent]
    mix = np.sum([gated[a] for a in others], axis=0).astype(np.float32)
    anyone = np.max([masks[a] for a in others], axis=0)
    mix = scaled_to(mix, anyone, REMOTE_LEVEL_DB)
    peak = float(np.max(np.abs(mix)))
    if peak > 0.9:
        mix *= 0.9 / peak
    remote = opus_round_trip(mix)

    path = make_echo_path(rng)
    return Prepared(
        meeting=meeting,
        local_agent=local_agent,
        local_speaker=speaker_of[local_agent],
        remote=remote,
        local_voice=gated[local_agent],
        noise=pink_noise(rng, samples, MIC_NOISE_DB),
        echo_unit=laptop_speaker_echo(remote, path),
        path=path,
        levels=levels,
    )


@dataclass
class Variant:
    name: str
    microphone: np.ndarray
    gain: float
    target_correlation: float | None
    correlation: float
    correlation_lag_seconds: float
    reached_target: bool
    echo_to_voice_db: float | None


def render_variant(prepared: Prepared, name: str, target: float | None) -> Variant:
    """The microphone for one variant. `target` None means headphones: no echo."""
    base = prepared.local_voice + prepared.noise
    if target is None:
        correlation, lag = echo_correlation(base, prepared.remote)
        return Variant(name, base.astype(np.float32), 0.0, None, correlation, lag, True, None)

    def at(gain: float) -> tuple[float, float]:
        return echo_correlation(base + gain * prepared.echo_unit, prepared.remote)

    low, high = 1e-3, 100.0
    top, _ = at(high)
    reached = top >= target
    if not reached:
        gain = high
    else:
        for _ in range(24):
            gain = float(np.sqrt(low * high))
            value, _ = at(gain)
            if abs(value - target) < 0.002:
                break
            if value < target:
                low = gain
            else:
                high = gain
    microphone = (base + gain * prepared.echo_unit).astype(np.float32)
    correlation, lag = echo_correlation(microphone, prepared.remote)
    voice_power = np.mean(prepared.local_voice[prepared.local_voice != 0].astype(np.float64) ** 2)
    echo_power = np.mean((gain * prepared.echo_unit[prepared.remote != 0]).astype(np.float64) ** 2)
    ratio = float(10 * np.log10(echo_power / voice_power))
    return Variant(name, microphone, gain, target, correlation, lag, reached, ratio)


def write_pcm16(path: Path, audio: np.ndarray) -> str:
    """Writes 16-bit mono WAV and returns the SHA-256 of the file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(path, np.clip(audio, -1.0, 1.0), RATE, subtype="PCM_16")
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(4 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def case_id(meeting: str, variant: str) -> str:
    return "%s-%s" % (meeting, variant)


def write_case(directory: Path, prepared: Prepared, variant: Variant, seed: int, truth: dict) -> dict:
    """Writes `mic.wav`, `remote.wav` and `case.json`, and returns the description."""
    directory.mkdir(parents=True, exist_ok=True)
    mic_hash = write_pcm16(directory / "mic.wav", variant.microphone)
    remote_hash = write_pcm16(directory / "remote.wav", prepared.remote)
    info = {
        "generatorVersion": GENERATOR_VERSION,
        "case": case_id(prepared.meeting, variant.name),
        "meeting": prepared.meeting,
        "variant": variant.name,
        "seed": seed,
        "localAgent": prepared.local_agent,
        "localSpeaker": prepared.local_speaker,
        "windowStart": truth.get("windowStart"),
        "windowSeconds": truth["windowSeconds"],
        "sampleRate": RATE,
        "files": {
            "mic": {"name": "mic.wav", "sha256": mic_hash},
            "remote": {"name": "remote.wav", "sha256": remote_hash},
        },
        "codec": {"name": "opus", "bitrate": OPUS_BITRATE, "application": "voip"},
        "speakerLevelsDB": prepared.levels,
        "echo": {
            "targetCorrelation": variant.target_correlation,
            "correlation": round(variant.correlation, 4),
            "correlationLagSeconds": round(variant.correlation_lag_seconds, 3),
            "reachedTarget": variant.reached_target,
            "gain": round(variant.gain, 6),
            "echoToLocalVoiceDB": None if variant.echo_to_voice_db is None else round(variant.echo_to_voice_db, 2),
            "playbackDelaySeconds": round(prepared.path.delay_seconds, 4),
            "rt60Seconds": round(prepared.path.rt60_seconds, 3),
        },
    }
    with open(directory / "case.json", "w") as handle:
        json.dump(info, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return info
