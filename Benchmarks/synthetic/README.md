# Synthetic meetings

These scripts build benchmark meetings that no public corpus has: more than
eight speakers, a chosen amount of talking over each other, and the same
meeting rendered as a headphones call, a laptop-speaker call and an in-person
room recording. A Gemini text model writes the script and Gemini text to speech
voices it. Every person in a script is invented.

| Step | Script | Writes |
| --- | --- | --- |
| Write the meeting | `write_script.py` | `scripts/<meeting>.json` |
| Voice it | `synthesize.py` | One track per person and the ground truth, in `~/Library/Caches/pipit-bench/synthetic/<meeting>/` |
| Check the voices | `check_audio.py` | `<meeting>.audio-check.json` beside the voices |
| Make benchmark cases | `make_cases.py` | A benchmark root in `~/Library/Caches/pipit-bench/synthetic/bench/` |

The scripts read the API key from `GEMINI_API_KEY`. On the free tier the speech
model allows about ten requests a day, and `synthesize.py` uses one request per
person, so a ten-person meeting takes a day's quota. A rerun reuses the voice
files already in the cache and sends nothing for them. Google may use free-tier
requests to train its models, which is acceptable here because every script is
invented.

## Ground truth

The reference words are the script's words, not a transcription of the audio.
Text to speech sometimes skips, repeats or changes a word, and each such slip
counts against every engine. `check_audio.py` sends each person's lines to a
cheap Gemini model that takes audio (Flash-Lite by default) and compares its
transcript with the script. The model is not shown the script: when it was, it
copied the script back and passed lines that had been swapped. It is also not
told how many lines to expect, since it then left speech out to fit that
number. Its own hearing errors show up as flags too, so listen to a flagged
line, or transcribe it with `pipit-eval asr`, before changing a meeting.

Gemini does not leave a reliable pause between the lines of one request, so
`synthesize.py` finds the line boundaries by aligning Parakeet's transcript of
the voice file (`pipit-eval asr`, so build `pipit-eval` first) to the script,
and cuts in the longest silence near each boundary. If fewer than four lines in
five can be placed, or a line the recogniser did not hear has too little audio
for its words (the speech model probably skipped it), it stops; `--per-line` then voices that speaker one line per
request. A short line that repeats the last word of the line before can still
be cut in the wrong place when the recogniser drops it; `check_audio.py` is
the check for that. Word times inside a line are spread across its voiced span by
character count, so they are approximate.

`ground-truth/<meeting>.json` holds the committed copy of each meeting's truth.
`SYN001` came from an earlier version of `synthesize.py`, the one its recorded
results used; running the current version on the same voices moves line starts by
seconds (a median of about 6 s) and drops six stray "." words, so regenerate
its audio and truth together.
The audio is not committed; `Benchmarks/results` records its checksums for
each run that used it.

## Running the cases

The call cases read the manifest and truth from the benchmark root and the
audio from its `calls` folder. The in-person case is one truth file with its
room recording beside it.

```sh
BENCH=~/Library/Caches/pipit-bench/synthetic/bench
scripts/eval.sh bench --benchmarks "$BENCH" --audio-dir "$BENCH" \
  --suite calls --case SYN001-headphones --case SYN001-laptop --allow-missing-baseline
scripts/eval.sh bench --truth "$BENCH/ground-truth/SYN001.json" --allow-missing-baseline
```
