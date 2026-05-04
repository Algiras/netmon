"""Tests for db.py — SQLite event store and vector similarity search."""
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent.parent))

import db


def _tmp_db():
    """Return a fresh in-memory db path for each test."""
    return tempfile.mktemp(suffix=".db")


class TestInsertAndRetrieve(unittest.TestCase):
    def setUp(self):
        self._path = _tmp_db()
        patch.object(db, "DB_PATH", Path(self._path)).start()
        db.init()

    def tearDown(self):
        patch.stopall()
        Path(self._path).unlink(missing_ok=True)

    def test_insert_and_get_pending(self):
        eid = db.insert_event("python3", "1.2.3.4:443", "warning", "test", None)
        pending = db.get_pending()
        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0]["id"], eid)
        self.assertEqual(pending[0]["status"], "pending")

    def test_update_status_confirmed(self):
        eid = db.insert_event("bash", "5.6.7.8:22", "warning", "ssh", None)
        db.update_status(eid, "confirmed")
        pending = db.get_pending()
        self.assertEqual(len(pending), 0)
        recent = db.get_recent()
        confirmed = [r for r in recent if r["id"] == eid]
        self.assertEqual(confirmed[0]["status"], "confirmed")

    def test_update_status_rejected(self):
        eid = db.insert_event("nc", "9.9.9.9:4444", "critical", "reverse shell", None)
        db.update_status(eid, "rejected")
        recent = db.get_recent()
        row = next(r for r in recent if r["id"] == eid)
        self.assertEqual(row["status"], "rejected")

    def test_get_recent_limit(self):
        for i in range(10):
            db.insert_event(f"proc{i}", f"1.2.3.{i}:443", "info", f"event {i}", None)
        recent = db.get_recent(limit=5)
        self.assertEqual(len(recent), 5)

    def test_multiple_pending(self):
        db.insert_event("a", "1.1.1.1:80", "info", "a", None)
        db.insert_event("b", "2.2.2.2:80", "info", "b", None)
        eid3 = db.insert_event("c", "3.3.3.3:80", "info", "c", None)
        db.update_status(eid3, "confirmed")
        self.assertEqual(len(db.get_pending()), 2)


class TestClearEmbeddings(unittest.TestCase):
    def setUp(self):
        self._path = _tmp_db()
        patch.object(db, "DB_PATH", Path(self._path)).start()
        db.init()

    def tearDown(self):
        patch.stopall()
        Path(self._path).unlink(missing_ok=True)

    def test_clear_removes_all_embeddings(self):
        vec = [0.1] * 8
        db.insert_event("bash", "1.2.3.4:22", "warning", "ssh", vec)
        db.insert_event("chrome", "5.6.7.8:443", "info", "cdn", vec)
        db.clear_embeddings()
        results = db.find_similar(vec, top_k=10, min_sim=0.0)
        self.assertEqual(len(results), 0)

    def test_events_remain_after_clear(self):
        db.insert_event("bash", "1.2.3.4:22", "warning", "ssh", [0.1] * 8)
        db.clear_embeddings()
        self.assertEqual(len(db.get_recent()), 1)


class TestFindSimilar(unittest.TestCase):
    def setUp(self):
        self._path = _tmp_db()
        patch.object(db, "DB_PATH", Path(self._path)).start()
        db.init()

    def tearDown(self):
        patch.stopall()
        Path(self._path).unlink(missing_ok=True)

    def _vec(self, val, dims=8):
        """Create a unit vector tilted toward val."""
        import math
        v = [val] * dims
        norm = math.sqrt(sum(x * x for x in v))
        return [x / norm for x in v]

    def test_find_similar_high_sim(self):
        v = self._vec(1.0)
        db.insert_event("python3", "1.2.3.4:443", "warning", "baseline", v)
        results = db.find_similar(v, top_k=5, min_sim=0.99)
        self.assertEqual(len(results), 1)
        self.assertAlmostEqual(results[0]["similarity"], 1.0, places=3)

    def test_find_similar_below_threshold(self):
        v1 = self._vec(1.0)
        v2 = self._vec(-1.0)  # opposite direction → cosine sim = -1
        db.insert_event("bash", "5.6.7.8:22", "warning", "ssh", v1)
        results = db.find_similar(v2, top_k=5, min_sim=0.5)
        self.assertEqual(len(results), 0)

    def test_find_similar_top_k(self):
        v = self._vec(1.0)
        for i in range(5):
            db.insert_event(f"proc{i}", f"1.2.3.{i}:443", "info", "x", v)
        results = db.find_similar(v, top_k=3, min_sim=0.99)
        self.assertEqual(len(results), 3)

    def test_no_embedding_skipped(self):
        db.insert_event("chrome", "1.1.1.1:443", "info", "cdn", None)
        results = db.find_similar(self._vec(1.0), top_k=5, min_sim=0.0)
        self.assertEqual(len(results), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
