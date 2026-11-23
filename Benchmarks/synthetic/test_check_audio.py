"""Tests for the comparison in check_audio.py; no network.

    uv run --with numpy --with soundfile --with whisper-normalizer==0.1.12 \
        python -m unittest Benchmarks/synthetic/test_check_audio.py
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import check_audio

LINES = ["We tried three steps.", "Mm-hmm, yes.", "The launch is on Friday, alright?"]


def verdicts(lines: list[str], heard: str) -> list[str]:
    differing, heard_any = check_audio.differing_words(lines, heard)
    return [check_audio.verdict(count, len(check_audio.tokens(line)), any_heard)
            for line, count, any_heard in zip(lines, differing, heard_any, strict=True)]


class Compare(unittest.TestCase):
    def test_the_same_words_written_differently_match(self) -> None:
        heard = "We tried 3 steps. Yes. The launch is on Friday, all right?"
        self.assertEqual(verdicts(LINES, heard), ["match", "match", "match"])

    def test_spoken_amounts_match_digits(self) -> None:
        self.assertEqual(verdicts(["That is ninety eight thousand dollars."], "That is $98,000."), ["match"])

    def test_lines_in_the_wrong_order_are_flagged(self) -> None:
        heard = "The launch is on Friday, alright? We tried three steps."
        self.assertNotIn("match", verdicts(LINES, heard)[:1])

    def test_a_line_that_was_not_said_is_missing(self) -> None:
        heard = "We tried three steps. The launch is on Friday, alright?"
        self.assertEqual(verdicts(["We tried three steps.", "Honestly I think we should wait.",
                                   "The launch is on Friday, alright?"], heard), ["match", "missing", "match"])

    def test_a_line_said_with_other_words_is_a_mismatch_not_missing(self) -> None:
        self.assertEqual(verdicts(["We tried.", "No.", "Okay then."], "We tried. Maybe. Okay then."),
                         ["match", "mismatch", "match"])

    def test_a_line_of_only_a_hesitation_is_not_scored(self) -> None:
        self.assertEqual(verdicts(["Mm-hmm."], "Mhm."), ["unscored"])

    def test_words_heard_in_place_of_a_hesitation_line_stay_with_it(self) -> None:
        self.assertEqual(verdicts(["We tried three steps.", "Mm-hmm.", "Okay then."],
                                  "We tried three steps. No way. Okay then."), ["match", "unscored", "match"])

    def test_clock_times_match_the_spoken_hour(self) -> None:
        self.assertEqual(verdicts(["The report arrived at eleven."], "The report arrived at 11:00."), ["match"])


if __name__ == "__main__":
    unittest.main()
