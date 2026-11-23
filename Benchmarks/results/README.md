# Recorded benchmark results

Each folder here holds one benchmark run that informed a decision, named by the
date it finished and what it measured. A folder is written once and not edited
afterwards, so it stays a record of what that code measured on that day. A
later run that replaces its numbers goes in a new folder.

`baselines.json` one level up is different: it holds the numbers the regression
gate compares against, and it is overwritten when the baselines are rebuilt.

## What a folder holds

| File | Contents |
| --- | --- |
| `README.md` | The question, how the run was made, the results, and their limits |
| `provenance.json` | Commit, the diff of changed files and a SHA-256 of untracked ones, machine, Swift package and Python package versions, model revisions, and a SHA-256 for every input audio file |
| `*-scores.json`, `pipeline-*.json` | Scores as the tools wrote them, with local paths removed |
| `*-transcripts.json.gz` | The raw transcripts each engine produced |

The transcripts make a run re-scorable without rerunning any model. When the
scorer or its normaliser changes, re-score the stored transcripts against the
current ground truth and compare with the stored scores. The checksums say
whether the audio in the cache is still the audio that was measured: the call
generator and the synthetic voices both change over time.

To rerun a result instead, start from the same audio: generators change, so
the scripts in the commit that added a folder may no longer make the audio
that was measured, and the checksums say whether a cached file is the same.
`provenance.json` names the commit the app was built from and any files that
were not yet committed. Install the recorded package versions before comparing
numbers.

Write `provenance.json` for a new run with:

```sh
python3 Benchmarks/results/provenance.py --hf-model <model id> \
  --python <interpreter that ran the engines> --input <audio file> > provenance.json
```
