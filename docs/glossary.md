# Glossary

**Anomaly**
:   A network connection from a process to a remote IP:port that is not in the baseline. Every new connection starts as an anomaly until the LLM or the user classifies it.

**Autonomous mode**
:   An operating mode where the LLM resolves events without human review. The LLM calls `auto_resolve` directly instead of `send_notification`. See [Review vs Autonomous](user-guide/modes.md).

**Baseline**
:   The list of known-safe `process|IP:port` pairs stored in `~/.netmon/baseline.txt`. Baselined connections are silently skipped by `monitor.sh` and never reach the LLM.

**CIDR**
:   Classless Inter-Domain Routing notation for IP address ranges. `34.0.0.0/8` means all IPs from `34.0.0.0` to `34.255.255.255`. Used in process policy to declare expected IP ranges.

**Cosine similarity**
:   A measure of how similar two vectors are, regardless of their magnitude. netmon uses cosine similarity to compare the embedding of a new event against stored past events. Threshold is **0.88** — events above this score reuse the past decision without a new LLM call.

**Embedding**
:   A list of floating-point numbers (a vector) that encodes the semantic meaning of a text. netmon uses `nomic-embed-text-v2-moe` (via Ollama) to embed event descriptions. Similar events produce similar vectors.

**Heartbeat**
:   The `analyze.py --recheck` process that runs every 60 seconds. It re-evaluates all pending events with updated RAG context. Events that the LLM was uncertain about during the main cycle often resolve within a few minutes via heartbeat.

**Injection guard**
:   A pre-triage filter that scans the assembled context for prompt injection patterns before the LLM sees it. Prevents hostile content in connection metadata from hijacking the triage AI.

**LaunchAgent**
:   A macOS background service defined by a `.plist` file in `~/Library/LaunchAgents/`. netmon installs five LaunchAgents: monitor, analyze, heartbeat, panel, and menubar.

**LLM (Large Language Model)**
:   The AI model that classifies network events. netmon uses Ollama to run the LLM locally. The LLM is given three tools (`send_notification`, `auto_resolve`, `mark_as_normal`) and chooses which to call based on the event context.

**MCP (Model Context Protocol)**
:   An open protocol for connecting AI assistants to external tools and data sources. netmon's `netmon_mcp.py` implements an MCP server that exposes network events and actions to Claude Code or Claude Desktop.

**Ollama**
:   An open-source tool for running large language models locally on macOS (and other platforms). netmon uses Ollama for both the triage LLM and the embedding model. Available at [ollama.com](https://ollama.com).

**pf (Packet Filter)**
:   The macOS kernel-level firewall. When pf enforcement is enabled, rejected IPs are added to a pf anchor and blocked at the network layer — no process can reach them.

**Process policy**
:   A per-process allowlist of expected CIDR ranges stored in `process_policy.json`. Connections outside the declared ranges trigger a Critical violation immediately, bypassing the LLM.

**RAG (Retrieval-Augmented Generation)**
:   A technique where relevant past context is retrieved from a store and included in the LLM prompt. netmon retrieves the 3 most similar past events (by cosine similarity) and includes their decisions in every triage prompt.

**Review mode**
:   The default operating mode where the LLM flags suspicious events for human review. The LLM calls `send_notification`, which creates a macOS notification with Confirm/Reject buttons.

**Tool calling**
:   A capability where an LLM can invoke predefined functions instead of (or in addition to) returning text. netmon's LLM is given three tools and must call one of them — this is what makes the triage structured and actionable.

**Volume anomaly**
:   An alert triggered when a connection's count exceeds `volume_threshold × rolling_average` within the `volume_window`. Catches data exfiltration that uses repeated connections to a known-safe endpoint.
