# netmon — Architecture Overview

## Purpose

Local-machine network monitor for macOS. Detects unexpected outbound connections from any process, with AI-assisted triage and specific hardening for AI agent processes.

## Component Map

```
launchd (60-second timer)
    └── monitor.sh               # lsof snapshot → anomaly log
        └── volume_check.py      # connection-count spike detection

launchd (60-second timer, heartbeat)
    └── analyze.py               # reads anomaly log → AI triage → DB + notifications

~/.netmon/netmon.db              # SQLite: events + embeddings
~/.netmon/baseline.txt           # confirmed-safe process|remote pairs
~/.netmon/blocked_ips.txt        # blocked IPs (+ pf enforcement if enabled)
~/.netmon/blocked_ips_meta.json  # metadata for each blocked IP
~/.netmon/connection_counts.json # rolling per-pair connection-count history
~/.netmon/process_policy.json    # per-process expected-IP allowlist (AI agents)
~/.netmon/config.json            # user settings

panel.py                         # local HTTP server (localhost:6543)
    ├── GET  /api/events          # pending + recent events + config
    ├── GET  /api/baseline        # baseline entries
    ├── GET  /api/blocked-ips     # blocked IPs with metadata
    ├── GET  /api/pf-status       # pf enforcement status
    ├── GET  /api/process-policy  # per-process IP allowlist
    ├── GET  /api/models          # Ollama model list
    ├── POST /action              # confirm / reject / revert event
    ├── POST /config              # update settings
    ├── POST /baseline/remove     # remove baseline entry
    ├── POST /unblock-ip          # remove IP from block list
    └── POST /recheck             # trigger reanalysis

MenuBar app (Swift)
    ├── NetmonMenuBar             # status bar icon + quick-action menu
    ├── PanelWindowController     # embedded SwiftUI web view (panel UI)
    └── Notifier                  # UNUserNotification sender
```

## Data Flow

```
lsof snapshot
    → comm -23 vs baseline.txt        (new pairs only)
    → [ANOMALY] lines in anomalies.log

volume_check.py
    → lsof counts per pair
    → rolling window in connection_counts.json
    → [VOLUME_ANOMALY] lines in anomalies.log (on spike)

analyze.py reads anomaly log:
    1. Injection guard (regex + optional LLM)  → [BLOCKED] event
    2. Process policy check                    → [POLICY_VIOLATION] event (no LLM)
    3. LLM triage (Ollama or Claude)           → tool calls:
        - send_notification  → DB insert + macOS notification
        - add_to_review      → DB insert (pending)
        - mark_as_normal     → DB insert (confirmed) + baseline entry
        - auto_resolve       → DB update
    4. Sweep/recheck pending events via RAG similarity
```

## Alert Severities

| Tag | Severity | Routed via | Requires human? |
|-----|----------|-----------|-----------------|
| `[BLOCKED]` | critical | Direct DB insert | Yes — no AI review |
| `[POLICY_VIOLATION]` | critical | Direct DB insert + notify | Yes — no AI review |
| `[VOLUME_ANOMALY]` | warning+ | LLM triage | Depends on LLM decision |
| `[ANOMALY]` | info–critical | LLM triage | Depends on LLM decision |

## Backends

`analyze.py` supports two LLM backends, selected via `config.json`:

- **ollama** (default) — local inference via Ollama REST API (`localhost:11434`)
- **claude** — Anthropic API via `ANTHROPIC_API_KEY`

The embed model is always local (Ollama) for RAG/similarity lookups.

## Security Layers

1. **Baseline** — process×IP pairs confirmed safe; new pairs trigger review
2. **Injection guard** — regex + optional LLM scan on assembled context before LLM triage
3. **Process policy** — per-process expected CIDR allowlist; violations skip LLM entirely
4. **Volume check** — rolling connection-count baseline; spike = anomaly even for known pairs
5. **IP blocking** — manual or reject-triggered; optional pf enforcement (`setup-pf.sh`)
6. **RAG cascade** — similar past decisions auto-applied to new events (cosine sim > 0.88)
