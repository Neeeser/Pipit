"""AECMOS, Microsoft's non-intrusive echo scorer, without the torch import.

Same features and model as ``AECMOS_local/aecmos.py`` in the AEC Challenge
repository (MIT). Two scores from 1 to 5: echo, and other degradation.
"""

from __future__ import annotations

import os
from pathlib import Path

import numpy as np

MODELS = Path(os.environ.get("AECMOS_MODELS", "~/Library/Caches/pipit-bench/aec/models")).expanduser()
RATE = 16000


class AECMOS:
    def __init__(self, scenario_aware: bool = True):
        import onnxruntime as ort

        name = "Run_1663915512_Stage_0.onnx" if scenario_aware else "Run_1663829550_Stage_0.onnx"
        options = ort.SessionOptions()
        options.log_severity_level = 3
        self.session = ort.InferenceSession(str(MODELS / name), options)
        self.input_name = self.session.get_inputs()[0].name
        self.scenario_aware = scenario_aware
        self.max_len = 20
        self.dft_size = 512
        self.hidden = (4, 1, 64)

    def _mel(self, audio: np.ndarray) -> np.ndarray:
        import librosa

        mel = librosa.feature.melspectrogram(
            y=audio, sr=RATE, n_fft=self.dft_size + 1, hop_length=self.dft_size // 2, n_mels=160
        )
        return ((librosa.power_to_db(mel, ref=np.max) + 40) / 40).T

    def score(self, lpb: np.ndarray, mic: np.ndarray, enh: np.ndarray, talk_type: str) -> tuple[float, float]:
        n = min(len(lpb), len(mic), len(enh), self.max_len * RATE)
        lpb, mic, enh = self._mel(lpb[:n]), self._mel(mic[:n]), self._mel(enh[:n])
        if self.scenario_aware:
            ne_st = 1 if talk_type == "nst" else 0
            fe_st = 1 if talk_type == "st" else 0
            width = mic.shape[1]
            mic = np.concatenate((mic, np.ones((20, width)) * (1 - fe_st), np.zeros((20, width))))
            lpb = np.concatenate((lpb, np.ones((20, width)) * (1 - ne_st), np.zeros((20, width))))
            enh = np.concatenate((enh, np.ones((20, width)), np.zeros((20, width))))
        feats = np.expand_dims(np.stack((lpb, mic, enh)).astype(np.float32), 0)
        h0 = np.zeros(self.hidden, np.float32)
        result = self.session.run([], {self.input_name: feats, "h0": h0})[0]
        return float(result[0]), float(result[1])
