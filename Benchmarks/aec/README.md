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
  A meeting that ends before `--start` is skipped.
- `mixes`: far-end-only stretches of one private meeting plus user-only
  stretches of another, prepared as WAV files listed in a JSON spec.

## Scores

Transcript first. `leakedPerMinute` counts output words that the far end
said within three seconds and the user did not. `lostPerMinute` counts the
user's words that the output no longer holds within three seconds, and
`keptShare` is the rest of them as a share. `echoRemovedMedianDB` is measured
on the audio over far-end windows, never taken from a canceller's own report.
`siSdrMeanDB` compares against the clean near-end after removing the
canceller's own block delay. `aecmosEcho` and `aecmosOther` are the 1 to 5
scores of Microsoft's model on the real and synthetic tiers.

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

The pass that shipped before 12 September 2026, WebRTC AEC3, is not a
candidate in `candidates.py` any more, because its source left the repository
with it. Its row in the results below was measured once, from a scratch build
of commit `aa42831` behind the current alignment and 10 ms lead.

## Results

Run on 10 October 2026 with the shipped pass as of commit `4be35d0`. Every
figure is a rate over all the clips of a tier. Older figures for this
bake-off, including the 52% and 87% that these docs used to quote, were
scored on word times that `pipit-eval asr --json` reported late by the
segment's start. Backends already report word times from the start of the
file, so a word later in a clip sat further from where the three-second match
looked for it. On five-minute meeting excerpts the shipped pass scored 56.5%
of the user's words kept where the corrected scoring gives 94.5%. Those
figures are retired.

How this run differs from the setup above:

- The LocalVQE candidates ran through the vendored library in
  `Sources/CLocalVQE`, built as a dynamic library behind a stand-in for the
  upstream command-line binary, with one batch call per file.
- `shipped, filter stage alone` and `shipped, network stage alone` are the
  shipped pass with `PIPIT_ECHO_STAGE` set.
- The WebRTC row is the pre-September canceller as described above.
- `kept` needs the user's words as ground truth, so on the real tier it comes
  from the near-end single-talk recordings only.

### Synthetic: 200 clips, 33.3 minutes

| candidate | leaked/min | lost/min | kept | echo removed (dB) | SI-SDR (dB) | AECMOS echo | AECMOS other |
|---|---|---|---|---|---|---|---|
| `shipped` | 0.18 | 13.38 | 76.6% | 34.0 | 14.2 | 4.43 | 3.32 |
| `localvqe_v1_4-aec-2_7K+dtln512` | 0.12 | 12.57 | 78.0% | 34.7 | 14.7 | 4.44 | 3.27 |
| `localvqe_v1_4-aec-200K+dtln512` | 0.09 | 15.33 | 73.1% | 46.1 | 13.1 | 4.46 | 3.13 |
| `localvqe_v1_4-aec-200K+dtln256` | 0.03 | 14.88 | 73.9% | 42.9 | 12.6 | 4.36 | 2.99 |
| `dtln128` | 0.66 | 15.78 | 72.4% | 31.5 | 11.7 | 4.19 | 3.08 |
| `dtln256` | 0.18 | 13.41 | 76.5% | 34.6 | 12.6 | 4.27 | 3.19 |
| `dtln512` | 0.18 | 13.95 | 75.6% | 36.4 | 13.5 | 4.42 | 3.33 |
| `localvqe_v1_4-aec-200K` | 1.35 | 15.81 | 72.3% | 27.7 | 9.2 | 3.90 | 2.86 |
| `localvqe_v1_4-aec-2_7K` | 11.61 | 20.76 | 63.6% | 7.1 | 5.5 | 3.57 | 3.04 |
| `localvqe_v1_2-1_3M` | 0.21 | 17.70 | 69.0% | 56.5 | 8.8 | 4.15 | 2.85 |
| `localvqe_v1_3-4_8M` | 0.36 | 18.15 | 68.2% | 54.1 | 9.9 | 4.30 | 3.07 |
| `shipped, filter stage alone` | 11.55 | 24.18 | 57.6% | 5.0 | 3.5 | 3.49 | 3.05 |
| `shipped, network stage alone` | 0.12 | 14.46 | 74.7% | 34.7 | 13.4 | 4.38 | 3.34 |
| `WebRTC AEC3 (previous pass)` | 0.30 | 22.59 | 60.4% | 26.8 | -1.0 | 4.30 | 1.95 |

### Real: 216 recordings, 41.4 minutes

