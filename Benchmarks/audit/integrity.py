"""Guards that keep a broken reference from being scored as a whole one.

Standard library only, so the tests run without the audit's heavy dependencies.
"""

import hashlib
import os
import shutil
from contextlib import contextmanager
from pathlib import Path

# A reference whose last word ends before this share of Pipit's last word, or that has
# fewer than this share of Pipit's words, stopped early (token cap, finish reason, a
# long meeting) and would count the missing tail as Pipit's mistakes.
TAIL_SHORTFALL = 0.8
WORD_SHORTFALL = 0.5
# Too short a transcript says nothing about completeness.
MIN_WORDS_TO_JUDGE = 50


# Writing without leaving half a file behind ---------------------------------------

@contextmanager
def staged(final: Path):
    """Yield a path to write instead of `final`; move it into place only when the
    block ends without an error and the file exists and has content.

    A killed or failed run leaves nothing under the final name, so a later run
    cannot take a partial file for a finished one. The staging folder sits beside
    `final` so the rename stays on one volume and is atomic.
    """
    final = Path(final)
    folder = final.parent / f".{final.name}.partial"
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / final.name
    try:
        yield target
        if not target.exists() or target.stat().st_size == 0:
            raise FileNotFoundError("the run wrote no output")
        os.replace(target, final)
    finally:
        shutil.rmtree(folder, ignore_errors=True)


def write_atomic(path: Path, text: str) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with staged(path) as target:
        target.write_text(text)


# Meeting identifiers ------------------------------------------------------------------

def meeting_key(meeting_id: str) -> str:
    """A short, stable name for a meeting. Identifiers carry a title slug, so nothing
    but the work folder's meetings file may hold the identifier itself.
    """
    return hashlib.sha256(meeting_id.encode()).hexdigest()[:8]


def label(meeting: dict) -> str:
    """What gets printed and written to results: the index and the short key."""
    return f"#{meeting['index']} {meeting['key']}"


def with_keys(chosen: list[dict]) -> list[dict]:
    """Add the short key and a 1-based index, keeping any index already assigned."""
    out = []
    for position, m in enumerate(chosen, start=1):
        out.append({**m, "key": m.get("key") or meeting_key(m["id"]), "index": m.get("index") or position})
    return out


# Truncated references ---------------------------------------------------------------

def words_in(segments: list[dict]) -> int:
    return sum(len(s["text"].split()) for s in segments)


def truncation(reference: list[dict], pipit: list[dict]) -> str | None:
    """Why `reference` looks cut short compared with Pipit's transcript of the same
    audio, or None. Both are lists of {"start", "end", "text"}.
    """
    pipit_words = words_in(pipit)
    if pipit_words < MIN_WORDS_TO_JUDGE:
        return None
    if not reference:
        return "no words"
    pipit_end = max(s["end"] for s in pipit)
    ref_end = max(s["end"] for s in reference)
    if ref_end < TAIL_SHORTFALL * pipit_end:
        return f"ends at {ref_end:.0f}s, Pipit at {pipit_end:.0f}s"
    ref_words = words_in(reference)
    if ref_words < WORD_SHORTFALL * pipit_words:
        return f"{ref_words} words, Pipit {pipit_words}"
    return None


# Work folder -----------------------------------------------------------------------

def enclosing_repository(path: Path) -> Path | None:
    """The git working tree that contains `path`, or None. A `.git` entry can be a
    folder or, in a linked worktree, a file.
    """
    here = Path(path).expanduser().resolve()
    for candidate in [here, *here.parents]:
        if (candidate / ".git").exists():
            return candidate
    return None


# Results ------------------------------------------------------------------------------

class Tally:
    """Counts what happened to each unit of work, so a run can end with a summary
    and a non-zero exit when anything failed.
    """

    def __init__(self) -> None:
        self.ok = self.failed = self.skipped = 0

    def summary(self, what: str) -> str:
        return f"{what}: {self.ok} ok, {self.failed} failed, {self.skipped} skipped"

    @property
    def exit_code(self) -> int:
        return 1 if self.failed else 0
