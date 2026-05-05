# Architecture

## System components

```mermaid
graph TB
    subgraph LaunchAgents ["launchd — background services"]
        MON["monitor.sh\n⏱ every 60 s"]
        ANA["analyze.py\n⏱ every 5 min"]
        HB["analyze.py --recheck\n⏱ every 60 s"]
        PAN["panel.py\n↻ persistent"]
        MB["NetmonMenuBar.app\n↻ persistent"]
    end

    subgraph Storage ["~/.netmon/ — flat files + SQLite"]
        LOG["anomalies.log"]
        DB[("netmon.db\nSQLite")]
        BASE["baseline.txt"]
        BLOCKED["blocked_ips.txt"]
        POLICY["process_policy.json"]
        CFG["config.json"]
        TOK["panel_token\nmode 0600"]
    end

    subgraph External ["External services"]
        OLL["Ollama\nlocalhost:11434"]
        PF["pf firewall\nkernel"]
    end

    LSOF["lsof -i 4"] -->|snapshot| MON
    MON -->|diff vs baseline| LOG
    LOG -->|unprocessed lines| ANA
    ANA <-->|embed + cosine search| DB
    ANA -->|triage result| DB
    ANA <-->|LLM + embeddings| OLL
    ANA -->|block IP| PF
    ANA -->|read| BASE
    ANA -->|read| POLICY
    ANA -->|read| CFG
    ANA -->|append| BASE
    DB -->|pending events| HB
    HB <-->|re-embed + re-triage| OLL
    PAN <-->|read/write| DB
    PAN <-->|read/write| BASE
    PAN <-->|read/write| BLOCKED
    PAN <-->|read/write| CFG
    PAN --- TOK
    MB <-->|HTTP + X-Netmon-Token| PAN
    MCP["netmon_mcp.py\nMCP server"] <-->|HTTP + X-Netmon-Token| PAN
```

---

## Detection data flow

```mermaid
sequenceDiagram
    participant lsof
    participant monitor.sh
    participant volume_check.py
    participant anomalies.log
    participant analyze.py
    participant Ollama
    participant netmon.db
    participant Notifications

    loop Every 60 seconds
        lsof->>monitor.sh: IPv4 connection snapshot
        monitor.sh->>monitor.sh: comm -23 vs baseline.txt
        monitor.sh->>anomalies.log: [ANOMALY] new pairs
        monitor.sh->>volume_check.py: trigger volume check
        volume_check.py->>volume_check.py: update connection_counts.json
        volume_check.py-->>anomalies.log: [VOLUME_ANOMALY] on spike
    end

    loop Every 5 minutes
        analyze.py->>anomalies.log: read unprocessed lines
        analyze.py->>analyze.py: injection guard (regex)
        analyze.py->>analyze.py: process policy check
        analyze.py->>Ollama: embed event text
        Ollama-->>analyze.py: float32 vector
        analyze.py->>netmon.db: cosine similarity search
        netmon.db-->>analyze.py: similar past events
        analyze.py->>Ollama: LLM triage (event + RAG context)
        Ollama-->>analyze.py: tool call
        analyze.py->>netmon.db: insert event record
        analyze.py-->>Notifications: macOS notification (if pending)
    end

    loop Every 60 seconds (heartbeat)
        analyze.py->>netmon.db: fetch pending events
        analyze.py->>Ollama: re-triage with latest RAG
        Ollama-->>analyze.py: updated decision
        analyze.py->>netmon.db: update event status
    end
```

---

## Decision pipeline

Every event from `anomalies.log` passes through six layers in strict order. Earlier layers are cheaper and can skip the rest.

```mermaid
flowchart TD
    IN([New anomaly line]) --> IG

    IG{1 · Injection Guard\nregex scan}
    IG -->|match| BLK1[🚫 BLOCKED\nCritical · no LLM\nPending queue]
    IG -->|clean| PP

    PP{2 · Process Policy\nCIDR check}
    PP -->|outside expected range| BLK2[🚨 POLICY_VIOLATION\nCritical · no LLM\nPending queue]
    PP -->|within range or not listed| BASE

    BASE{3 · Baseline Check\nknown pair?}
    BASE -->|yes| SKIP[✓ Silently skipped\nno DB entry]
    BASE -->|no| EMB

    EMB[4 · Embed event\nOllama /api/embed] --> RAG

    RAG[5 · RAG lookup\ncosine similarity > 0.88] -->|similar past decision found| AUTO[♻️ Reuse past decision]
    RAG -->|no match| LLM

    LLM[6 · LLM triage\nOllama tool call] --> TOOL

    TOOL{Tool called}
    TOOL -->|mark_as_normal| NORM[✓ Baseline entry\nDB: confirmed]
    TOOL -->|send_notification| PEND[⏳ Pending queue\nmacOS notification]
    TOOL -->|auto_resolve confirmed| CONF[✓ DB: confirmed\nBaseline entry]
    TOOL -->|auto_resolve rejected| REJ[🚫 DB: rejected\nIP blocked]
```

---

## Security model

- **Loopback-only** — panel binds to `127.0.0.1:6543`; no LAN exposure
- **Token auth** — all panel routes require `X-Netmon-Token` (timing-safe `secrets.compare_digest`)
- **No cloud by default** — all inference local via Ollama; cloud backend is explicit opt-in
- **AI agent protection** — process policy + injection guard target exfiltration and prompt injection specifically
- **Kernel enforcement** — optional pf anchor blocks rejected IPs at the network layer

## Alert severity matrix

| Tag | Severity | Routed via | LLM involved? |
|-----|----------|-----------|---------------|
| `[BLOCKED]` | Critical | Direct DB insert | No |
| `[POLICY_VIOLATION]` | Critical | Direct DB insert + notify | No |
| `[VOLUME_ANOMALY]` | Warning+ | LLM triage | Yes |
| `[ANOMALY]` | Info–Critical | LLM triage | Yes |
