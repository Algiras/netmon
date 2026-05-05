# Injection Guard

The injection guard is netmon's defence against **prompt injection attacks** — attempts by malicious content in a connection payload or process environment to hijack the triage LLM.

If netmon is analysing traffic from an AI agent that processed hostile input, the hostile content could end up in the anomaly log and then in the LLM's triage context. Without the injection guard, the attacker could manipulate netmon's LLM into auto-confirming a malicious connection or leaking information.

---

## How it works

Before the assembled triage context is sent to the LLM, `analyze.py` runs it through the injection guard:

### Stage 1 — Regex scan

A set of patterns checked against the context string:

```python
INJECTION_PATTERNS = [
    r"ignore previous instructions",
    r"disregard (?:all )?(?:previous|prior|above)",
    r"you are now",
    r"new instructions?:",
    r"system prompt",
    r"<\|.*?\|>",           # special token patterns
    r"\[INST\]",            # Llama instruction tags
    r"### ?(?:Human|Assistant|System):",
]
```

If any pattern matches, the event is flagged as `[BLOCKED]` — a Critical severity injection attempt — and is **not sent to the LLM**.

### Stage 2 — Optional LLM scan

When `injection_llm_check: true` is set in `config.json`, a second, smaller LLM call checks the context for subtle injection attempts that regex misses. This uses the same `llm_model` but with a minimal classification prompt.

---

## What happens on detection

An injection attempt event is inserted directly into the database as:

- **Type:** `[BLOCKED]`
- **Severity:** Critical
- **Summary:** `"Potential prompt injection detected in triage context"`
- **Status:** Pending (requires human review)

It appears in the Pending tab with an orange badge. You can Confirm (log and ignore) or Reject (flag and block the remote IP).

---

## Limitations

The injection guard operates on the **assembled context string** — it can detect injections that appear verbatim in the anomaly log. It cannot:

- Detect semantically obfuscated injections (e.g., base64-encoded or split across multiple events)
- Inspect encrypted payloads
- Protect against injections in tool call *responses* (only the input context is scanned)

For AI agent processes, the [Process Policy](../configuration/process-policy.md) layer provides a complementary control that doesn't rely on content inspection.

---

## Configuring the LLM scan

```json
{
  "injection_llm_check": true
}
```

Adds ~1–2 seconds per triage cycle. Recommended when running high-value AI agent workloads.
