"""Writes the DTLN-aec weights Pipit's Swift port reads.

Reads the two ONNX halves of one DTLN-aec size and writes every tensor the
port needs, float32 little-endian, into one file in a fixed order, with a JSON
sidecar naming each tensor, its shape and byte offset. Matrices keep the ONNX
layout: an LSTM input kernel is (inputs, 4 * units) with gates in the order
i, f, g, o; a recurrent kernel is (units, 4 * units); the encoder and decoder
are (out, in).

Usage: python3 export_dtln.py --units 512 --models DIR --out FILE
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import onnx
from onnx import numpy_helper


def tensors(model_path: Path) -> dict[str, np.ndarray]:
    model = onnx.load(str(model_path))
    return {t.name: numpy_helper.to_array(t) for t in model.graph.initializer}


def pick(table: dict[str, np.ndarray], fragment: str, shape: tuple[int, ...]) -> np.ndarray:
    matches = [v for k, v in table.items() if fragment in k and v.shape == shape]
    if len(matches) != 1:
        raise SystemExit(f"{fragment} with shape {shape}: {len(matches)} matches")
    return matches[0].astype(np.float32)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--units", type=int, default=512)
    parser.add_argument("--models", type=Path, default=Path("~/Library/Caches/pipit-bench/aec/models/dtln").expanduser())
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    u = args.units
    bins = 257
    block = 512
    p1 = tensors(args.models / f"model_{u}_1.onnx")
    p2 = tensors(args.models / f"model_{u}_2.onnx")

    # The layer-norm and LSTM names carry Keras layer numbers that differ per
    # export, so tensors are found by shape and role rather than by name.
    def lstm_kernels(table, inputs):
        ins = [v for k, v in table.items() if v.shape == (inputs, 4 * u) and "const_fold" in k]
        recs = [v for k, v in table.items() if v.shape == (u, 4 * u) and "const_fold" in k]
        return ins, recs

    order = []

    def add(name, array):
        order.append((name, np.ascontiguousarray(array, dtype=np.float32)))

    # Part 1. Two layer norms on 257 bins (mic then far end), two LSTMs, one dense.
    ln1 = sorted([(k, v) for k, v in p1.items() if v.shape == (bins,) and "instant_layer_normalization" in k])
    # Keras numbers the mic norm first; each norm has gamma (lower id) then beta.
    (mic_gamma_k, mic_gamma), (mic_beta_k, mic_beta), (lpb_gamma_k, lpb_gamma), (lpb_beta_k, lpb_beta) = ln1
    add("p1.mic.gamma", mic_gamma); add("p1.mic.beta", mic_beta)
    add("p1.lpb.gamma", lpb_gamma); add("p1.lpb.beta", lpb_beta)
    add("p1.lstm1.kernel", pick(p1, "const_fold", (2 * bins, 4 * u)))
    rec1 = [v for k, v in p1.items() if v.shape == (u, 4 * u)]
    # The recurrent kernel of layer 1 and both kernels of layer 2 share a shape.
    # The graph multiplies layer 1's state by the tensor with the higher fold id
    # of the pair used with a state slice; resolved here from the node graph.
    model1 = onnx.load(str(args.models / f"model_{u}_1.onnx"))
    by_state = {}
    for node in model1.graph.node:
        if node.op_type == "MatMul":
            by_state[node.output[0]] = node.input[1]
        if node.op_type == "Gemm":
            by_state[node.output[0]] = (node.input[1], node.input[2])
    gemms = [v for v in by_state.values() if isinstance(v, tuple)]
    # Gemm(x, W, C=h@R): first Gemm is layer 1 (its W has 514 rows).
    layer1 = next(g for g in gemms if p1[g[0]].shape[0] == 2 * bins)
    layer2 = next(g for g in gemms if p1[g[0]].shape[0] == u)
    add("p1.lstm1.recurrent", p1[by_state[layer1[1]]])
    biases1 = sorted([(k, v) for k, v in p1.items() if v.shape == (4 * u,)])
    add("p1.lstm1.bias", biases1[0][1] if "lstm_4" in biases1[0][0] or biases1[0][0] < biases1[1][0] else biases1[1][1])
    add("p1.lstm2.kernel", p1[layer2[0]])
    add("p1.lstm2.recurrent", p1[by_state[layer2[1]]])
    add("p1.lstm2.bias", biases1[1][1] if "lstm_4" in biases1[0][0] or biases1[0][0] < biases1[1][0] else biases1[0][1])
    add("p1.dense.kernel", pick(p1, "const_fold", (u, bins)))
    add("p1.dense.bias", pick(p1, "dense", (bins,)))

    # Part 2. Shared encoder, two layer norms on 512 features (estimate then far end), two LSTMs, dense, decoder.
    model2 = onnx.load(str(args.models / f"model_{u}_2.onnx"))
    convs = [n for n in model2.graph.node if n.op_type == "Conv"]
    encoder_name = convs[0].input[1]
    decoder_name = convs[-1].input[1]
    add("p2.encoder", p2[encoder_name].reshape(u, block))
    ln2 = sorted([(k, v) for k, v in p2.items() if v.shape == (u,) and "instant_layer_normalization" in k])
    (e_gamma_k, e_gamma), (e_beta_k, e_beta), (l_gamma_k, l_gamma), (l_beta_k, l_beta) = ln2
    add("p2.est.gamma", e_gamma); add("p2.est.beta", e_beta)
    add("p2.lpb.gamma", l_gamma); add("p2.lpb.beta", l_beta)
    by_state2 = {}
    for node in model2.graph.node:
        if node.op_type == "MatMul":
            by_state2[node.output[0]] = node.input[1]
        if node.op_type == "Gemm":
            by_state2[node.output[0]] = (node.input[1], node.input[2])
    gemms2 = [v for v in by_state2.values() if isinstance(v, tuple)]
    layer1 = next(g for g in gemms2 if p2[g[0]].shape[0] == 2 * u)
    layer2 = next(g for g in gemms2 if p2[g[0]].shape[0] == u and p2[g[0]].shape[1] == 4 * u)
    biases2 = sorted([(k, v) for k, v in p2.items() if v.shape == (4 * u,)])
    add("p2.lstm1.kernel", p2[layer1[0]]); add("p2.lstm1.recurrent", p2[by_state2[layer1[1]]]); add("p2.lstm1.bias", biases2[0][1])
    add("p2.lstm2.kernel", p2[layer2[0]]); add("p2.lstm2.recurrent", p2[by_state2[layer2[1]]]); add("p2.lstm2.bias", biases2[1][1])
    add("p2.dense.kernel", pick(p2, "const_fold", (u, u)))
    add("p2.dense.bias", pick(p2, "dense", (u,)))
    add("p2.decoder", p2[decoder_name].reshape(block, u))

    args.out.parent.mkdir(parents=True, exist_ok=True)
    offset = 0
    index = []
    with open(args.out, "wb") as f:
        for name, array in order:
            data = array.tobytes()
            f.write(data)
            index.append({"name": name, "shape": list(array.shape), "offset": offset, "count": int(array.size)})
            offset += len(data)
    digest = hashlib.sha256(args.out.read_bytes()).hexdigest()
    sidecar = {"model": f"dtln-aec-{u}", "units": u, "bins": bins, "block": block, "hop": 128, "bytes": offset, "sha256": digest, "tensors": index}
    args.out.with_suffix(".json").write_text(json.dumps(sidecar, indent=1))
    print(f"wrote {args.out} ({offset / 1e6:.1f} MB) sha256 {digest}")
    for entry in index:
        print(f"  {entry['name']:20s} {entry['shape']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