| candidate | leaked/min | lost/min | kept | echo removed (dB) | AECMOS echo | AECMOS other |
|---|---|---|---|---|---|---|
| `shipped` | 0.56 | 3.05 | 92.8% | 9.9 | 4.54 | 4.26 |
| `localvqe_v1_4-aec-2_7K+dtln512` | 0.68 | 2.64 | 93.8% | 9.7 | 4.55 | 4.25 |
| `localvqe_v1_4-aec-200K+dtln512` | 0.80 | 1.93 | 95.4% | 11.1 | 4.62 | 4.25 |
| `localvqe_v1_4-aec-200K+dtln256` | 0.65 | 1.98 | 95.3% | 11.4 | 4.60 | 4.25 |
| `dtln128` | 1.21 | 1.57 | 96.3% | 10.7 | 4.50 | 4.23 |
| `dtln256` | 1.11 | 2.10 | 95.0% | 9.1 | 4.54 | 4.27 |
| `dtln512` | 0.94 | 2.64 | 93.8% | 10.9 | 4.60 | 4.30 |
| `localvqe_v1_4-aec-200K` | 4.06 | 0.82 | 98.1% | 7.7 | 4.34 | 4.14 |
| `localvqe_v1_4-aec-2_7K` | 31.19 | 0.34 | 99.2% | 3.4 | 4.21 | 4.15 |
| `localvqe_v1_2-1_3M` | 1.69 | 1.77 | 95.8% | 13.6 | 4.57 | 4.21 |
| `localvqe_v1_3-4_8M` | 13.71 | 1.35 | 96.8% | 15.5 | 4.58 | 4.32 |
| `shipped, filter stage alone` | 31.44 | 0.00 | 100.0% | 1.8 | 4.03 | 4.13 |
| `shipped, network stage alone` | 1.04 | 2.68 | 93.7% | 10.5 | 4.59 | 4.31 |
| `WebRTC AEC3 (previous pass)` | 0.85 | 0.70 | 98.3% | 12.0 | 4.48 | 3.91 |

### Meetings: 15 meetings, 75.0 minutes

The first 15 cleaned meetings in path order, five minutes of each starting at
300 s. Aggregate figures only. The echo-removed median is left out because
most of these meetings hold little echo for it to measure.

| candidate | leaked/min | lost/min | kept |
|---|---|---|---|
| `shipped` | 0.27 | 2.15 | 94.5% |
| `localvqe_v1_4-aec-2_7K+dtln512` | 0.25 | 2.23 | 94.3% |
| `localvqe_v1_4-aec-200K+dtln512` | 0.24 | 2.23 | 94.3% |
| `localvqe_v1_4-aec-200K+dtln256` | 0.25 | 2.12 | 94.6% |
| `dtln128` | 0.59 | 2.20 | 94.4% |
| `dtln256` | 0.33 | 1.99 | 94.9% |
| `dtln512` | 0.29 | 2.20 | 94.4% |
| `localvqe_v1_4-aec-200K` | 1.21 | 1.92 | 95.1% |
| `localvqe_v1_4-aec-2_7K` | 14.02 | 0.99 | 97.5% |
| `localvqe_v1_2-1_3M` | 0.41 | 2.45 | 93.8% |
| `localvqe_v1_3-4_8M` | 9.79 | 2.32 | 94.1% |
| `WebRTC AEC3 (previous pass)` | 0.23 | 1.79 | 95.4% |

On all 65 cleaned meetings that run past 300 s (324.5 minutes), `shipped`
leaked 0.54 words per minute, lost 5.88 and kept 87.6%, and WebRTC AEC3
leaked 0.34, lost 5.90 and kept 87.5%.

### Reading the tiers

- Synthetic clips carry a nonlinear far end, as a loud laptop speaker
  produces. The shipped pass keeps 76.6% of the near-end words with an SI-SDR
  of 14.2 dB. WebRTC AEC3 keeps 60.4% with an SI-SDR of -1.0 dB and an AECMOS
  other score of 1.95.
- On the real-device recordings WebRTC AEC3 loses fewer of the user's words
  (kept 98.3% against 92.8%) and leaks slightly more far-end words (0.85 per
  minute against 0.56). The LocalVQE filter alone leaks 31 words per minute
  there, which is why it is followed by the network.
- On the meetings the shipped pass and WebRTC AEC3 cannot be told apart.
- The `mixes` tier is not part of this run. Its inputs came from private
  meetings and are not kept, so the loud-double-talk figures from the earlier
  run cannot be reproduced.
