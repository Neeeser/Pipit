"""Tests for provenance.py that need no git history.

    python3 -m unittest Benchmarks/results/test_provenance.py
"""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import provenance


class Redact(unittest.TestCase):
    def test_the_home_directory_is_replaced_and_counted(self) -> None:
        text, count = provenance.redact_home("+path = /Users/someone/code/x\n+other /Users/someone/y", "/Users/someone")
        self.assertEqual(text, "+path = ~/code/x\n+other ~/y")
        self.assertEqual(count, 2)

    def test_text_without_it_is_unchanged(self) -> None:
        self.assertEqual(provenance.redact_home("nothing here", "/Users/someone"), ("nothing here", 0))


class CodeFiles(unittest.TestCase):
    def test_named_files_are_hashed_by_the_name_given(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "run.sh"
            path.write_text("echo hi\n")
            hashes = provenance.code_files([path])
            self.assertEqual(list(hashes), [str(path)])
            self.assertEqual(hashes[str(path)], provenance.sha256(path))


if __name__ == "__main__":
    unittest.main()
