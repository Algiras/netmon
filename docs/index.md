# netmon

**Local network anomaly monitor for macOS** — AI-assisted triage, fully private by default.

netmon watches every outbound connection your Mac makes, compares them against a learned baseline, and flags anything unexpected. A local LLM (running in Ollama) decides whether each new connection is suspicious, routine, or worth adding to the baseline — with no data leaving your machine unless you explicitly switch to the Claude cloud backend.

---

## What it looks like

![netmon panel — pending event](assets/screenshots/panel-pending.png)

The review panel shows pending alerts with full details and one-click Confirm / Reject buttons. Every decision is stored and used to make future triage smarter.

---

## How it works

```
lsof (every 60 s)
    └── diff vs baseline.txt
            └── [ANOMALY] lines → anomalies.log
                    └── analyze.py (every 5 min)
                            ├── injection guard
                            ├── process policy check
                            ├── RAG lookup (past similar events)
                            └── Ollama LLM triage
                                    ├── send_notification  → pending queue
                                    ├── auto_resolve       → autonomous mode
                                    └── mark_as_normal     → baseline
```

---

## Key features

| Feature | Detail |
|---------|--------|
| **Baseline learning** | Known-safe process×IP pairs are silently skipped |
| **LLM triage** | Tool-calling LLM classifies each new connection |
| **RAG memory** | Past decisions retrieved by embedding similarity — no repeat prompting |
| **Review mode** | You approve or reject each alert via notifications or the panel |
| **Autonomous mode** | LLM decides autonomously — no human step required |
| **Process policy** | Per-process expected CIDR ranges; violations skip LLM entirely |
| **Volume anomaly** | Spike detection on connection counts, even for baselined pairs |
| **IP blocking** | Reject an event → IP blocked; optional pf firewall enforcement |
| **Injection guard** | Regex + optional LLM scan before AI triage to detect prompt injection |
| **MCP server** | Claude Code / Claude Desktop can query and act on events directly |

---

## Everything runs on-device

The default setup uses **Ollama** for both the LLM and the embedding model — zero cloud API calls, zero data leaving your Mac. An optional Claude API backend is available for higher-quality analysis; when active, the panel shows a clear warning.

---

## Quick start

```bash
git clone https://github.com/Algiras/netmon ~/.netmon
bash ~/.netmon/install.sh
```

After about two minutes you'll see `⚡` in your menu bar. Head to [Getting Started](getting-started.md) for the full install walkthrough.
