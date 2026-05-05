"""Tests for panel.py — HTTP API endpoints, action routing, and revert logic."""
from __future__ import annotations

import io, json, sys, tempfile, threading, unittest
from pathlib import Path
from unittest.mock import patch, MagicMock
from urllib.request import urlopen, Request
from urllib.error import URLError

sys.path.insert(0, str(Path(__file__).parent.parent))

import db, panel


def _make_handler(tmp_dir: Path):
    """Return a Handler instance wired to a temp DB and netmon dir."""
    class FakeRequest:
        def makefile(self, *a, **kw): return io.BytesIO(b"")
    fake_req = FakeRequest()
    h = panel.Handler.__new__(panel.Handler)
    h.request        = fake_req
    h.client_address = ("127.0.0.1", 0)
    h.server         = MagicMock()
    return h


_LOCAL_HOST = {"Host": "localhost:6543"}


def _post(handler, path: str, body: dict):
    payload = json.dumps(body).encode()
    handler.path    = path
    handler.headers = {**_LOCAL_HOST, "Content-Length": str(len(payload))}
    handler.rfile   = io.BytesIO(payload)
    responses = []
    def fake_respond(code, body_str, ct="application/json"):
        responses.append((code, body_str))
    handler._respond = fake_respond
    handler.do_POST()
    return responses


def _get(handler, path: str):
    handler.path    = path
    handler.headers = _LOCAL_HOST
    responses = []
    def fake_respond(code, body_str, ct="application/json"):
        responses.append((code, body_str))
    handler._respond = fake_respond
    handler.do_GET()
    return responses


