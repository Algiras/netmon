"""
~/.netmon/db.py — SQLite store with in-process cosine-similarity vector search.
No extensions required; works with Python stdlib sqlite3.
"""

from __future__ import annotations

import json
import math
import sqlite3
from datetime import datetime
from pathlib import Path

DB_PATH = Path.home() / ".netmon" / "netmon.db"
EMB_DIM = 768  # nomic-embed-text-v2-moe


def _conn() -> sqlite3.Connection:
    c = sqlite3.connect(DB_PATH)
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("PRAGMA synchronous=NORMAL")
    return c


def init():
    with _conn() as c:
        c.executescript("""
        CREATE TABLE IF NOT EXISTS events (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            ts        TEXT    NOT NULL,
            process   TEXT    NOT NULL,
            remote    TEXT    NOT NULL,
            severity  TEXT    DEFAULT 'unknown',
            summary   TEXT    DEFAULT '',
            status    TEXT    DEFAULT 'pending',
            embedding TEXT    DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS idx_events_status ON events(status);
        CREATE INDEX IF NOT EXISTS idx_events_ts     ON events(ts DESC);
        CREATE INDEX IF NOT EXISTS idx_events_proc   ON events(process);
        """)


def insert_event(
    process: str,
    remote: str,
    severity: str = "unknown",
    summary: str = "",
    embedding: list[float] | None = None,
    ts: str | None = None,
) -> int:
    ts = ts or datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    emb_json = json.dumps(embedding) if embedding else ""
    with _conn() as c:
        cur = c.execute(
            "INSERT INTO events (ts,process,remote,severity,summary,embedding,status) "
            "VALUES (?,?,?,?,?,?,'pending')",
            (ts, process, remote, severity, summary, emb_json),
        )
        return cur.lastrowid


def update_status(event_id: int, status: str):
    """status: 'confirmed' | 'rejected' | 'pending'"""
    with _conn() as c:
        c.execute("UPDATE events SET status=? WHERE id=?", (status, event_id))


def get_pending() -> list[dict]:
    with _conn() as c:
        rows = c.execute(
            "SELECT id,ts,process,remote,severity,summary,status FROM events "
            "WHERE status='pending' ORDER BY ts DESC"
        ).fetchall()
    return [dict(r) for r in rows]


def get_recent(limit: int = 50) -> list[dict]:
    with _conn() as c:
        rows = c.execute(
            "SELECT id,ts,process,remote,severity,summary,status FROM events "
            "ORDER BY ts DESC LIMIT ?", (limit,)
        ).fetchall()
    return [dict(r) for r in rows]


# ── Vector search ─────────────────────────────────────────────────────────────

def _cosine(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    na  = math.sqrt(sum(x * x for x in a))
    nb  = math.sqrt(sum(x * x for x in b))
    return dot / (na * nb) if na and nb else 0.0


def clear_embeddings():
    """Null-out all stored embeddings (call when embedding model changes)."""
    with _conn() as c:
        c.execute("UPDATE events SET embedding = ''")


def find_similar(
    embedding: list[float],
    top_k: int = 5,
    min_sim: float = 0.72,
    exclude_status: str | None = None,
) -> list[dict]:
    """Return past events with cosine similarity ≥ min_sim to the given embedding."""
    with _conn() as c:
        query = (
            "SELECT id,ts,process,remote,severity,summary,status,embedding FROM events "
            "WHERE embedding != '' ORDER BY ts DESC LIMIT 1000"
        )
        rows = c.execute(query).fetchall()

    hits: list[tuple[float, dict]] = []
    for row in rows:
        if exclude_status and row["status"] == exclude_status:
            continue
        try:
            stored = json.loads(row["embedding"])
            sim = _cosine(embedding, stored)
            if sim >= min_sim:
                hits.append((sim, {**dict(row), "similarity": round(sim, 3)}))
        except Exception:
            continue

    hits.sort(key=lambda x: -x[0])
    return [h[1] for h in hits[:top_k]]
