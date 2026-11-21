"""Tests for the audit's guards and text normalisation, with synthetic data only.

Run from the repository root:
uv run --python 3.12 --with whisper-normalizer==0.1.12 python -m unittest discover -s Benchmarks/audit
The normaliser package is the only third-party one; meeteval is imported only by
the scoring step.
"""

import contextlib
import io
import json
import os
import stat
import sys
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import audit  # noqa: E402
import integrity  # noqa: E402
import sources  # noqa: E402

WORDS = "alpha bravo charlie delta echo foxtrot golf hotel india juliet".split()


def segments(count: int, end_at: float, track: str | None = None) -> list[dict]:
    """`count` ten-word segments spread evenly over `end_at` seconds."""
    step = end_at / count
    return [{"speaker": "s", "start": i * step, "end": (i + 1) * step, "text": " ".join(WORDS), "track": track}
            for i in range(count)]


class StagedTests(unittest.TestCase):
    def test_a_failed_run_leaves_no_file_under_the_final_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            final = Path(tmp) / "out.json"
            with self.assertRaises(RuntimeError), integrity.staged(final) as target:
                target.write_text("half a transcr")
                raise RuntimeError("killed")
            self.assertFalse(final.exists())
            self.assertEqual(os.listdir(tmp), [])

    def test_a_finished_run_appears_whole(self):
        with tempfile.TemporaryDirectory() as tmp:
            final = Path(tmp) / "out.json"
            with integrity.staged(final) as target:
                target.write_text("{}")
            self.assertEqual(final.read_text(), "{}")
            self.assertEqual(os.listdir(tmp), ["out.json"])

    def test_an_empty_output_is_a_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            final = Path(tmp) / "out.json"
            with self.assertRaises(FileNotFoundError), integrity.staged(final) as target:
                target.write_text("")
            self.assertFalse(final.exists())

    def test_a_partial_folder_from_a_killed_run_is_cleared(self):
        with tempfile.TemporaryDirectory() as tmp:
            final = Path(tmp) / "out.json"
            stale = Path(tmp) / ".out.json.partial"
            stale.mkdir()
            (stale / "out.json").write_text("left over")
            with integrity.staged(final) as target:
                self.assertFalse(target.exists())
                target.write_text("fresh")
            self.assertEqual(final.read_text(), "fresh")


class TruncationTests(unittest.TestCase):
    def test_a_whole_reference_passes(self):
        self.assertIsNone(integrity.truncation(segments(20, 600), segments(20, 600)))

    def test_a_reference_that_stops_early_is_flagged(self):
        self.assertIn("ends at", integrity.truncation(segments(10, 300), segments(20, 600)))

    def test_a_reference_with_far_fewer_words_is_flagged(self):
        sparse = [dict(s, text="alpha bravo") for s in segments(20, 600)]
        self.assertIn("words", integrity.truncation(sparse, segments(20, 600)))

    def test_an_empty_reference_is_flagged_when_pipit_heard_speech(self):
        self.assertEqual(integrity.truncation([], segments(20, 600)), "no words")

    def test_a_nearly_silent_track_is_not_judged(self):
        self.assertIsNone(integrity.truncation([], segments(2, 20)))


class IdentifierTests(unittest.TestCase):
    def test_the_key_is_short_stable_and_hides_the_title(self):
        meeting_id = "2026-10-12-0900-quarterly-planning-with-example-company"
        key = integrity.meeting_key(meeting_id)
        self.assertEqual(key, integrity.meeting_key(meeting_id))
        self.assertRegex(key, r"^[0-9a-f]{8}$")
        keyed = integrity.with_keys([{"id": meeting_id}, {"id": "other"}])
        self.assertEqual([m["index"] for m in keyed], [1, 2])
        self.assertNotIn("planning", integrity.label(keyed[0]))
        self.assertNotIn("example", integrity.label(keyed[0]))


