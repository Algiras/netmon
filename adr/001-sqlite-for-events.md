# ADR-001: SQLite for event storage

**Status:** Accepted  
**Date:** 2026-05

## Context

Events (process, remote, severity, summary, status, embedding) need to be stored persistently for the review panel, RAG lookups, and cascade decisions. Options were flat files (JSON/JSONL), SQLite, or a full database server.

## Decision

SQLite via the standard library (`sqlite3`). Embeddings stored as JSON-serialised float arrays in a TEXT column.

## Rationale

- Zero dependencies — ships with Python
- Single file (`~/.netmon/netmon.db`) — easy to inspect, backup, delete
- Full SQL for filtering (status, timestamp, similarity joins) without an ORM
- Sufficient for the expected write rate (~1–10 events/minute at peak)

## Consequences

- No concurrent writers — mitigated by WAL mode and `_conn()` context manager
- Cosine similarity is computed in Python (no vector index) — acceptable at <10k events; would need migration if event volume grows by orders of magnitude
