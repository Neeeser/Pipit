# Echo canceller bake-off

Scores echo cancellers on recordings with a known answer, so the one Pipit
ships is chosen by measurement. The question it answers is the one a person
reading a transcript asks: how many of the far end's words ended up under my
name, and how many of my own words went missing.

## What is here

| File | Role |
| --- | --- |
| `fetch.py` | Downloads the public clips and models into `~/Library/Caches/pipit-bench/aec`, verified against Git LFS checksums. Nothing is committed: the AEC Challenge clips carry no dataset licence of their own. |
| `candidates.py` | Every canceller under test behind one `run(mic, ref, out)` signature. |
| `harness.py` | Runs one tier of recordings through every candidate, transcribes the outputs with parakeet through `pipit-eval asr --json`, and writes `results-<tier>.json` and `.md`. |
| `metrics.py` | Echo removed, residual correlation, SI-SDR, and the transcript scores. |
| `aecmos.py` | Microsoft's AECMOS scorer (MIT), without the torch import. |
| `requirements.txt` | Python packages for the harness. |

## Tiers

- `synthetic`: AEC Challenge synthetic validation clips, file ids under 500
  with a nonlinear far end, first 200. The clean near-end is known, so echo
  removed, SI-SDR, leaked and lost words are all measured.
- `real`: AEC Challenge 2021 real-device blind set, clean half, 72 Windows
  PCs. Far-end single talk (echo removed, leaked words), near-end single
  talk (the user's own level and words), double talk (leaked words, AECMOS).
- `meetings`: Pipit meeting folders read in place with `--meetings DIR`.
  Private. Decoded excerpts go under `--work` and nowhere else. The user's
  own words are taken as the microphone's words the far end did not also say.
- `mixes`: far-end-only stretches of one private meeting plus user-only
  stretches of another, prepared as WAV files listed in a JSON spec.

## Scores

Transcript first. `leakedPerMinute` counts output words that the far end
said within three seconds and the user did not. `lostPerMinute` counts the
user's words that the output no longer holds within three seconds.
`echoRemovedMedianDB` is measured on the audio over far-end windows, never
taken from a canceller's own report. `siSdrMeanDB` compares against the clean
near-end after removing the canceller's own block delay. `aecmosEcho` and
`aecmosOther` are the 1 to 5 scores of Microsoft's model on the real and
synthetic tiers.

## Running

```sh
python3 -m venv .venv && .venv/bin/pip install -r Benchmarks/aec/requirements.txt
.venv/bin/python Benchmarks/aec/fetch.py
./scripts/build.sh debug
export LOCALVQE_BIN=/path/to/localvqe   # built from github.com/localai-org/LocalVQE, ggml/ directory
.venv/bin/python Benchmarks/aec/harness.py --tier synthetic --work /tmp/bakeoff
.venv/bin/python Benchmarks/aec/harness.py --tier real --work /tmp/bakeoff
.venv/bin/python Benchmarks/aec/harness.py --tier meetings --meetings ~/Documents/Pipit/Meetings --work /tmp/bakeoff --seconds 300
```

`--candidates a,b` limits the run, `--limit N` the clips, and
`--offset-shift S` moves every reference by `S` seconds first, which is how a
recording that stalled mid-call looks to the canceller.

## The pass Pipit ships

`pipit-eval aec --mic FILE --reference FILE --out FILE` runs the shipped pass
on two files, exactly as `MicrophoneCleaner` runs it on a meeting, so the
`shipped` candidate is the code in the app. `PIPIT_ECHO_STAGE=filter` or
`network` runs one stage of it alone, which is how the Swift port of DTLN-aec
was checked against onnxruntime (they agree to 7e-7 on a two-minute clip) and
how a change to either stage is checked again.

The pass that shipped before 12 September 2026, WebRTC AEC3, is not in the
list any more: it came last on every private tier, keeping 52% of the user's
words through loud double talk where the cascade keeps 87%.