class WorkFolderTests(unittest.TestCase):
    def test_a_folder_inside_a_repository_is_found(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / ".git").mkdir()
            inside = Path(tmp) / "a" / "b"
            self.assertEqual(integrity.enclosing_repository(inside), Path(tmp).resolve())

    def test_a_linked_worktree_marker_file_counts(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / ".git").write_text("gitdir: elsewhere")
            self.assertIsNotNone(integrity.enclosing_repository(Path(tmp) / "work"))

    def test_a_plain_folder_is_allowed(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsNone(integrity.enclosing_repository(Path(tmp) / "work"))


# Two transcribers writing the same speech in different house styles. Each pair
# must normalise to the same words, so none of these counts as an error.
SAME_SPEECH = {
    "numbers": [
        ("we need twenty five chairs", "we need 25 chairs"),
        ("about three hundred and forty people", "about 340 people"),
        ("two thousand five hundred units", "2,500 units"),
        ("one point five million rows", "1.5 million rows"),
        ("ninety-nine tickets", "99 tickets"),
    ],
    "ordinals": [
        ("the twenty first item", "the 21st item"),
        ("on the third floor", "on the 3rd floor"),
        ("on March fifth", "on March 5th"),
    ],
    "years": [
        ("back in twenty nineteen", "back in 2019"),
        ("since nineteen ninety eight", "since 1998"),
        ("by twenty twenty six", "by 2026"),
    ],
    "money": [
        ("it costs forty dollars", "it costs $40"),
        ("a budget of two million dollars", "a budget of $2 million"),
        ("five dollars and fifty cents", "$5.50"),
    ],
    "percentages": [
        ("growth of twelve percent", "growth of 12%"),
        ("about 30 percent", "about 30%"),
    ],
    "clock times": [
        ("meet at three thirty", "meet at 3:30"),
        ("call at three p.m.", "call at 3 PM"),
    ],
    "acronyms": [
        ("the A.P.I. is down", "the API is down"),
        ("ask the U.S. team", "ask the US team"),
        ("send it by E.O.D", "send it by EOD"),
        ("that sounds O.K.", "that sounds okay"),
    ],
    "spelled-out letters": [
        ("call the A P I", "call the API"),
        ("the g c p bill", "the GCP bill"),
        ("my initials are J K", "my initials are J.K."),
    ],
    "fillers and contractions": [
        ("um so we're uh done", "so we are done"),
        ("we'll pick a colour", "we will pick a color"),
        ("it’s fine", "it's fine"),
    ],
}

# Real disagreements about what was said, with how many words differ. Number and
# acronym handling must not hide these.
DIFFERENT_SPEECH = [
    ("we need twenty five chairs", "we need 35 chairs", 1),
    ("back in twenty nineteen", "back in 2018", 1),
    ("it costs forty dollars", "it costs $14", 1),
    ("growth of twelve percent", "growth of 20%", 1),
    ("the A.P.I. is down", "the APP is down", 1),
    ("I think a plan works", "I think the plan works", 1),
]


def word_errors(reference: list[str], hypothesis: list[str]) -> int:
    previous = list(range(len(hypothesis) + 1))
    for row, ref in enumerate(reference, 1):
        current = [row]
        for column, hyp in enumerate(hypothesis, 1):
            current.append(min(previous[column] + 1, current[column - 1] + 1,
                               previous[column - 1] + (ref != hyp)))
        previous = current
    return previous[-1]


class NormaliseTests(unittest.TestCase):
    def test_the_same_speech_in_another_style_scores_no_errors(self):
        for kind, pairs in SAME_SPEECH.items():
            for first, second in pairs:
                with self.subTest(kind=kind, first=first, second=second):
                    self.assertEqual(sources.normalise(first), sources.normalise(second))

    def test_a_real_difference_still_counts(self):
        for first, second, errors in DIFFERENT_SPEECH:
            with self.subTest(first=first, second=second):
                self.assertEqual(word_errors(sources.normalise(first), sources.normalise(second)), errors)

    def test_the_pronoun_and_the_article_stay_words(self):
        self.assertEqual(sources.normalise("so I think a plan and the A B C help"),
                         ["so", "i", "think", "a", "plan", "and", "the", "abc", "help"])

    def test_non_speech_tags_and_punctuation_go(self):
        self.assertEqual(sources.normalise("Right. [Noise] (laughs) Next, please!"), ["right", "next", "please"])


class ScoringPackageTests(unittest.TestCase):
    def check(self, versions: dict[str, str]) -> str | None:
        def version(package):
            if package not in versions:
                raise audit.metadata.PackageNotFoundError(package)
            return versions[package]
        original = audit.metadata.version
        audit.metadata.version = version
        try:
            audit.check_scoring_packages()
        except SystemExit as stopped:
            return str(stopped.code)
        finally:
            audit.metadata.version = original
        return None

    def test_the_pinned_versions_pass(self):
        self.assertIsNone(self.check({p: audit.PINNED[p] for p in audit.SCORING}))

    def test_another_normaliser_version_stops_the_score(self):
        message = self.check({"meeteval": audit.PINNED["meeteval"], "whisper-normalizer": "9.9"})
        self.assertIn("whisper-normalizer 9.9 is installed", message)
        self.assertIn(f"--with whisper-normalizer=={audit.PINNED['whisper-normalizer']}", message)

    def test_a_missing_package_says_how_to_run(self):
        self.assertIn("is not installed", self.check({"meeteval": audit.PINNED["meeteval"]}))


class TriangleTests(unittest.TestCase):
    def pairs(self, pipit_a, pipit_b, a_b):
        return {"pipit vs b": {"wer": pipit_b}, "pipit vs a": {"wer": pipit_a}, "b vs a": {"wer": a_b}}

    def test_a_consistent_triangle_is_split_between_the_sources(self):
        est = audit.triangle(self.pairs(0.10, 0.12, 0.10), "a", "b")
        self.assertAlmostEqual(est["pipit"], 0.06)
        self.assertEqual(est["violates"], [])

    def test_a_violated_triangle_keeps_its_negative_value(self):
        est = audit.triangle(self.pairs(0.05, 0.05, 0.40), "a", "b")
        self.assertLess(est["pipit"], 0)
        self.assertEqual(est["violates"], ["pipit"])
        self.assertIn("violated", audit.fmt_estimate(est))


def vibevoice_file(path: Path, count: int, end_at: float) -> None:
    step = end_at / count
    items = [{"Speaker": 0, "Start": i * step, "End": (i + 1) * step, "Content": " ".join(WORDS)}
             for i in range(count)]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"text": json.dumps(items)}))