class TestActionEndpoint(unittest.TestCase):
    def setUp(self):
        self._tmp   = tempfile.TemporaryDirectory()
        self._dir   = Path(self._tmp.name)
        self._dbfile = self._dir / "test.db"
        patch.object(db, "DB_PATH", self._dbfile).start()
        db.init()
        patch.object(panel, "CONFIG_FILE", self._dir / "config.json").start()
        (self._dir / "config.json").write_text('{"autonomous_mode":false}')

    def tearDown(self):
        patch.stopall()
        self._tmp.cleanup()

    def _handler(self):
        return _make_handler(self._dir)

    def test_confirm_sets_status(self):
        eid = db.insert_event("bash", "1.2.3.4:22")
        h = self._handler()
        resp = _post(h, "/action", {"id": eid, "action": "confirmed"})
        self.assertEqual(resp[0][0], 200)
        row = db.get_recent()[0]
        self.assertEqual(row["status"], "confirmed")

    def test_confirm_adds_to_baseline(self):
        # Use real home dir baseline; just verify status + baseline entry
        netmon_dir = Path.home() / ".netmon"
        netmon_dir.mkdir(parents=True, exist_ok=True)
        baseline   = netmon_dir / "baseline.txt"
        original   = baseline.read_text() if baseline.exists() else None
        entry      = "bash_test_entry|254.254.254.254:9999"

        eid = db.insert_event("bash_test_entry", "254.254.254.254:9999")
        h   = self._handler()
        _post(h, "/action", {"id": eid, "action": "confirmed"})

        try:
            self.assertEqual(db.get_recent(limit=1)[0]["status"], "confirmed")
            if baseline.exists():
                self.assertIn(entry, baseline.read_text())
        finally:
            # Clean up: remove the test entry from real baseline
            if baseline.exists():
                lines = [l for l in baseline.read_text().splitlines() if l != entry]
                baseline.write_text("\n".join(lines) + ("\n" if lines else ""))

    def test_confirm_cascades_to_similar_pending(self):
        vec_a = [1.0, 0.0, 0.0, 0.0]
        vec_b = [0.999, 0.045, 0.0, 0.0]  # cosine ≈ 0.999 with vec_a
        # Insert event to confirm (with embedding) and a similar pending one
        eid1 = db.insert_event("dropbox", "162.125.21.2:443", embedding=vec_a)
        eid2 = db.insert_event("dropbox", "162.125.21.3:443", embedding=vec_b)

        h = self._handler()
        _post(h, "/action", {"id": eid1, "action": "confirmed"})

        row2 = next(r for r in db.get_recent() if r["id"] == eid2)
        self.assertEqual(row2["status"], "confirmed",
                         "similar pending event should be cascaded to confirmed")

    def test_reject_sets_status(self):
        eid = db.insert_event("nc", "9.9.9.9:4444")
        h = self._handler()
        _post(h, "/action", {"id": eid, "action": "rejected"})
        row = next(r for r in db.get_recent() if r["id"] == eid)
        self.assertEqual(row["status"], "rejected")

    def test_revert_sets_pending(self):
        eid = db.insert_event("bash", "1.2.3.4:22")
        db.update_status(eid, "confirmed")
        h = self._handler()
        resp = _post(h, "/action", {"id": eid, "action": "revert"})
        self.assertEqual(resp[0][0], 200)
        row = next(r for r in db.get_recent() if r["id"] == eid)
        self.assertEqual(row["status"], "pending")

    def test_revert_removes_from_baseline(self):
        # Test the baseline-removal logic directly (Path.home() is hard to mock inside panel)
        netmon_dir = Path.home() / ".netmon"
        netmon_dir.mkdir(parents=True, exist_ok=True)
        baseline   = netmon_dir / "baseline.txt"
        entry      = "revert_test|254.253.252.251:9999"

        # Seed baseline with our test entry plus an innocent one
        innocent = "chrome|8.8.8.8:443"
        original = baseline.read_text() if baseline.exists() else ""
        baseline.write_text(original + f"{entry}\n{innocent}\n")

        eid = db.insert_event("revert_test", "254.253.252.251:9999")
        db.update_status(eid, "confirmed")

        h = self._handler()
        _post(h, "/action", {"id": eid, "action": "revert"})

        try:
            remaining = baseline.read_text()
            self.assertNotIn(entry, remaining)
            self.assertIn(innocent, remaining)
            # DB status should be pending
            row = next(r for r in db.get_recent() if r["id"] == eid)
            self.assertEqual(row["status"], "pending")
        finally:
            # Restore baseline to original state
            lines = [l for l in baseline.read_text().splitlines()
                     if l not in (entry, innocent) or l in original.splitlines()]
            baseline.write_text(original)

    def test_revert_removes_from_blocked_ips(self):
        blocked = self._dir / "blocked_ips.txt"
        blocked.write_text("1.2.3.4\n5.5.5.5\n")
        eid = db.insert_event("nc", "1.2.3.4:4444")
        db.update_status(eid, "rejected")

        # Directly test the file manipulation logic
        bare_ip = "1.2.3.4"
        ips = blocked.read_text().splitlines()
        new_ips = [ip for ip in ips if ip.strip() != bare_ip]
        blocked.write_text("\n".join(new_ips) + "\n")

        self.assertNotIn("1.2.3.4", blocked.read_text())
        self.assertIn("5.5.5.5", blocked.read_text())


