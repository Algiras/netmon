# Models

netmon uses two separate models with distinct roles. Both are configurable from the Settings tab or `config.json`.

---

## LLM model (triage + tool calls)

The LLM reads each anomaly, retrieves similar past events via RAG, and decides what to do by calling one of three tools: `send_notification`, `auto_resolve`, or `mark_as_normal`.

**Requirements:** must support Ollama's tool-calling interface (`/api/chat` with `tools` parameter).

### Tested models

| Model | Size | Notes |
|-------|------|-------|
| `granite4.1:3b` | ~2 GB | Default. Fast, good tool reliability on Apple Silicon |
| `llama3.2:3b` | ~2 GB | Good alternative; slightly better reasoning |
| `qwen3.5:2b` | ~1.5 GB | Lighter; acceptable for simple traffic |
| `gemma4:31b-cloud` | ~20 GB | Much higher accuracy; needs 32+ GB RAM |
| `mistral-large-3:675b-cloud` | ~400 GB | Best quality; requires a very powerful machine or cloud offload |

### Changing the LLM

From the panel: **Settings → Model dropdown**.

From the API:
```bash
TOKEN=$(cat ~/.netmon/panel_token)
curl -X POST http://localhost:6543/config \
  -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"llm_model": "llama3.2:3b"}'
```

---

## Embedding model (RAG memory)

The embedding model converts past events and new anomalies into vectors. Cosine similarity above 0.88 between a new event and a past event allows netmon to reuse the past decision — without an extra LLM call.

**Requirements:** must support Ollama's embedding interface (`/api/embed`).

### Tested models

| Model | Size | Notes |
|-------|------|-------|
| `nomic-embed-text-v2-moe` | ~500 MB | Default. MoE architecture, fast and accurate |
| `nomic-embed-text:latest` | ~300 MB | Lighter; slightly less accurate |
| `mxbai-embed-large` | ~700 MB | Alternative; strong multilingual performance |

### Changing the embedding model

!!! warning "This clears all stored embeddings"
    Past events are re-embedded on the next analyze run, so RAG lookups may be weaker for the first cycle after a change.

From the panel: **Settings → Memory Model dropdown** (shows a confirmation dialog).

From the API:
```bash
TOKEN=$(cat ~/.netmon/panel_token)
curl -X POST http://localhost:6543/config \
  -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"embed_model": "nomic-embed-text:latest", "_clear_embeddings": true}'
```

---

## Claude API backend

Instead of a local Ollama LLM, you can use the Anthropic Claude API for triage. The embedding model always stays local.

```json
{
  "backend": "claude",
  "anthropic_api_key": "sk-ant-..."
}
```

!!! danger "Data leaves your device"
    When using the Claude backend, process names, IP addresses, event summaries, and RAG context are sent to Anthropic's API on every triage. The panel displays a prominent orange warning when this is active.

Claude backend is useful when:
- Local models produce too many false positives or poor tool calls
- You want the highest-quality analysis and privacy is less of a concern
- You're investigating a specific incident and need deeper reasoning

---

## Pulling new models

```bash
ollama pull llama3.2:3b
ollama pull mxbai-embed-large
```

New models appear in the panel dropdowns automatically after pulling.
