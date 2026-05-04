# netmon

Local network anomaly monitor for macOS — detects suspicious outbound connections using a local LLM with tool calling, RAG short-term memory, a menu bar agent, and a web review panel.

## How it works

```
lsof (every 60s) → anomalies.log → LLM analyzer (every 5 min) → notifications + panel
```

1. **monitor.sh** — diffs `lsof -i 4` against a known-good baseline every 60 s; writes new connections to `anomalies.log`
2. **analyze.py** — reads new anomalies, embeds each with `nomic-embed-text-v2-moe`, retrieves similar past events (RAG), then calls a local Ollama LLM with tool calling to decide: alert, confirm, or reject
3. **panel.py** — web UI at `http://localhost:6543` for reviewing/confirming/rejecting flagged events
4. **NetmonMenuBar** — macOS menu bar app showing `⚡ N` badge for pending alerts; inline confirm/reject; Autonomous Mode toggle

## Requirements

- macOS 13+
- [Ollama](https://ollama.com) with at least one tool-capable model
- Python 3.10+ (Homebrew recommended)
- Xcode Command Line Tools (`xcode-select --install`)

## Install

```bash
git clone https://github.com/Algiras/netmon ~/.netmon
bash ~/.netmon/install.sh
```

`install.sh` pulls the default models, writes LaunchAgent plists, and builds the Swift menu bar app. All four agents start at login automatically via `RunAtLoad`.

## Models

Any Ollama model with tool-calling support works. Default: `granite4.1:3b`.

Switch model in the panel UI or via:
```bash
curl -X POST http://localhost:6543/config \
  -H "Content-Type: application/json" \
  -d '{"model": "llama3.2:3b"}'
```

Tested models: `granite4.1:3b`, `llama3.2:3b`, `qwen3.5:2b`, `gemma4:31b-cloud`, `mistral-large-3:675b-cloud`

## Modes

| Mode | Behaviour |
|------|-----------|
| **Review** (default) | LLM flags events → you confirm/reject in panel or notification |
| **Autonomous** | LLM auto-confirms benign traffic and auto-rejects suspicious — no human needed per event |

Toggle via the `⚡` menu bar icon or the panel button.

## Files

| File | Purpose |
|------|---------|
| `monitor.sh` | Polls `lsof`, writes anomalies |
| `analyze.py` | LLM analysis loop with RAG |
| `db.py` | SQLite event store + cosine similarity search |
| `embed.py` | Ollama embedding wrapper |
| `panel.py` | HTTP review panel |
| `MenuBar/` | Swift menu bar app source |
| `build.sh` | Compile Swift + reload LaunchAgents |
| `install.sh` | First-time setup |
| `tests/` | Unit tests (no Ollama required) |

## Tests

```bash
cd ~/.netmon && python3 -m pytest tests/ -v
```

## Rebuild menu bar app

```bash
bash ~/.netmon/build.sh
```

## Logs

```
~/.netmon/anomalies.log   # raw detections
~/.netmon/analysis.log    # LLM decisions
~/.netmon/panel.log       # panel access
~/.netmon/menubar.err     # Swift app errors
```
