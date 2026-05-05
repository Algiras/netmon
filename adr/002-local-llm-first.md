# ADR-002: Local LLM (Ollama) as default backend

**Status:** Accepted  
**Date:** 2026-05

## Context

The triage step sends network anomaly context (process names, IPs, past events) to an LLM. Options: always cloud (Anthropic/OpenAI), always local (Ollama), or switchable.

## Decision

Default to Ollama (local). Claude (Anthropic API) is an optional backend selectable via `config.json` `"backend": "claude"`.

## Rationale

- **Privacy** — network activity logs should not leave the machine by default
- **No API cost** — monitor runs every 60 s; cloud calls at that rate would be expensive
- **Works offline** — LAN/home network monitoring must function without internet

## Consequences

- Local model quality is lower than Claude — acceptable for binary confirm/reject triage
- Ollama must be installed; autonomous mode is gated on Ollama being reachable
- Claude backend added later as an opt-in for users who prefer quality over privacy
