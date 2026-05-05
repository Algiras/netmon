"""Tests for analyze.py — anomaly parsing, context building, tool dispatch."""
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).parent.parent))

import analyze


class TestBuildContext(unittest.TestCase):
    def _make_lines(self, entries):
        lines = []
        for proc, remote in entries:
            lines.append(f"[2026-05-05 00:00:00] [ANOMALY] {proc} -> {remote}")
        return lines

    def test_basic_parsing(self):
        lines = self._make_lines([("python3", "1.2.3.4:443"), ("bash", "5.6.7.8:22")])
        with patch("embed.embed_event", return_value=None), \
             patch("db.find_similar", return_value=[]):
            summary, parsed = analyze.build_context(lines)
        self.assertEqual(len(parsed), 2)
        self.assertEqual(parsed[0]["process"], "python3")
        self.assertEqual(parsed[1]["remote"], "5.6.7.8:22")

    def test_process_frequency(self):
        lines = self._make_lines([
            ("chrome", "1.1.1.1:443"),
            ("chrome", "2.2.2.2:443"),
            ("bash",   "3.3.3.3:22"),
        ])
        with patch("embed.embed_event", return_value=None), \
             patch("db.find_similar", return_value=[]):
            summary, _ = analyze.build_context(lines)
        self.assertIn("chrome: 2", summary)
        self.assertIn("bash: 1", summary)

    def test_rag_snippets_included(self):
        lines = self._make_lines([("python3", "1.2.3.4:443")])
        fake_similar = [{
            "ts": "2026-05-01 12:00:00", "process": "python3",
            "remote": "1.2.3.4:443", "status": "rejected",
            "similarity": 0.95, "summary": "known bad",
        }]
        with patch("embed.embed_event", return_value=[0.1] * 768), \
             patch("db.find_similar", return_value=fake_similar):
            summary, _ = analyze.build_context(lines)
        self.assertIn("RAG memory", summary)
        self.assertIn("known bad", summary)

    def test_malformed_lines_skipped(self):
        lines = ["garbage line", "[bad] format", ""] + \
                self._make_lines([("bash", "1.2.3.4:80")])
        with patch("embed.embed_event", return_value=None), \
             patch("db.find_similar", return_value=[]):
            summary, parsed = analyze.build_context(lines)
        self.assertEqual(len(parsed), 1)


class TestDispatch(unittest.TestCase):
    def test_send_notification(self):
        with patch("analyze.send_notification", return_value="queued") as mock:
            result = analyze.dispatch("send_notification", {
                "process": "bash", "remote": "1.2.3.4:4444",
                "title": "Alert", "message": "Suspicious", "severity": "warning",
            })
        mock.assert_called_once()
        self.assertEqual(result, "queued")

    def test_mark_as_normal(self):
        with patch("analyze.mark_as_normal", return_value="added") as mock:
            result = analyze.dispatch("mark_as_normal", {
                "process": "chrome", "remote": "1.1.1.1:443", "reason": "CDN",
            })
        mock.assert_called_once_with(process="chrome", remote="1.1.1.1:443", reason="CDN")

    def test_auto_resolve(self):
        with patch("analyze.auto_resolve", return_value="auto-confirmed") as mock:
            result = analyze.dispatch("auto_resolve", {
                "process": "slack", "remote": "52.36.201.45:443",
                "decision": "confirmed", "reason": "Slack CDN",
            })
        mock.assert_called_once()
        self.assertEqual(result, "auto-confirmed")

    def test_unknown_tool(self):
        result = analyze.dispatch("nonexistent_tool", {})
        self.assertIn("unknown tool", result)

    def test_json_string_args(self):
        with patch("analyze.mark_as_normal", return_value="ok"):
            result = analyze.dispatch("mark_as_normal",
                '{"process":"chrome","remote":"1.1.1.1:443"}')
        self.assertEqual(result, "ok")