class ReferenceTests(unittest.TestCase):
    def test_a_truncated_reference_is_set_aside_and_a_whole_one_is_kept(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            pipit = segments(20, 600, "mic") + segments(20, 600, "system")
            for track in ("mic", "system"):
                vibevoice_file(work / "teachers" / f"vibevoice-{track}" / "k.json", 20, 600)
            found, rejected = audit.references(work, "k", pipit)
            self.assertIn("split-vibevoice", found)
            self.assertEqual(rejected, {})
            vibevoice_file(work / "teachers" / "vibevoice-system" / "k.json", 8, 240)
            found, rejected = audit.references(work, "k", pipit)
            self.assertNotIn("split-vibevoice", found)
            self.assertIn("looks truncated", rejected["split-vibevoice"])

    def test_an_unreadable_reference_names_itself_and_not_its_contents(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            for track in ("mic", "system"):
                path = work / "teachers" / f"vibevoice-{track}" / "k.json"
                path.parent.mkdir(parents=True)
                path.write_text("{not json")
            with self.assertRaises(audit.UnusableReference) as raised:
                audit.references(work, "k", segments(20, 600, "mic"))
            self.assertIn("split-vibevoice", str(raised.exception))


FAKE_MOSS = """#!{python}
import sys
if "BROKEN" in open(sys.argv[2]).read():
    print("garbage"); sys.exit(0)
print("[   0.00 ->   5.00] S1: hello there")
"""


class TeachTests(unittest.TestCase):
    def run_teach(self, tmp: Path, model_text: str) -> tuple[int, Path]:
        work = tmp / "work"
        work.mkdir()
        meeting = {"id": "2026-10-12-0900-secret-title", "directory": str(tmp), "source": "zoom", "minutes": 30}
        (work / "meetings.json").write_text(json.dumps([meeting]))
        cli = tmp / "fake-cli"
        cli.write_text(FAKE_MOSS.format(python=sys.executable))
        cli.chmod(cli.stat().st_mode | stat.S_IXUSR)
        model = tmp / "model.gguf"
        model.write_text(model_text)
        args = Namespace(work=work, teacher="moss", tracks="mixed", allow_cloud=False, moss_cli=str(cli),
                         moss_model=str(model), vibevoice_model="", gemini_model="")
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as raised:
                audit.teach(args)
        self.printed = out.getvalue()
        return raised.exception.code, work

    def test_a_good_run_is_kept_and_summarised(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, work = self.run_teach(Path(tmp), "fine")
            key = integrity.meeting_key("2026-10-12-0900-secret-title")
            self.assertEqual(code, 0)
            self.assertTrue((work / "teachers" / "moss-mixed" / f"{key}.txt").exists())
            self.assertIn("1 ok, 0 failed", self.printed)
            self.assertNotIn("secret", self.printed)
            self.assertEqual(json.loads((work / "provenance.json").read_text())["moss"]["model"], "model.gguf")

    def test_an_interrupted_or_broken_run_leaves_nothing_and_fails_the_exit_code(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, work = self.run_teach(Path(tmp), "BROKEN")
            self.assertEqual(code, 1)
            self.assertEqual(list((work / "teachers" / "moss-mixed").iterdir()), [])
            self.assertIn("0 ok, 1 failed", self.printed)
            self.assertNotIn("secret", self.printed)


if __name__ == "__main__":
    unittest.main()
