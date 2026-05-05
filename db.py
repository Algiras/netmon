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
EMB_DIM             = 768   # nomic-embed-text-v2-moe
_FIND_SIMILAR_LIMIT = 5000  # max rows scanned by find_similar()


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


def find_pending_event(process: str, remote: str) -> int | None:
    """Return the id of an existing pending event for this process+remote, or None."""
    with _conn() as c:
        row = c.execute(
            "SELECT id FROM events WHERE process=? AND remote=? AND status='pending' "
            "ORDER BY ts DESC LIMIT 1",
            (process, remote),
        ).fetchone()
    return row["id"] if row else None


def update_event(event_id: int, status: str, severity: str, summary: str,
                 embedding: list[float] | None = None):
    """Update an existing event's status, severity, summary, and optionally embedding."""
    emb_json = json.dumps(embedding) if embedding else ""
    with _conn() as c:
        if embedding:
            c.execute(
                "UPDATE events SET status=?,severity=?,summary=?,embedding=? WHERE id=?",
                (status, severity, summary, emb_json, event_id),
            )
        else:
            c.execute(
                "UPDATE events SET status=?,severity=?,summary=? WHERE id=?",
                (status, severity, summary, event_id),
            )


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


def upsert_resolved_event(
    process: str, remote: str, decision: str,
    severity: str, summary: str,
    embedding: list[float] | None = None,
) -> int:
    """
    Atomically find an existing pending event for (process, remote) and resolve it,
    or insert a new pre-resolved event.  Single transaction — no TOCTOU gap.
    Returns the event id.
    """
    emb_json = json.dumps(embedding) if embedding else ""
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with _conn() as c:
        row = c.execute(
            "SELECT id FROM events WHERE process=? AND remote=? AND status='pending' "
            "ORDER BY ts DESC LIMIT 1",
            (process, remote),
        ).fetchone()
        if row:
            event_id = row["id"]
            if emb_json:
                c.execute(
                    "UPDATE events SET status=?,severity=?,summary=?,embedding=? WHERE id=?",
                    (decision, severity, summary, emb_json, event_id),
                )
            else:
                c.execute(
                    "UPDATE events SET status=?,severity=?,summary=? WHERE id=?",
                    (decision, severity, summary, event_id),
                )
        else:
            cur = c.execute(
                "INSERT INTO events (ts,process,remote,severity,summary,embedding,status) "
                "VALUES (?,?,?,?,?,?,?)",
                (ts, process, remote, severity, summary, emb_json, decision),
            )
            event_id = cur.lastrowid
    return event_id


def cascade_decision(event_id: int, decision: str, min_sim: float) -> int:
    """
    Find all pending events similar to event_id and resolve them in one transaction.
    Returns count of resolved events.
    """
    with _conn() as c:
        src = c.execute("SELECT embedding FROM events WHERE id=?", (event_id,)).fetchone()
        if not src or not src["embedding"]:
            return 0
        try:
            vector = json.loads(src["embedding"])
        except Exception:
            return 0

        rows = c.execute(
            "SELECT id, severity, embedding FROM events "
            "WHERE status='pending' AND embedding != '' AND id != ?",
            (event_id,),
        ).fetchall()

        to_update: list[tuple[int, float]] = []
        for r in rows:
            try:
                sim = _cosine(vector, json.loads(r["embedding"]))
                if sim >= min_sim:
                    to_update.append((r["id"], round(sim, 3)))
            except Exception:
                continue

        for eid, sim in to_update:
            c.execute(
                "UPDATE events SET status=?, summary=? WHERE id=?",
                (decision,
                 f"[AUTO-{decision.upper()}] Cascaded from similar event #{event_id} (sim={sim})",
                 eid),
            )
    return len(to_update)


def clear_embeddings():
    """Null-out all stored embeddings (call when embedding model changes)."""
    with _conn() as c:
        c.execute("UPDATE events SET embedding = ''")


def prune_old_events() -> int:
    """Delete events older than 30 days with status not 'pending', then VACUUM.
    Returns the count of deleted rows."""
    with _conn() as c:
        cur = c.execute(
            "DELETE FROM events "
            "WHERE status != 'pending' "
            "AND ts < datetime('now', '-30 days')"
        )
        deleted = cur.rowcount
        c.execute("VACUUM")
    return deleted


def get_event_embedding(event_id: int) -> list[float] | None:
    """Return the stored embedding for an event, or None if absent."""
    with _conn() as c:
        row = c.execute("SELECT embedding FROM events WHERE id=?", (event_id,)).fetchone()
    if not row or not row["embedding"]:
        return None
    try:
        return json.loads(row["embedding"])
    except Exception:
        return None


def find_similar(
    embedding: list[float],
    top_k: int = 5,
    min_sim: float = 0.72,
    exclude_status: str | None = None,
    only_status: str | None = None,
) -> list[dict]:
    """Return past events with cosine similarity ≥ min_sim to the given embedding."""
    with _conn() as c:
        rows = c.execute(
            "SELECT id,ts,process,remote,severity,summary,status,embedding FROM events "
            "WHERE embedding != '' ORDER BY ts DESC LIMIT ?",
            (_FIND_SIMILAR_LIMIT,),
        ).fetchall()

    hits: list[tuple[float, dict]] = []
    for row in rows:
        if exclude_status and row["status"] == exclude_status:
            continue
        if only_status and row["status"] != only_status:
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
