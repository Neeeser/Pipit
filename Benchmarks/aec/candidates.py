"""Every echo canceller the bake-off runs, behind one call signature.

Each candidate is a function ``run(mic, ref, out)`` that reads two 16 kHz mono
WAV files and writes the cleaned microphone as a 16 kHz mono WAV. Runtimes are
found through environment variables so the harness has no opinion about where
a binary was built:

  PIPIT_EVAL         path to pipit-eval (default .build/debug/pipit-eval)
  LOCALVQE_BIN       path to the LocalVQE command-line binary
  LOCALVQE_MODELS    directory holding the LocalVQE .gguf files
  DTLN_MODELS        directory holding model_{128,256,512}_{1,2}.onnx
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import numpy as np
import soundfile as sf

REPO = Path(__file__).resolve().parents[2]
PIPIT_EVAL = Path(os.environ.get("PIPIT_EVAL", REPO / ".build/debug/pipit-eval"))
LOCALVQE_BIN = os.environ.get("LOCALVQE_BIN")
LOCALVQE_MODELS = Path(os.environ.get("LOCALVQE_MODELS", "~/Library/Caches/pipit-bench/aec/models/localvqe")).expanduser()
DTLN_MODELS = Path(os.environ.get("DTLN_MODELS", "~/Library/Caches/pipit-bench/aec/models/dtln")).expanduser()

RATE = 16000


def read(path: Path) -> np.ndarray:
    audio, rate = sf.read(path, dtype="float32", always_2d=True)
    if rate != RATE:
        raise ValueError(f"{path} is {rate} Hz, the harness takes {RATE} Hz")
    return audio[:, 0]


def write(path: Path, audio: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(path, audio.astype(np.float32), RATE, subtype="FLOAT")


def shipped(mic: Path, ref: Path, out: Path, offset: float | None = None) -> None:
    """Pipit's shipped pass, whatever it is on this checkout, through
    `pipit-eval aec`: the envelope alignment, the lead, and the canceller."""
    command = [str(PIPIT_EVAL), "aec", "--mic", str(mic), "--reference", str(ref), "--out", str(out)]
    if offset is not None:
        command += ["--offset", str(offset)]
    subprocess.run(command, check=True, capture_output=True)


class DTLN:
    """DTLN-aec from the published weights, run through onnxruntime.

    Two models per size. The first masks the microphone magnitude spectrum
    given the far end's; the second refines the time-domain block. States are
    carried between hops by the caller. Block 512, hop 128, no alignment
    stage of its own.
    """

    BLOCK = 512
    HOP = 128

    def __init__(self, units: int):
        import onnxruntime as ort

        options = ort.SessionOptions()
        options.intra_op_num_threads = 1
        options.inter_op_num_threads = 1
        options.log_severity_level = 3
        self.units = units
        self.model1 = ort.InferenceSession(str(DTLN_MODELS / f"model_{units}_1.onnx"), options)
        self.model2 = ort.InferenceSession(str(DTLN_MODELS / f"model_{units}_2.onnx"), options)
        self.names1 = [i.name for i in self.model1.get_inputs()]
        self.names2 = [i.name for i in self.model2.get_inputs()]

    def process(self, mic: np.ndarray, ref: np.ndarray) -> np.ndarray:
        n = min(len(mic), len(ref))
        mic, ref = mic[:n], ref[:n]
        block, hop = self.BLOCK, self.HOP
        state1 = np.zeros((1, 2, self.units, 2), np.float32)
        state2 = np.zeros((1, 2, self.units, 2), np.float32)
        in_mic = np.zeros(block, np.float32)
        in_ref = np.zeros(block, np.float32)
        out_buffer = np.zeros(block, np.float32)
        out = np.zeros(n, np.float32)
        for i in range(n // hop):
            in_mic[:-hop] = in_mic[hop:]
            in_mic[-hop:] = mic[i * hop:(i + 1) * hop]
            in_ref[:-hop] = in_ref[hop:]
            in_ref[-hop:] = ref[i * hop:(i + 1) * hop]
            spectrum = np.fft.rfft(in_mic)
            ref_spectrum = np.fft.rfft(in_ref)
            mask, state1 = self.model1.run(
                None,
                {
                    self.names1[0]: np.abs(spectrum)[None, None, :].astype(np.float32),
                    self.names1[1]: state1,
                    self.names1[2]: np.abs(ref_spectrum)[None, None, :].astype(np.float32),
                },
            )
            estimate = np.fft.irfft(spectrum * mask[0, 0]).astype(np.float32)
            block_out, state2 = self.model2.run(
                None,
                {
                    self.names2[0]: estimate[None, None, :],
                    self.names2[1]: state2,
                    self.names2[2]: in_ref[None, None, :],
                },
            )
            out_buffer[:-hop] = out_buffer[hop:]
            out_buffer[-hop:] = 0
            out_buffer += block_out[0, 0]
            out[i * hop:(i + 1) * hop] = out_buffer[:hop]
        return out


_dtln_cache: dict[int, DTLN] = {}


def dtln(units: int):
    def run(mic: Path, ref: Path, out: Path) -> None:
        model = _dtln_cache.setdefault(units, DTLN(units))
        write(out, model.process(read(mic), read(ref)))

    run.__name__ = f"dtln{units}"
    return run


def localvqe(model_file: str):
    def run(mic: Path, ref: Path, out: Path) -> None:
        if not LOCALVQE_BIN:
            raise RuntimeError("LOCALVQE_BIN is not set")
        out.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [LOCALVQE_BIN, str(LOCALVQE_MODELS / model_file), "--in-wav", str(mic), str(ref), "--out-wav", str(out)],
            check=True,
            capture_output=True,
        )
        # LocalVQE writes 16-bit PCM. Re-read so every candidate's output is float WAV.
        write(out, read(out))

    run.__name__ = "localvqe_" + model_file.split("-f32")[0].replace("localvqe-", "").replace(".", "_")
    return run


def cascade(first, second):
    def run(mic: Path, ref: Path, out: Path) -> None:
        middle = out.with_suffix(".stage1.wav")
        first(mic, ref, middle)
        second(middle, ref, out)
        middle.unlink(missing_ok=True)

    run.__name__ = f"{first.__name__}+{second.__name__}"
    return run


def all_candidates() -> dict:
    lvqe_14 = localvqe("localvqe-v1.4-aec-200K-f32.gguf")
    lvqe_filter = localvqe("localvqe-v1.4-aec-2.7K-f32.gguf")
    lvqe_12 = localvqe("localvqe-v1.2-1.3M-f32.gguf")
    lvqe_13 = localvqe("localvqe-v1.3-4.8M-f32.gguf")
    candidates = [
        shipped,
        dtln(128),
        dtln(256),
        dtln(512),
        lvqe_14,
        lvqe_filter,
        lvqe_12,
        lvqe_13,
        cascade(lvqe_filter, dtln(512)),
        cascade(lvqe_14, dtln(512)),
        cascade(lvqe_14, dtln(256)),
    ]
    return {c.__name__: c for c in candidates}
