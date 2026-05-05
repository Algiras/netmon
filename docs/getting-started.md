# Installation

## Requirements

| Requirement | Notes |
|-------------|-------|
| **macOS 13 Ventura or later** | Apple Silicon or Intel |
| **[Ollama](https://ollama.com)** | At least one tool-capable model |
| **Python 3.10+** | Homebrew recommended: `brew install python` |
| **Xcode Command Line Tools** | `xcode-select --install` |

!!! note "Disk space"
    The default models take about 3–4 GB:
    `granite4.1:3b` (~2 GB) and `nomic-embed-text-v2-moe` (~500 MB).

---

## One-line install

```bash
git clone https://github.com/Algiras/netmon ~/.netmon
bash ~/.netmon/install.sh
```

`install.sh` does everything in order:

1. **Checks dependencies** — python3, ollama, xcrun
2. **Pulls Ollama models** — `granite4.1:3b` (LLM) and `nomic-embed-text-v2-moe` (embeddings)
3. **Installs Python packages** — `anthropic`, `mcp`
4. **Writes LaunchAgent plists** — seven background agents under `~/Library/LaunchAgents/`
5. **Configures sudoers** — writes `/etc/sudoers.d/netmon` (least-privilege entries for pfctl and tcpdump)
6. **Builds the Swift menu bar app** — compiles and installs to `/Applications/NetmonMenuBar.app`
7. **Loads all agents** — starts everything via `launchctl`

---

## What gets installed

### LaunchAgents (background services)

| Label | What it runs | Interval |
|-------|-------------|---------|
| `com.user.netmon` | `monitor.sh` — lsof snapshot + diff | every 60 s |
| `com.user.netmon.analyze` | `analyze.py` — LLM triage | every 5 min |
| `com.user.netmon.heartbeat` | `analyze.py --recheck` — recheck pending events | every 60 s |
| `com.user.netmon.dns` | `dns_monitor.py` — DNS exfiltration detection | persistent |
| `com.user.netmon.panel` | `panel.py` — local HTTP API server | persistent |
| `com.user.netmon.menubar` | `NetmonMenuBar.app` | persistent |
| `com.user.netmon.watchdog` | `watchdog.sh` — alert if services stop | every 5 min |

### Files written to `~/.netmon/`

| File | Purpose |
|------|---------|
| `anomalies.log` | Raw lsof detections |
| `analysis.log` | LLM decisions and summaries |
| `netmon.db` | SQLite event store + RAG embeddings |
| `baseline.txt` | Confirmed-safe process×IP pairs |
| `baseline.sha256` | SHA256 checksum for tamper detection (mode 0600) |
| `panel_token` | 64-char auth token for the panel API (mode 0600) |
| `config.json` | User settings (mode 0600) |
| `connection_counts.json` | Rolling connection counts for volume anomaly detection |
| `/etc/sudoers.d/netmon` | Least-privilege sudo rules for pfctl and tcpdump |

---

## Verifying the install

```bash
~/.netmon/verify.sh
```

Expected output:

```
✓ monitor agent running
✓ panel server up (localhost:6543)
✓ ollama running
✓ LLM model present (granite4.1:3b)
✓ embed model present (nomic-embed-text-v2-moe)
```

---

## Uninstall

```bash
for plist in ~/Library/LaunchAgents/com.user.netmon*.plist; do
    launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
done
rm -f ~/Library/LaunchAgents/com.user.netmon*.plist
sudo rm -f /etc/sudoers.d/netmon
rm -rf /Applications/NetmonMenuBar.app
rm -rf ~/.netmon
```

---

## Next step

Continue to [First Run](first-run.md) to understand what happens in the first few minutes after install.
