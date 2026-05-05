# Architecture

## Overview

netmon is a collection of small, single-purpose components connected by flat files and a local SQLite database. Each component can be restarted, replaced, or debugged independently.

```
launchd (60-second timer)
    └── monitor.sh               # lsof snapshot → anomaly log
        └── volume_check.py      # connection-count spike detection

launchd (5-minute timer)
    └── analyze.py               # reads anomaly log → AI triage → DB + notifications

launchd (60-second timer)
    └── analyze.py --recheck     # re-evaluate pending events (heartbeat)

~/.netmon/netmon.db              # SQLite: events + embeddings
~/.netmon/baseline.txt           # confirmed-safe process|remote pairs
~/.netmon/blocked_ips.txt        # blocked IPs (+ pf enforcement if enabled)
~/.netmon/blocked_ips_meta.json  # metadata for each blocked IP
~/.netmon/connection_counts.json # rolling per-pair connection-count history
~/.netmon/process_policy.json    # per-process expected-IP allowlist (AI agents)
~/.netmon/config.json            # user settings
~/.netmon/panel_token            # 64-char auth token (mode 0600)

panel.py                         # local HTTP API server (localhost:6543)
    ├── GET  /api/events          # pending + recent events + config
    ├── GET  /api/config          # current settings
    ├── GET  /api/models          # Ollama model capabilities
    ├── GET  /api/baseline        # baseline entries
    ├── GET  /api/blocked-ips     # blocked IPs with metadata
    ├── GET  /api/pf-status       # pf enforcement status
    ├── GET  /api/process-policy  # per-process IP allowlist
    ├── POST /action              # confirm / reject / revert event
    ├── POST /config              # update settings
    ├── POST /baseline/remove     # remove baseline entry
    ├── POST /unblock-ip          # remove IP from block list
    └── POST /recheck             # trigger reanalysis

MenuBar/ (Swift)
    ├── NetmonMenuBar             # status bar icon + quick-action menu
    ├── PanelWindowController     # native SwiftUI panel window
    └── Notifier                  # UNUserNotification sender

netmon_mcp.py                    # MCP server (stdio transport)
```

---

## Data flow

### Detection path

```
lsof -i 4 (60 s)
    → comm -23 vs baseline.txt        ← new process×IP pairs only
    → volume_check.py                 ← spike detection on existing pairs
    → [ANOMALY] / [VOLUME_ANOMALY] lines → anomalies.log
```

### Analysis path

```
analyze.py reads anomalies.log:
    1. Injection guard          → [BLOCKED] event (Critical, no LLM)
    2. Process policy check     → [POLICY_VIOLATION] event (Critical, no LLM)
    3. Baseline dedup           → already known? skip
    4. Embed new event          → Ollama /api/embed
    5. RAG lookup               → cosine similarity vs past events in DB
    6. Build LLM context        → event + similar past decisions
    7. LLM triage               → tool call:
        send_notification       → DB insert (pending) + macOS notification
        auto_resolve(confirmed) → DB insert (confirmed) + baseline entry
        auto_resolve(rejected)  → DB insert (rejected) + IP blocked
        mark_as_normal          → DB insert (confirmed) + baseline entry
```

### Heartbeat path

```
analyze.py --recheck (60 s):
    → re-fetch all pending events from DB
    → re-embed + re-run RAG
    → re-triage with latest context
    → update DB if decision changed
```

---

## Component details

### monitor.sh

Runs `lsof -i 4 -n -P` (all IPv4 connections, no DNS resolution, numeric ports), normalises the output to `process|IP:port` pairs, diffs against `baseline.txt` with `comm -23`, and appends `[ANOMALY]` lines to `anomalies.log`.

Runs every 60 seconds via LaunchAgent. Lightweight — no Python, no network calls, no LLM.

### analyze.py

The core intelligence layer. Reads unprocessed lines from `anomalies.log` (tracked by byte offset in `analysis.log`), applies the security layers in order, embeds each event, retrieves similar past events, and sends the assembled context to the LLM.

LLM backend: Ollama (default) or Anthropic Claude API (cloud, optional).

### db.py

Thin SQLite wrapper. Tables:
- `events` — all triage events with status, severity, type, summary
- `events.embedding` — serialised float32 vector for RAG
- In-process cosine similarity search (no vector DB dependency)

### embed.py

Calls `POST http://localhost:11434/api/embed` with the configured embed model. Returns a list of floats. Model is configurable; switching clears all stored embeddings.

### panel.py

`http.server`-based HTTP server. Single-threaded (Python GIL), sufficient for local use. All routes require `Host: localhost:6543` and `X-Netmon-Token` headers. Token is generated at first boot and stored at `~/.netmon/panel_token` (mode 0600).

### MenuBar (Swift)

SwiftUI app that runs as a menu bar item (`.accessoryOnly` activation policy). Uses `UNUserNotificationCenter` for system notifications. The panel is a native `NSWindow` with a SwiftUI view — not a web view. Reads the panel token from disk once at startup.

---

## Alert severities

| Tag | Severity | Routed via | Requires human? |
|-----|----------|-----------|-----------------|
| `[BLOCKED]` | Critical | Direct DB insert | Yes — no AI review |
| `[POLICY_VIOLATION]` | Critical | Direct DB insert + notify | Yes — no AI review |
| `[VOLUME_ANOMALY]` | Warning+ | LLM triage | Depends on LLM decision |
| `[ANOMALY]` | Info–Critical | LLM triage | Depends on LLM decision |

---

## Security design

- **Loopback-only** — panel server binds to `127.0.0.1:6543`, no LAN exposure
- **Token auth** — all panel routes require `X-Netmon-Token` (timing-safe comparison)
- **No cloud by default** — all inference local via Ollama; cloud backend is opt-in
- **AI agent protection** — process policy + injection guard specifically target AI agent exfiltration and prompt injection
- **Kernel enforcement** — optional pf anchor blocks rejected IPs at the network layer
