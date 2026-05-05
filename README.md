# ⚡ netmon

[![Build DMG](https://github.com/Algiras/netmon/actions/workflows/build-dmg.yml/badge.svg)](https://github.com/Algiras/netmon/actions/workflows/build-dmg.yml)

Local network anomaly monitor for macOS. Detects suspicious outbound connections using a **local LLM with tool calling**, RAG short-term memory, a native menu bar agent, and a dark-theme web review panel — everything runs on-device, no cloud required.

---

## How it works

```
lsof (60s) ──► anomalies.log ──► analyze.py (5 min) ──► notifications
                                       │                       │
                               embed + RAG lookup         panel UI / MCP
                               (nomic-embed-text)    localhost:6543
                                       │
                               Ollama LLM (tool calls)
                               granite4.1:3b / llama3.2 / …
                               ├─ send_notification   → queues for review
                               ├─ auto_resolve        → autonomous confirm/reject
                               └─ mark_as_normal      → adds to baseline

 confirm/reject ──► RAG cascade: similar pending events auto-resolved
                    (cosine similarity ≥ 0.88 across stored embeddings)
```

### Components

| Component | What it does |
|-----------|-------------|
| `monitor.sh` | Polls `lsof -i 4` every 60 s, diffs against `baseline.txt`, writes `[ANOMALY]` lines |
| `analyze.py` | Reads new anomalies, embeds with Ollama, retrieves similar past events (RAG), calls LLM |
| `db.py` | SQLite event store with in-process cosine-similarity vector search |
| `embed.py` | Thin wrapper around `POST /api/embed` — model configurable |
| `panel.py` | Dark-theme HTTP review panel at `localhost:6543` |
| `MenuBar/` | Swift menu bar app — `⚡ N` badge, inline confirm/reject, mode toggle |
| `build.sh` | Compile Swift app + reload LaunchAgents |
| `install.sh` | One-shot first-run setup |

---

## Requirements

- macOS 13 Ventura or later
- [Ollama](https://ollama.com) (at least one tool-capable model)
- Python 3.10+ — Homebrew recommended (`brew install python`)
- Xcode Command Line Tools — `xcode-select --install`

---

## Install

```bash
git clone https://github.com/Algiras/netmon ~/.netmon
bash ~/.netmon/install.sh
```

`install.sh`:
1. Pulls `granite4.1:3b` and `nomic-embed-text-v2-moe` from Ollama
2. Writes four LaunchAgent plists to `~/Library/LaunchAgents/`
3. Builds the Swift menu bar app
4. Loads all agents — they will restart automatically at every login

After install you'll see `⚡` in your menu bar and the panel at http://localhost:6543.

---

## Models

netmon uses two separate models, both configurable from the panel:

| Role | Default | Config key |
|------|---------|------------|
| **LLM** (analysis + tool calls) | `granite4.1:3b` | `llm_model` |
| **Embedding** (RAG memory) | `nomic-embed-text-v2-moe` | `embed_model` |

The panel's model bar shows only models that support the required capability (`tools` for LLM, `embedding` for vectors). Any Ollama model works.

> **Note:** Changing the embedding model clears all stored embeddings — the panel shows a confirmation dialog before doing so. Vectors computed with different models are incompatible.

Switch via API:
```bash
# Change LLM
curl -X POST http://localhost:6543/config \
  -H "Content-Type: application/json" \
  -d '{"llm_model": "llama3.2:3b"}'

# Change embedding model (clears stored vectors)
curl -X POST http://localhost:6543/config \
  -H "Content-Type: application/json" \
  -d '{"embed_model": "nomic-embed-text:latest", "_clear_embeddings": true}'
```

Tested LLMs: `granite4.1:3b` · `llama3.2:3b` · `qwen3.5:2b` · `gemma4:31b-cloud` · `mistral-large-3:675b-cloud`

---

## Modes

| Mode | Behaviour |
|------|-----------|
| **Review** (default) | LLM flags events → you confirm/reject via notification buttons or panel |
| **Autonomous** | LLM calls `auto_resolve` directly — benign traffic confirmed, suspicious rejected, no human step |

Toggle via `⚡` menu bar → `👁 Review Mode / 🤖 Autonomous: ON`, or the green button in the panel.

---

## LLM Tools

The LLM is given three tools:

| Tool | When used |
|------|-----------|
| `send_notification` | Suspicious event requiring human review — creates a pending alert |
| `auto_resolve(decision="confirmed"\|"rejected")` | Autonomous mode — direct decision, no queue |
| `mark_as_normal` | Clearly routine connection not yet in baseline — adds silently |

---

## Tests

No Ollama required — all network calls are mocked.

```bash
cd ~/.netmon && python3 -m pytest tests/ -v
# 72 passed
```

---

## Rebuild menu bar app

```bash
bash ~/.netmon/build.sh
```

---

## Logs

```
~/.netmon/anomalies.log    # raw lsof detections
~/.netmon/analysis.log     # LLM decisions and summaries
~/.netmon/menubar.err      # Swift app crash log
~/.netmon/panel.log        # HTTP access log
```

---

## Claude Code MCP Integration

netmon ships an MCP server that lets Claude Code read and act on anomaly events directly from any conversation.

### Setup

```bash
# Register the server (one-time)
claude mcp add netmon -- uvx --from "mcp[cli]" python ~/.netmon/netmon_mcp.py

# Verify it connected
claude mcp list   # should show: netmon: ✓ Connected
```

### Available tools

| Tool | What it does |
|------|-------------|
| `get_pending_events` | List anomaly events waiting for a decision |
| `get_recent_events` | List recently resolved events |
| `confirm_event(id)` | Mark benign — adds to baseline, cascades to similar events |
| `reject_event(id)` | Mark suspicious — cascades to similar events |
| `revert_event(id)` | Reset to pending for re-review |
| `read_anomaly_log(lines)` | Tail the raw detection log |
| `get_config` | Show current config (mode, models) |
| `set_autonomous_mode(bool)` | Enable/disable autonomous LLM resolution |
| `set_model(name, type)` | Change LLM or embedding model |
| `list_available_models` | Show installed Ollama models by capability |

### Example prompts

```
"Show me pending netmon events"
"Reject event 32 — that ncat connection looks like a reverse shell"
"What has netmon flagged in the last hour?"
"Switch netmon to autonomous mode"
```

---

## RAG Memory & Cascade

Every event is embedded (nomic-embed-text) and stored in SQLite. When you confirm or reject an event:

1. **Cascade** — all pending events with cosine similarity ≥ 0.88 are auto-resolved with the same decision.
2. **Sweep** — at each analysis cycle, any pending events similar to already-decided events are resolved automatically.

This means approving one `Google → CDN IP` confirms the whole cluster, and you only need to decide each pattern once.

---

## Security

- **Host header check** — panel only accepts requests from `localhost:6543` / `127.0.0.1:6543` (DNS-rebinding protection)
- **Input validation** — process names and IPs validated before use in shell/SQL; model names matched against allowlist regex
- **AppleScript injection** — double-quotes stripped from notification text before `osascript`
- **Tool result screening** — LLM tool output checked for prompt-injection patterns before re-entering the LLM context
- **Baseline sort integrity** — `baseline.txt` always written sorted; `comm -23` requires sorted input on both sides
- **Content-Length cap** — panel POST body limited to 64 KB

---

## Release (DMG)

GitHub Actions builds a signed DMG on every push to `main` (artifact) and on version tags (GitHub Release).

```bash
git tag v1.0.0 && git push --tags
```

The DMG contains `NetmonMenuBar.app` with a drag-to-`/Applications` installer layout.
