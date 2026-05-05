# API Reference

The panel server runs at `http://localhost:6543` and accepts only connections from `localhost`/`127.0.0.1`. Every request must include two headers:

```
Host: localhost:6543
X-Netmon-Token: <token>
```

The token is at `~/.netmon/panel_token`. Set it once in your shell session:

```bash
TOKEN=$(cat ~/.netmon/panel_token)
```

All responses are JSON. Errors return `{"error": "<message>"}` with an appropriate HTTP status code.

---

## GET /api/events

Returns pending events, recent history, and the current config in one call (used by the panel on load).

```bash
curl -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
     http://localhost:6543/api/events
```

**Response:**

```json
{
  "pending": [
    {
      "id": 932,
      "process": "2.1.119",
      "remote": "198.51.100.7:443",
      "summary": "Claude Code connected to unexpected endpoint...",
      "severity": "critical",
      "type": "policy_violation",
      "status": "pending",
      "created_at": "2026-05-05T17:02:24"
    }
  ],
  "recent": [ ... ],
  "config": { ... }
}
```

---

## GET /api/config

Returns the current `config.json` contents.

```bash
curl -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
     http://localhost:6543/api/config
```

---

## GET /api/models

Returns available Ollama models grouped by capability, plus the current config.

```bash
curl -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
     http://localhost:6543/api/models
```

**Response:**

```json
{
  "llm_models": ["granite4.1:3b", "llama3.2:3b"],
  "embed_models": ["nomic-embed-text-v2-moe:latest"],
  "config": { ... }
}
```

---

## GET /api/baseline

Returns all entries in `baseline.txt`.

```bash
curl -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
     http://localhost:6543/api/baseline
```

**Response:**

```json
{
  "entries": [
    {"entry": "node|52.207.53.37:443", "process": "node", "remote": "52.207.53.37:443"}
  ],
  "count": 480
}
```

---

## GET /api/blocked-ips

Returns all blocked IPs with metadata.

```bash
curl -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
     http://localhost:6543/api/blocked-ips
```

**Response:**

```json
{
  "ips": [
    {
      "ip": "198.51.100.7",
      "reason": "Process Policy Violation — unexpected endpoint",
      "blocked_at": "2026-05-05T17:02:24",
      "process": "2.1.119"
    }
  ]
}
```

---

## GET /api/pf-status

Returns pf firewall enforcement status.

```bash
curl -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
     http://localhost:6543/api/pf-status
```

**Response:**

```json
{
  "sudoers_configured": true,
  "anchor_configured": true,
  "enforcement_active": true,
  "pf_enforcement": true,
  "setup_script": "/Users/you/.netmon/setup-pf.sh"
}
```

---

## GET /api/process-policy

Returns the current `process_policy.json` contents (without the `_comment` key).

```bash
curl -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
     http://localhost:6543/api/process-policy
```

---

## POST /action

Confirm or reject a pending event.

```bash
# Confirm
curl -X POST http://localhost:6543/action \
  -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"id": 932, "action": "confirm"}'

# Reject
curl -X POST http://localhost:6543/action \
  -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"id": 932, "action": "reject"}'

# Confirm and also block IP
curl -X POST http://localhost:6543/action \
  -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"id": 932, "action": "confirm", "block_ip": true}'
```

**Response:** `{"status": "ok"}`

---

## POST /config

Update one or more config values. Partial updates are accepted.

```bash
curl -X POST http://localhost:6543/config \
  -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"autonomous": true, "llm_model": "llama3.2:3b"}'
```

Special flag: `"_clear_embeddings": true` — clears all stored RAG embeddings (use when changing `embed_model`).

**Response:** `{"status": "ok"}`

---

## POST /baseline/remove

Remove a specific entry from `baseline.txt`.

```bash
curl -X POST http://localhost:6543/baseline/remove \
  -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"entry": "node|52.207.53.37:443"}'
```

**Response:** `{"status": "ok"}`

---

## POST /unblock-ip

Remove an IP from `blocked_ips.txt` and regenerate the pf anchor.

```bash
curl -X POST http://localhost:6543/unblock-ip \
  -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"ip": "198.51.100.7"}'
```

**Response:** `{"status": "ok"}`

---

## POST /recheck

Trigger `analyze.py --recheck` to re-evaluate all pending events.

```bash
curl -X POST http://localhost:6543/recheck \
  -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN"
```

**Response:** `{"status": "ok"}`

---

## Authentication

All endpoints return `401 {"error":"unauthorized"}` if:

- The `Host` header is not `localhost:6543` or `127.0.0.1:6543`
- The `X-Netmon-Token` header is missing or incorrect

The server uses `secrets.compare_digest` for timing-safe token comparison.
