#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10,<3.14"
# dependencies = ["onnxruntime>=1.20", "tokenizers>=0.20", "numpy>=1.26", "huggingface_hub>=0.25"]
# ///
"""Embed texts on this Mac with a sentence-embedding model's ONNX export.

Reads {"model": "<hugging face id>", "texts": [...]} on stdin and writes
{"embeddings": [[...], ...]} on stdout, one unit-length vector per text in the
order given. `pipit-eval summaries` runs this to match a model's items with an
answer key's, so nothing it compares leaves the machine.

    echo '{"model": "hindsight-ai/hs-embed-1", "texts": ["one", "two"]}' | uv run scripts/embed-texts.py

The model is downloaded once into the Hugging Face cache. It has to publish
onnx/model.onnx and tokenizer.json and use mean pooling, as hs-embed-1 does.
"""

import json
import sys

import numpy as np
import onnxruntime
from huggingface_hub import hf_hub_download
from tokenizers import Tokenizer

BATCH = 32
MAX_TOKENS = 512


def main():
    request = json.load(sys.stdin)
    model = request["model"]
    texts = request["texts"]

    tokenizer = Tokenizer.from_file(hf_hub_download(model, "tokenizer.json"))
    tokenizer.enable_truncation(MAX_TOKENS)
    tokenizer.enable_padding()
    session = onnxruntime.InferenceSession(
        hf_hub_download(model, "onnx/model.onnx"), providers=["CPUExecutionProvider"]
    )
    inputs = {i.name for i in session.get_inputs()}

    vectors = []
    for start in range(0, len(texts), BATCH):
        encoded = tokenizer.encode_batch(texts[start:start + BATCH])
        ids = np.array([e.ids for e in encoded], dtype=np.int64)
        mask = np.array([e.attention_mask for e in encoded], dtype=np.int64)
        feed = {"input_ids": ids, "attention_mask": mask}
        if "token_type_ids" in inputs:
            feed["token_type_ids"] = np.zeros_like(ids)
        hidden = session.run(None, {k: v for k, v in feed.items() if k in inputs})[0]
        # Mean over the real tokens, the pooling the model was trained with,
        # then unit length so a dot product is the cosine.
        weights = mask[..., None].astype(np.float32)
        pooled = (hidden * weights).sum(axis=1) / np.maximum(weights.sum(axis=1), 1e-9)
        pooled /= np.maximum(np.linalg.norm(pooled, axis=1, keepdims=True), 1e-12)
        vectors.extend(pooled.tolist())

    json.dump({"embeddings": vectors}, sys.stdout)


if __name__ == "__main__":
    main()