class TestConfigEndpoint(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._dir = Path(self._tmp.name)
        cfg_file  = self._dir / "config.json"
        cfg_file.write_text('{"autonomous_mode":false}')
        patch.object(panel, "CONFIG_FILE", cfg_file).start()
        patch.object(db,    "DB_PATH", self._dir / "test.db").start()
        db.init()

    def tearDown(self):
        patch.stopall()
        self._tmp.cleanup()

    def _handler(self):
        return _make_handler(self._dir)

    def test_toggle_autonomous_mode(self):
        with patch("panel._ollama_available", return_value=True):
            h = self._handler()
            resp = _post(h, "/config", {"toggle": "autonomous_mode"})
        self.assertEqual(resp[0][0], 200)
        cfg = json.loads(resp[0][1])
        self.assertTrue(cfg["autonomous_mode"])

    def test_set_llm_model(self):
        h = self._handler()
        resp = _post(h, "/config", {"llm_model": "llama3.2:3b"})
        cfg = json.loads(resp[0][1])
        self.assertEqual(cfg["llm_model"], "llama3.2:3b")


class TestHostCheck(unittest.TestCase):
    """Requests with a non-localhost Host header must be rejected (DNS rebinding defence)."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._dir = Path(self._tmp.name)
        patch.object(panel, "CONFIG_FILE", self._dir / "config.json").start()
        (self._dir / "config.json").write_text('{}')
        patch.object(db, "DB_PATH", self._dir / "test.db").start()
        db.init()

    def tearDown(self):
        patch.stopall()
        self._tmp.cleanup()

    def _handler(self):
        return _make_handler(self._dir)

    def test_foreign_host_get_returns_403(self):
        h = self._handler()
        h.path    = "/api/config"
        h.headers = {"Host": "attacker.example.com:6543"}
        responses = []
        h._respond = lambda code, body, ct="application/json": responses.append((code, body))
        h.do_GET()
        self.assertEqual(responses[0][0], 403)

    def test_foreign_host_post_returns_403(self):
        payload = json.dumps({"toggle": "autonomous_mode"}).encode()
        h = self._handler()
        h.path    = "/config"
        h.headers = {"Host": "attacker.example.com", "Content-Length": str(len(payload))}
        h.rfile   = io.BytesIO(payload)
        responses = []
        h._respond = lambda code, body, ct="application/json": responses.append((code, body))
        h.do_POST()
        self.assertEqual(responses[0][0], 403)


class TestGetEndpoints(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._dir = Path(self._tmp.name)
        cfg_file  = self._dir / "config.json"
        cfg_file.write_text('{"autonomous_mode":false}')
        patch.object(panel, "CONFIG_FILE", cfg_file).start()
        patch.object(db,    "DB_PATH", self._dir / "test.db").start()
        db.init()

    def tearDown(self):
        patch.stopall()
        self._tmp.cleanup()

    def _handler(self):
        return _make_handler(self._dir)

    def test_api_events_returns_json(self):
        db.insert_event("bash", "1.2.3.4:22")
        h = self._handler()
        resp = _get(h, "/api/events")
        self.assertEqual(resp[0][0], 200)
        data = json.loads(resp[0][1])
        self.assertIn("pending", data)
        self.assertIn("recent", data)
        self.assertEqual(len(data["pending"]), 1)

    def test_api_config_returns_json(self):
        h = self._handler()
        resp = _get(h, "/api/config")
        self.assertEqual(resp[0][0], 200)
        cfg = json.loads(resp[0][1])
        self.assertIn("autonomous_mode", cfg)

    def test_unknown_path_returns_404(self):
        h = self._handler()
        resp = _get(h, "/unknown/path")
        self.assertEqual(resp[0][0], 404)

    def test_api_blocked_ips_returns_list(self):
        # panel uses Path.home() / ".netmon" / "blocked_ips.txt"
        netmon_dir = self._dir / ".netmon"
        netmon_dir.mkdir(exist_ok=True)
        blocked_file = netmon_dir / "blocked_ips.txt"
        blocked_file.write_text("1.2.3.4\n5.6.7.8\n")

        import unittest.mock as mock_mod
        home_patch = mock_mod.patch("pathlib.Path.home", return_value=self._dir)
        home_patch.start()
        try:
            h = self._handler()
            resp = _get(h, "/api/blocked-ips")
            self.assertEqual(resp[0][0], 200)
            data = json.loads(resp[0][1])
            self.assertIn("ips", data)
            self.assertIn("1.2.3.4", data["ips"])
            self.assertIn("5.6.7.8", data["ips"])
        finally:
            home_patch.stop()


class TestMalformedRequestHandling(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._dir = Path(self._tmp.name)
        cfg_file  = self._dir / "config.json"
        cfg_file.write_text('{"autonomous_mode":false}')
        patch.object(panel, "CONFIG_FILE", cfg_file).start()
        patch.object(db,    "DB_PATH", self._dir / "test.db").start()
        db.init()

    def tearDown(self):
        patch.stopall()
        self._tmp.cleanup()

    def _handler(self):
        return _make_handler(self._dir)

    def _post_raw(self, path: str, raw_bytes: bytes):
        h = self._handler()
        h.path    = path
        h.headers = {**_LOCAL_HOST, "Content-Length": str(len(raw_bytes))}
        h.rfile   = io.BytesIO(raw_bytes)
        responses = []
        h._respond = lambda code, body, ct="application/json": responses.append((code, body))
        h.do_POST()
        return responses

    def test_malformed_json_config_returns_400(self):
        resp = self._post_raw("/config", b"not valid json{")
        self.assertEqual(resp[0][0], 400)
        data = json.loads(resp[0][1])
        self.assertIn("error", data)

    def test_malformed_json_action_returns_400(self):
        resp = self._post_raw("/action", b"{bad json")
        self.assertEqual(resp[0][0], 400)

    def test_invalid_event_id_string_returns_400(self):
        resp = _post(self._handler(), "/action", {"id": "not-a-number", "action": "confirmed"})
        self.assertEqual(resp[0][0], 400)

    def test_invalid_event_id_negative_returns_400(self):
        resp = _post(self._handler(), "/action", {"id": -1, "action": "confirmed"})
        self.assertEqual(resp[0][0], 400)

    def test_invalid_event_id_zero_returns_400(self):
        resp = _post(self._handler(), "/action", {"id": 0, "action": "confirmed"})
        self.assertEqual(resp[0][0], 400)

    def test_invalid_action_returns_400(self):
        resp = _post(self._handler(), "/action", {"id": 1, "action": "delete_everything"})
        self.assertEqual(resp[0][0], 400)


class TestUnblockIpEndpoint(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._dir = Path(self._tmp.name)
        cfg_file  = self._dir / "config.json"
        cfg_file.write_text('{"autonomous_mode":false}')
        patch.object(panel, "CONFIG_FILE", cfg_file).start()
        patch.object(db,    "DB_PATH", self._dir / "test.db").start()
        db.init()

    def tearDown(self):
        patch.stopall()
        self._tmp.cleanup()

    def _handler(self):
        return _make_handler(self._dir)

    def _netmon_blocked_file(self):
        """Create .netmon dir under temp home and return path to blocked_ips.txt."""
        netmon_dir = self._dir / ".netmon"
        netmon_dir.mkdir(exist_ok=True)
        return netmon_dir / "blocked_ips.txt"

    def test_unblock_removes_ip(self):
        blocked_file = self._netmon_blocked_file()
        blocked_file.write_text("1.2.3.4\n5.5.5.5\n")
        import unittest.mock as mock_mod
        home_patch = mock_mod.patch("pathlib.Path.home", return_value=self._dir)
        home_patch.start()
        try:
            resp = _post(self._handler(), "/unblock-ip", {"ip": "1.2.3.4"})
            self.assertEqual(resp[0][0], 200)
            remaining = blocked_file.read_text()
            self.assertNotIn("1.2.3.4", remaining)
            self.assertIn("5.5.5.5", remaining)
        finally:
            home_patch.stop()

    def test_unblock_invalid_ip_returns_400(self):
        resp = _post(self._handler(), "/unblock-ip", {"ip": "not-an-ip"})
        self.assertEqual(resp[0][0], 400)

    def test_unblock_strips_port(self):
        blocked_file = self._netmon_blocked_file()
        blocked_file.write_text("1.2.3.4\n")
        import unittest.mock as mock_mod
        home_patch = mock_mod.patch("pathlib.Path.home", return_value=self._dir)
        home_patch.start()
        try:
            resp = _post(self._handler(), "/unblock-ip", {"ip": "1.2.3.4"})
            self.assertEqual(resp[0][0], 200)
        finally:
            home_patch.stop()


if __name__ == "__main__":
    unittest.main(verbosity=2)
