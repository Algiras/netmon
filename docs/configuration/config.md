# config.json Reference

`~/.netmon/config.json` is created on first run with sensible defaults. Edit it directly or use the panel Settings tab / the `/config` API endpoint.

---

## Full reference

```json
{
  "llm_model":          "granite4.1:3b",
  "embed_model":        "nomic-embed-text-v2-moe",
  "autonomous":         false,
  "backend":            "ollama",
  "anthropic_api_key":  "",
  "pf_enforcement":     false,
  "volume_threshold":   3.0,
  "volume_window":      10
}
```

---

## Keys

### `llm_model`

**Type:** string  
**Default:** `"granite4.1:3b"`

The Ollama model used for LLM triage. Must support tool calling. The panel's model picker shows only tool-capable models from your local Ollama installation.

Tested models: `granite4.1:3b` · `llama3.2:3b` · `qwen3.5:2b` · `gemma4:31b-cloud` · `mistral-large-3:675b-cloud`

See [Models](models.md) for a comparison.

---

### `embed_model`

**Type:** string  
**Default:** `"nomic-embed-text-v2-moe"`

The Ollama model used to embed past events for RAG retrieval. Must support embedding. The panel shows only embedding-capable models.

!!! warning
    Changing this key clears all stored embeddings — past events are re-embedded on the next analyze run. The panel shows a confirmation dialog before applying.

---

### `autonomous`

**Type:** boolean  
**Default:** `false`

When `true`, the LLM calls `auto_resolve` instead of `send_notification`. See [Review vs Autonomous](../user-guide/modes.md).

---

### `backend`

**Type:** `"ollama"` | `"claude"`  
**Default:** `"ollama"`

Which LLM backend to use for triage.

- **`ollama`** — fully local, zero data egress, uses `llm_model`
- **`claude`** — Anthropic API, higher quality but process names/IPs/summaries leave the device

!!! danger "Claude backend sends data to Anthropic"
    When `backend` is `"claude"`, process names, IP addresses, event summaries, and past-event RAG context are sent to the Anthropic API on every triage cycle. The panel shows an orange warning banner when this is active.

To use the Claude backend, also set `anthropic_api_key`.

---

### `anthropic_api_key`

**Type:** string  
**Default:** `""`

Required when `backend` is `"claude"`. Your Anthropic API key.

---

### `pf_enforcement`

**Type:** boolean  
**Default:** `false`

When `true` and the pf anchor is configured, rejected IPs are added to the pf firewall ruleset and blocked at the kernel level. Requires running `~/.netmon/setup-pf.sh` once to configure sudo permissions.

See [IP Blocking & pf](../security/ip-blocking.md).

---

### `volume_threshold`

**Type:** float  
**Default:** `3.0`

A connection's count must exceed `volume_threshold × rolling_average` to trigger a volume anomaly. Lower values = more sensitive; higher = fewer false positives.

---

### `volume_window`

**Type:** integer  
**Default:** `10`

Number of recent samples used to compute the rolling average for volume anomaly detection. Each sample is one monitor.sh run (60 seconds), so the default window covers the last 10 minutes.

---

## Updating via API

```bash
TOKEN=$(cat ~/.netmon/panel_token)

curl -X POST http://localhost:6543/config \
  -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"llm_model": "llama3.2:3b", "autonomous": true}'
```

Partial updates are accepted — only the supplied keys are changed.

### Special: clearing embeddings when changing embed model

```bash
curl -X POST http://localhost:6543/config \
  -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"embed_model": "nomic-embed-text:latest", "_clear_embeddings": true}'
```

The `_clear_embeddings: true` flag tells the server to wipe the embedding column before saving. Without it, mismatched embeddings will corrupt RAG results.
