# ADR-003: Per-process expected-CIDR allowlist for AI agents

**Status:** Accepted  
**Date:** 2026-05

## Context

AI agent processes (Claude Code, Codex, Coder) are confirmed in the baseline like any other process. Once baselined, they can connect to any IP without triggering alerts. Given OWASP Top 10 for Agentic Apps (2026), a compromised or rogue agent silently connecting to a C2 server would be invisible.

## Decision

`process_policy.json` maps known agent process names to expected CIDR ranges. Any new connection from a listed process to an IP outside its ranges fires a critical `[POLICY_VIOLATION]` alert, bypassing the LLM entirely (same treatment as injection guard blocks).

Confirming a policy violation from the panel/notification automatically appends the specific IP as a `/32` entry to the process's `expected_cidrs` — so the operator explicitly expands the allowlist.

## Alternatives considered

- **HTTP proxy (mitmproxy)** — would see actual API endpoints but requires SSL interception and `HTTPS_PROXY` env var support in every agent. Deferred to a future ADR.
- **ASN-based matching** — query WHOIS per IP at runtime. Ruled out: adds latency, requires network access, ASN → process mapping is brittle.
- **Flag all new agent connections as critical regardless of CIDR** — too noisy; legitimate agents rotate IPs within known ASNs regularly.

## Consequences

- False positives possible when legitimate services add new IP ranges (e.g., Anthropic CDN expansion). Operator confirms once → `/32` added to policy.
- `process_policy.json` must be manually updated when new AI agent versions change their binary name (e.g., `2.1.119` → `2.1.120`). A future improvement could match on process path or a glob pattern.
