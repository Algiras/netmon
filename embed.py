"""
~/.netmon/embed.py — Thin wrapper around Ollama /api/embed.
Reads embedding model from config.json (key: embed_model).
"""

from __future__ import annotations

import json
import urllib.request
from pathlib import Path

OLLAMA_URL   = "http://localhost:11434"
_CONFIG_FILE = Path.home() / ".netmon" / "config.json"
_DEFAULT_MODEL = "nomic-embed-text-v2-moe"


def _embed_model() -> str:
    try:
        return json.loads(_CONFIG_FILE.read_text()).get("embed_model", _DEFAULT_MODEL)
    except Exception:
        return _DEFAULT_MODEL


def embed(text: str) -> list[float] | None:
    payload = json.dumps({"model": _embed_model(), "input": text}).encode()
    req = urllib.request.Request(
        f"{OLLAMA_URL}/api/embed",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read())
            vecs = data.get("embeddings", [])
            return vecs[0] if vecs else None
    except Exception:
        return None


def embed_event(process: str, remote: str, summary: str = "") -> list[float] | None:
    """Build a canonical text representation of an event and embed it."""
    text = f"network event: {process} connected to {remote}"
    if summary:
        text += f". Context: {summary}"
    return embed(text)