class TestReadConfig(unittest.TestCase):
    def test_reads_model(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump({"llm_model": "llama3.2:3b", "autonomous_mode": True}, f)
            tmp = Path(f.name)
        with patch.object(analyze, "CONFIG_FILE", tmp):
            cfg = analyze.read_config()
        self.assertEqual(cfg["llm_model"], "llama3.2:3b")
        self.assertTrue(cfg["autonomous_mode"])
        tmp.unlink()

    def test_defaults_on_missing_file(self):
        with patch.object(analyze, "CONFIG_FILE", Path("/nonexistent/config.json")):
            cfg = analyze.read_config()
        self.assertEqual(cfg, {"autonomous_mode": False})


class TestMarkAsNormal(unittest.TestCase):
    def test_appends_to_baseline(self):
        with tempfile.TemporaryDirectory() as d:
            baseline = Path(d) / "baseline.txt"
            baseline.write_text("existing|1.2.3.4:443\n")
            with patch.object(analyze, "NETMON_DIR", Path(d)):
                result = analyze.mark_as_normal("chrome", "5.6.7.8:443", "CDN")
            self.assertIn("chrome|5.6.7.8:443", baseline.read_text())
            self.assertEqual(result, "added to baseline")

    def test_no_duplicate_in_baseline(self):
        with tempfile.TemporaryDirectory() as d:
            baseline = Path(d) / "baseline.txt"
            baseline.write_text("chrome|5.6.7.8:443\n")
            with patch.object(analyze, "NETMON_DIR", Path(d)):
                result = analyze.mark_as_normal("chrome", "5.6.7.8:443")
            self.assertEqual(result, "already in baseline")
            self.assertEqual(baseline.read_text().count("chrome|5.6.7.8:443"), 1)


class TestBlockIp(unittest.TestCase):
    def test_writes_to_blocked_file(self):
        with tempfile.TemporaryDirectory() as d:
            with patch.object(analyze, "NETMON_DIR", Path(d)), \
                 patch.object(analyze, "BLOCKED_FILE", Path(d) / "blocked_ips.txt"), \
                 patch("subprocess.run", return_value=MagicMock(returncode=1)):
                analyze.block_ip("1.2.3.4", "known C2")
            blocked = (Path(d) / "blocked_ips.txt").read_text()
            self.assertIn("1.2.3.4", blocked)

    def test_strips_port_from_ip(self):
        with tempfile.TemporaryDirectory() as d:
            with patch.object(analyze, "BLOCKED_FILE", Path(d) / "blocked_ips.txt"), \
                 patch("subprocess.run", return_value=MagicMock(returncode=1)):
                analyze.block_ip("1.2.3.4:4444", "port included by mistake")
            blocked = (Path(d) / "blocked_ips.txt").read_text().strip()
            self.assertEqual(blocked, "1.2.3.4")

    def test_no_duplicate_entries(self):
        with tempfile.TemporaryDirectory() as d:
            bf = Path(d) / "blocked_ips.txt"
            bf.write_text("1.2.3.4\n")
            with patch.object(analyze, "BLOCKED_FILE", bf), \
                 patch("subprocess.run", return_value=MagicMock(returncode=1)):
                analyze.block_ip("1.2.3.4", "duplicate")
            self.assertEqual(bf.read_text().count("1.2.3.4"), 1)


class TestKillProcess(unittest.TestCase):
    def test_returns_killed_on_success(self):
        with patch("subprocess.run", return_value=MagicMock(returncode=0, stderr="")) as mock:
            result = analyze.kill_process("malware", "exfiltrating data")
        mock.assert_called_once()
        self.assertIn("killed", result)

    def test_uses_sigkill_when_force(self):
        with patch("subprocess.run", return_value=MagicMock(returncode=0, stderr="")) as mock:
            analyze.kill_process("malware", "force kill", force=True)
        args = mock.call_args[0][0]
        self.assertIn("-9", args)

    def test_returns_failure_message_on_error(self):
        with patch("subprocess.run", return_value=MagicMock(returncode=1, stderr="no process found")):
            result = analyze.kill_process("nonexistent", "test")
        self.assertIn("kill failed", result)


class TestGetProcessInfo(unittest.TestCase):
    def test_returns_lsof_output(self):
        fake_lsof = MagicMock(returncode=0, stdout="COMMAND  PID  USER\npython3  1234 user")
        fake_ps   = MagicMock(returncode=0, stdout="USER PID\nuser 1234 python3")
        with patch("subprocess.run", side_effect=[fake_lsof, fake_ps]):
            result = analyze.get_process_info("python3")
        self.assertIn("python3", result)

    def test_returns_not_found_when_empty(self):
        fake = MagicMock(returncode=0, stdout="")
        with patch("subprocess.run", side_effect=[fake, fake]):
            result = analyze.get_process_info("nonexistentproc")
        self.assertIn("No info found", result)

    def test_dispatch_routes_get_process_info(self):
        with patch("analyze.get_process_info", return_value="info") as mock:
            analyze.dispatch("get_process_info", {"process_name": "python3"})
        mock.assert_called_once_with("python3")

    def test_dispatch_routes_kill_process(self):
        with patch("analyze.kill_process", return_value="killed") as mock:
            analyze.dispatch("kill_process", {"process_name": "malware", "reason": "bad", "force": True})
        mock.assert_called_once_with(process_name="malware", reason="bad", force=True)

    def test_dispatch_routes_block_ip(self):
        with patch("analyze.block_ip", return_value="blocked") as mock:
            analyze.dispatch("block_ip", {"ip": "1.2.3.4", "reason": "C2"})
        mock.assert_called_once_with(ip="1.2.3.4", reason="C2")


if __name__ == "__main__":
    unittest.main(verbosity=2)
