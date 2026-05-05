# Security Features Overview

netmon is built around the idea that network visibility is a security primitive. It layers multiple independent detection mechanisms so that no single failure mode lets unexpected traffic go unnoticed.

---

## Defence layers

```
Incoming lsof event
        │
        ▼
┌───────────────────────┐
│  1. Injection Guard   │  regex + optional LLM scan on assembled context
└───────────┬───────────┘
            │ pass
            ▼
┌───────────────────────┐
│  2. Process Policy    │  expected CIDR check — no LLM, instant Critical alert
└───────────┬───────────┘
            │ pass
            ▼
┌───────────────────────┐
│  3. Volume Anomaly    │  spike detection on connection count rolling average
└───────────┬───────────┘
            │ flagged events fed to LLM
            ▼
┌───────────────────────┐
│  4. Baseline Check    │  known-safe pairs silently skipped
└───────────┬───────────┘
            │ new pairs
            ▼
┌───────────────────────┐
│  5. LLM Triage        │  RAG-assisted analysis → tool call decision
└───────────┬───────────┘
            │ rejected
            ▼
┌───────────────────────┐
│  6. IP Blocking       │  blocked_ips.txt + optional pf enforcement
└───────────────────────┘
```

---

## Layer summary

| # | Layer | Docs | Bypasses LLM? |
|---|-------|------|--------------|
| 1 | [Injection Guard](injection-guard.md) | Regex scan on assembled triage context | No (but blocks before LLM sees it) |
| 2 | [Process Policy](../configuration/process-policy.md) | Per-process expected CIDR ranges | Yes — instant Critical |
| 3 | [Volume Anomaly](volume-anomaly.md) | Rolling count spike detection | No — feeds into LLM |
| 4 | [Baseline](baseline.md) | Known-safe process×IP pairs | Yes — silently skipped |
| 5 | LLM Triage | RAG + tool calls | — |
| 6 | [IP Blocking & pf](ip-blocking.md) | Reject → block, optional kernel enforcement | — |

---

## Threat model

netmon is designed for **local network visibility on a personal Mac**. It addresses:

- Unexpected connections from any process (malware, supply-chain)
- AI agent exfiltration via prompt injection (process policy)
- Silently growing connection volume from compromised processes (volume anomaly)
- Prompt injection into the triage LLM itself (injection guard)
- Persistent access from previously seen malicious IPs (IP blocking)

It does **not** address:
- Encrypted payload inspection
- Inbound connections (only outbound TCP/UDP via lsof)
- DNS-based exfiltration
- Lateral movement within a LAN
- Kernel-level rootkits (those can hide from lsof)
