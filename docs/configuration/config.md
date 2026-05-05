# config.json Reference

`~/.netmon/config.json` is created on first run with sensible defaults. Edit it directly, use the panel Settings tab, or use the `/config` API endpoint.

---

## All keys

```json
{
  "llm_model":             "granite4.1:3b",
  "embed_model":           "nomic-embed-text-v2-moe",
  "autonomous":            false,
  "backend":               "ollama",
  "anthropic_api_key":     "",
  "pf_enforcement":        false,
  "volume_threshold":      3.0,
  "volume_window":         10,
  "injection_llm_check":   false
}
```

---

## Key reference

### `llm_model`
**Type:** string · **Default:** `"granite4.1:3b"`

The Ollama model used for triage. Must support tool calling. The panel's model picker shows only tool-capable models.

### `embed_model`
**Type:** string · **Default:** `"nomic-embed-text-v2-moe"`

The Ollama model used to embed past events for RAG retrieval. Must support embedding.

!!! warning "Changing embed_model clears all stored embeddings"
    Vectors from different models are incompatible. Pass `"_clear_embeddings": true` in the same config update, or use the panel dialog.

### `autonomous`
**Type:** boolean · **Default:** `false`

When `true`, the LLM calls `auto_resolve` instead of `send_notification`. No human review step. See [Review vs Autonomous](../user-guide/modes.md).

### `backend`
**Type:** `"ollama"` | `"claude"` · **Default:** `"ollama"`

Which LLM backend to use.

!!! danger "Claude backend sends data to Anthropic"
    Process names, IPs, event summaries, and RAG context are sent to the Anthropic API on every triage. The panel shows an orange warning banner when active. Set `anthropic_api_key` as well.

### `anthropic_api_key`
**Type:** string · **Default:** `""`  Required when `backend: "claude"`.

### `pf_enforcement`
**Type:** boolean · **Default:** `false`

When `true` and the pf anchor is configured, rejected IPs are blocked at the kernel level. Requires running `setup-pf.sh` first.

### `volume_threshold`
**Type:** float · **Default:** `3.0`

A connection's count must exceed `threshold × rolling_average` to trigger a volume anomaly.

| Value | Sensitivity |
|-------|------------|
| `2.0` | High — flags 2× spikes; more false positives |
| `3.0` | Default — flags 3× spikes |
| `5.0` | Low — only extreme spikes; fewer false positives |

### `volume_window`
**Type:** integer · **Default:** `10`

Number of 60-second samples in the rolling average. Default = last 10 minutes.

### `injection_llm_check`
**Type:** boolean · **Default:** `false`

When `true`, adds a second LLM pass to the injection guard for subtle attacks that regex misses. Adds ~1–2 s per triage cycle. Recommended when running high-value AI agent workloads. See [Injection Guard](../security/injection-guard.md).

---

## Config scenarios

=== "Default (local, review)"

    ```json
    {
      "llm_model": "granite4.1:3b",
      "embed_model": "nomic-embed-text-v2-moe",
      "autonomous": false,
      "backend": "ollama"
    }
    ```
    Fully local. You review every alert.

=== "Autonomous + pf enforcement"

    ```json
    {
      "llm_model": "granite4.1:3b",
      "autonomous": true,
      "pf_enforcement": true
    }
    ```
    LLM decides, firewall enforces. Set this after your baseline is stable.

=== "High-security AI agent workstation"

    ```json
    {
      "llm_model": "llama3.2:3b",
      "autonomous": false,
      "pf_enforcement": true,
      "injection_llm_check": true,
      "volume_threshold": 2.0,
      "volume_window": 5
    }
    ```
    Manual review, strict volume detection, LLM injection scanning. Best when running Claude Code, Cursor, or other AI agents.

=== "Maximum privacy (local only)"

    ```json
    {
      "backend": "ollama",
      "anthropic_api_key": ""
    }
    ```
    Explicitly ensures no Anthropic API calls. Pair with Ollama running in airplane mode for full air-gap.

---

## Updating via API

```bash
TOKEN=$(cat ~/.netmon/panel_token)

# Partial update — only supplied keys change
curl -X POST http://localhost:6543/config \
  -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"llm_model": "llama3.2:3b", "autonomous": true}'

# Change embedding model and clear stored vectors
curl -X POST http://localhost:6543/config \
  -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"embed_model": "nomic-embed-text:latest", "_clear_embeddings": true}'
```
