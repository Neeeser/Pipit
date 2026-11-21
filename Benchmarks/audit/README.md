# Meeting audit

`audit.py` measures how well Pipit transcribed your own recorded meetings. No
human transcript of a real meeting exists, so it compares Pipit with reference
transcribers ("teachers") and the teachers with each other. Where two
independent teachers agree and Pipit differs, the error is most likely Pipit's.

The public-corpus benchmark (`pipit-eval bench`) is the regression gate. This
audit answers a different question: how Pipit does on the calls a person
actually records, with their microphone, echo, call apps and speakers.

## Privacy

The audit reads meetings through the `pipit` command and writes decoded audio,
teacher transcripts and results under `--work`, by default
`~/Library/Caches/pipit-bench/audit`. It refuses a `--work` folder inside a git
repository, so nothing goes into one by accident.

Meeting identifiers carry a title slug, and titles name companies and people.
`prepare` gives each meeting a short key (the first eight characters of the
identifier's SHA-256) and an index. File names, printed output, logs, results
and `report.md` use only `#index key`. The one place that links a key to the
identifier, and so to the title, is `meetings.json` in the work folder, along
with the meeting folder paths. Do not copy that file out of the work folder.
Printed output holds keys, counts and rates, never what was said, and a failure
prints the exception type only, with the traceback in `logs/` under the work
folder.

The VibeVoice and MOSS teachers run on this Mac. The Gemini teacher uploads
meeting audio to Google and runs only with `--allow-cloud`. `gemini.py` deletes
the upload when the call ends, whether it succeeded or failed, and exits with an
error naming the uploaded file if the delete itself fails. A process killed
mid-call cannot clean up; the file then expires on Google's side. On the free
tier Google may use what it receives to improve its products.

## Teachers

| Teacher | Runs | Speakers | Notes |
| --- | --- | --- | --- |
| `vibevoice` | MLX, through `uv` and `mlx-audio` | Yes | 5.7 GB 4-bit model downloaded on first use. Up to 60 minutes per pass. |
| `moss` | [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) on Metal | Yes | MOSS-Transcribe-Diarize, 1 GB Q8 GGUF. Needs `--moss-cli` and `--moss-model`. |
| `gemini` | Google API, `--allow-cloud` | Labels only | Word-level tiebreaker. Its speaker labels and timestamps are not reliable enough to score attribution. |

Each local teacher can run on three tracks of a meeting:

- `mixed`: the recording as you hear it.
- `mic`: the echo-cancelled microphone (`raw/audio/mic.cleaned.m4a`).
- `system`: the call audio (`raw/audio/system.m4a`), which holds everyone but you.

A teacher run on `mic` and `system` separately is a split reference. It keeps
overlapping speech, which a teacher working from one mixed file drops, and it
cannot confuse you with a remote speaker. The score step prefers split
references.

## Running

```sh
export PIPIT_AUDIT_DIR=~/Library/Caches/pipit-bench/audit   # optional
python3 Benchmarks/audit/audit.py prepare --since 2026-10-01 --limit 10
python3 Benchmarks/audit/audit.py teach --teacher vibevoice --tracks mic,system
python3 Benchmarks/audit/audit.py teach --teacher moss --tracks mixed,mic,system \
  --moss-cli /path/to/transcribe-cli --moss-model /path/to/MOSS-Transcribe-Diarize-Q8_0.gguf
uv run --python 3.12 --with meeteval==0.4.3 python Benchmarks/audit/audit.py score
python3 Benchmarks/audit/audit.py report
```

`prepare` skips meetings with more than one recording, since a rejoined call has
separate timelines, and meetings missing a track. `teach` skips outputs that
already exist, so a stopped run resumes. Every output (decoded audio, teacher
transcripts, diarizer files, results) is written under a temporary name and
renamed when the run succeeds, so a stopped run never leaves a partial file that
a later run would take for a finished one.

Each command ends with a line such as `score: 7 ok, 1 failed, 2 skipped` and
exits 1 when anything failed. A teacher's error output goes to `logs/` under the
work folder.

The guards have standard-library tests on synthetic data:
`python3 -m unittest discover -s Benchmarks/audit`.

## Versions

`audit.py` pins the Python packages it runs (`PINNED`: `mlx-audio`,
`google-genai`, `meeteval`) and the model identifiers, and `uv` is given the
exact version. `score` stops when the installed `meeteval` differs from the pin,
so run it as `uv run --python 3.12 --with meeteval==0.4.3 ...`. `teach` writes
the packages, the model names, the cached VibeVoice snapshot and the MOSS file's
SHA-256 to `provenance.json`, and `score` copies that and the `meeteval` version
into every result file. Change a pin on purpose and rerun the teachers, since
references from different versions are not comparable.

## Truncated references

A reference that stops early would score its missing tail as Pipit's mistakes.
Causes include VibeVoice's token cap, a Gemini finish reason other than a normal
stop (the Gemini step now fails instead of writing the file), and a meeting
longer than a model handles. `score` compares each reference with Pipit's
transcript of the same track and sets it aside, with the reason, when its last
word ends before 80% of where Pipit's does or it holds under half of Pipit's
words. A meeting whose references are all set aside is skipped. A teacher file
that cannot be read fails that meeting and the run continues with the others.

To compare speaker separators on the call track with Pipit's words held fixed,
build `fluidaudiocli` from the pinned FluidAudio checkout and run:

```sh
uv run --python 3.12 --with meeteval==0.4.3 python Benchmarks/audit/audit.py diarizers \
  --fluidaudio-cli /path/to/fluidaudiocli
```

That run labels every call-track word with each diarizer's speaker and leaves
your mic words as you. It shows what a call without meeting-app speaker data,
such as Zoom or an unknown app, would get from each diarizer.

## Results

`report` writes `report.md` under the work folder with one row per meeting:

| Column | Meaning |
| --- | --- |
| Pipit word error (est., one stream) | Pipit's own word error, estimated from the three disagreements between Pipit and two teachers from different models, with everyone's words in one time-ordered stream |
| Pipit cpWER (est.) | The same estimate from the speaker-attributed error, so it does not pay the crosstalk ordering cost |
| Words+speaker vs best reference | cpWER of Pipit against the preferred reference: words and who said them |
| Speakers Pipit / reference | Speaker labels each one used |
| Echo leak | Share of the words Pipit gave you that a teacher also heard on the call track at the same moment |

The estimate assumes the three sources make independent mistakes, so that each
pairwise disagreement is about the sum of the two error rates. It is a guide,
not a measurement. When the three disagreements cannot fit that model (one is
larger than the other two added together, so a source's estimate would be
negative), the report prints the negative number with "assumption violated" and
leaves that meeting out of the median; it is not rounded up to zero. Two teachers that share a model, such as VibeVoice on the
mixed file and VibeVoice on split tracks, are never paired for it.

Plain word error is computed over one time-ordered stream, so two people
talking at once can count as errors even when every word is right. Speaker
attributed error (cpWER) does not have that ordering cost, which is why it can
come out lower than plain word error on calls with crosstalk.

Text is normalised before scoring: lowercase, punctuation and hesitation sounds
removed, numbers below 1000 spelled out, and spelled acronyms joined, so "G C P"
and "GCP" match.
