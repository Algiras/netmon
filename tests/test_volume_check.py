"""Tests for volume_check.py — connection-count spike detection."""
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent.parent))
import volume_check


class TestVolumeCheck(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._log  = Path(self._tmp.name) / "anomalies.log"
        self._counts = Path(self._tmp.name) / "connection_counts.json"
        self._log.touch()

    def tearDown(self):
        self._tmp.cleanup()

    def _run(self, connections: dict, history: dict, now_ts: float = 1_000_000.0):
        import datetime as _real_dt

        class _FakeDT:
            @staticmethod
            def now():
                class _N:
                    def timestamp(self): return now_ts
                    def strftime(self, _): return "2026-05-05 17:00:00"
                return _N()

        with patch("volume_check._get_counts", return_value=connections), \
             patch("volume_check._load",       return_value=history), \
             patch("volume_check.ANOMALY_LOG", self._log), \
             patch("volume_check.COUNTS_FILE", self._counts), \
             patch("volume_check.datetime",    _FakeDT):
            volume_check.main()

        return self._log.read_text()

    def _history(self, key: str, samples: list, alerted_at=None) -> dict:
        return {key: {"samples": list(samples), "alerted_at": alerted_at}}

    # ── no-alert cases ────────────────────────────────────────────────────────

    def test_no_alert_below_min_samples(self):
        key = "codex|104.18.32.47:443"
        out = self._run({key: 20}, self._history(key, [1] * 5))
        self.assertNotIn("VOLUME_ANOMALY", out)

    def test_no_alert_below_spike_min_count(self):
        key = "codex|104.18.32.47:443"
        out = self._run({key: 4}, self._history(key, [1] * 15))
        self.assertNotIn("VOLUME_ANOMALY", out)

    def test_no_alert_within_factor(self):
        # mean ≈ 2, current = 7 → 3.5× — below SPIKE_FACTOR=4.0
        key = "codex|104.18.32.47:443"
        out = self._run({key: 7}, self._history(key, [2] * 15))
        self.assertNotIn("VOLUME_ANOMALY", out)

    def test_cooldown_suppresses_repeat_alert(self):
        key = "node|10.0.0.1:443"
        hist = self._history(key, [1] * 15, alerted_at=1_000_000.0 - 60)
        out = self._run({key: 10}, hist, now_ts=1_000_000.0)
        self.assertNotIn("VOLUME_ANOMALY", out)

    def test_no_alert_for_new_pair_with_low_count(self):
        out = self._run({"newproc|1.2.3.4:443": 1}, {})
        self.assertNotIn("VOLUME_ANOMALY", out)

    # ── alert cases ───────────────────────────────────────────────────────────

    def test_alert_on_spike(self):
        key = "codex|104.18.32.47:443"
        out = self._run({key: 10}, self._history(key, [1] * 15))
        self.assertIn("VOLUME_ANOMALY", out)
        self.assertIn("codex", out)
        self.assertIn("104.18.32.47:443", out)

    def test_alert_includes_count_and_avg(self):
        key = "node|10.0.0.1:443"
        out = self._run({key: 20}, self._history(key, [2] * 15))
        self.assertIn("20 connections", out)
        self.assertIn("baseline avg", out)

    def test_cooldown_expires_after_interval(self):
        key = "node|10.0.0.1:443"
        hist = self._history(key, [1] * 15, alerted_at=1_000_000.0 - 700)
        out = self._run({key: 10}, hist, now_ts=1_000_000.0)
        self.assertIn("VOLUME_ANOMALY", out)

    # ── state management ──────────────────────────────────────────────────────

    def test_history_window_capped(self):
        key = "node|10.0.0.1:443"
        hist = self._history(key, [1] * 30)
        self._run({key: 2}, hist)
        import json
        saved = json.loads(self._counts.read_text())
        self.assertLessEqual(len(saved[key]["samples"]), volume_check.WINDOW_SIZE)

    def test_alert_recorded_in_alerted_at(self):
        key = "codex|104.18.32.47:443"
        self._run({key: 10}, self._history(key, [1] * 15), now_ts=12345.0)
        import json
        saved = json.loads(self._counts.read_text())
        self.assertAlmostEqual(saved[key]["alerted_at"], 12345.0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
