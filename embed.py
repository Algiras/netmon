"""
~/.netmon/embed.py — Thin wrapper around Ollama /api/embed.
Uses nomic-embed-text-v2-moe (768-dim) for all event embeddings.
"""

import json
import urllib.error
import urllib.request

OLLAMA_URL   = "http://localhost:11434"
EMBED_MODEL  = "nomic-embed-text-v2-moe"


def embed(text: str) -> list[float] | None:
    payload = json.dumps({"model": EMBED_MODEL, "input": text}).encode()
    req = urllib.request.Request(
        f"{OLLAMA_URL}/api/embed",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read())
            return data["embeddings"][0]
    except Exception:
        return None


def embed_event(process: str, remote: str, summary: str = "") -> list[float] | None:
    """Build a canonical text representation of an event and embed it."""
    text = f"network event: {process} connected to {remote}"
    if summary:
        text += f". Context: {summary}"
    return embed(text)
