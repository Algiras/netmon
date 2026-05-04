"""Tests for embed.py — Ollama embedding calls and vector normalisation."""
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).parent.parent))

import embed


class TestEmbedModelConfig(unittest.TestCase):
    def test_reads_embed_model_from_config(self):
        import tempfile, json
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump({"embed_model": "nomic-embed-text:latest"}, f)
            tmp = Path(f.name)
        with patch.object(embed, "_CONFIG_FILE", tmp):
            model = embed._embed_model()
        self.assertEqual(model, "nomic-embed-text:latest")
        Path(tmp).unlink()

    def test_defaults_when_config_missing(self):
        with patch.object(embed, "_CONFIG_FILE", Path("/nonexistent/config.json")):
            model = embed._embed_model()
        self.assertEqual(model, embed._DEFAULT_MODEL)


class TestEmbedEvent(unittest.TestCase):
    def _fake_response(self, vector):
        """Build a fake urllib response returning the given embedding."""
        mock_resp = MagicMock()
        mock_resp.read.return_value = json.dumps({"embeddings": [vector]}).encode()
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        return mock_resp

    def test_returns_vector_on_success(self):
        vec = [0.1] * 768
        with patch("urllib.request.urlopen", return_value=self._fake_response(vec)):
            result = embed.embed_event("python3", "1.2.3.4:443")
        self.assertEqual(len(result), 768)
        self.assertAlmostEqual(result[0], 0.1)

    def test_returns_none_on_error(self):
        with patch("urllib.request.urlopen", side_effect=Exception("connection refused")):
            result = embed.embed_event("bash", "5.6.7.8:22")
        self.assertIsNone(result)

    def test_canonical_text_includes_process_and_remote(self):
        """Verify the text sent to Ollama contains process and remote."""
        captured = {}
        def fake_urlopen(req, timeout=None):
            captured["data"] = json.loads(req.data)
            return self._fake_response([0.0] * 768)
        with patch("urllib.request.urlopen", side_effect=fake_urlopen):
            embed.embed_event("chrome", "142.250.80.46:443", "Google CDN")
        text = captured["data"]["input"]
        self.assertIn("chrome", text)
        self.assertIn("142.250.80.46:443", text)

    def test_summary_included_in_text(self):
        captured = {}
        def fake_urlopen(req, timeout=None):
            captured["data"] = json.loads(req.data)
            return self._fake_response([0.0] * 768)
        with patch("urllib.request.urlopen", side_effect=fake_urlopen):
            embed.embed_event("bash", "1.2.3.4:22", "suspicious SSH")
        self.assertIn("suspicious SSH", captured["data"]["input"])

    def test_empty_embedding_returns_none(self):
        mock_resp = MagicMock()
        mock_resp.read.return_value = json.dumps({"embeddings": []}).encode()
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        with patch("urllib.request.urlopen", return_value=mock_resp):
            result = embed.embed_event("proc", "1.2.3.4:80")
        self.assertIsNone(result)


if __name__ == "__main__":
    unittest.main(verbosity=2)
