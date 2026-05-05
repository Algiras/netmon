"""Tests for baseline.py — atomic read-modify-write helpers."""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))
import baseline


class TestAddEntry(unittest.TestCase):
    def test_creates_file_and_adds_entry(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "baseline.txt"
            result = baseline.add_entry(path, "chrome|1.1.1.1:443")
            self.assertEqual(result, "added to baseline")
            self.assertIn("chrome|1.1.1.1:443", path.read_text())

    def test_sorted_output(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "baseline.txt"
            baseline.add_entry(path, "zsh|9.9.9.9:443")
            baseline.add_entry(path, "chrome|1.1.1.1:443")
            lines = [l for l in path.read_text().splitlines() if l]
            self.assertEqual(lines, sorted(lines))

    def test_no_duplicate(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "baseline.txt"
            baseline.add_entry(path, "chrome|1.1.1.1:443")
            result = baseline.add_entry(path, "chrome|1.1.1.1:443")
            self.assertEqual(result, "already in baseline")
            self.assertEqual(path.read_text().count("chrome|1.1.1.1:443"), 1)

    def test_preserves_existing_entries(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "baseline.txt"
            path.write_text("existing|1.2.3.4:443\n")
            baseline.add_entry(path, "new|5.6.7.8:80")
            content = path.read_text()
            self.assertIn("existing|1.2.3.4:443", content)
            self.assertIn("new|5.6.7.8:80", content)


class TestRemoveEntry(unittest.TestCase):
    def test_removes_existing_entry(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "baseline.txt"
            path.write_text("chrome|1.1.1.1:443\nbash|2.2.2.2:22\n")
            removed = baseline.remove_entry(path, "chrome|1.1.1.1:443")
            self.assertTrue(removed)
            self.assertNotIn("chrome|1.1.1.1:443", path.read_text())
            self.assertIn("bash|2.2.2.2:22", path.read_text())

    def test_returns_false_when_not_present(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "baseline.txt"
            path.write_text("other|1.2.3.4:443\n")
            removed = baseline.remove_entry(path, "missing|9.9.9.9:443")
            self.assertFalse(removed)

    def test_returns_false_when_file_missing(self):
        removed = baseline.remove_entry(Path("/nonexistent/baseline.txt"), "x|y")
        self.assertFalse(removed)

    def test_empty_file_after_last_entry_removed(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "baseline.txt"
            path.write_text("only|1.2.3.4:443\n")
            baseline.remove_entry(path, "only|1.2.3.4:443")
            self.assertEqual(path.read_text(), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
