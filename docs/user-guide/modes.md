# Review vs Autonomous Mode

netmon has two operating modes that control how events are resolved.

---

## Review mode (default)

In Review mode, the LLM flags events but **you make the final call**.

```
new connection
    └── LLM triage
            ├── mark_as_normal   → silently added to baseline (no alert)
            └── send_notification → pending queue + macOS notification
                    └── You: Confirm or Reject
```

**Use Review mode when:**
- You want full visibility into what's happening on your network
- You're investigating a specific process or IP
- You've just installed netmon and want to audit the initial baseline
- The machine is handling sensitive work and you want human oversight

---

## Autonomous mode

In Autonomous mode, the LLM resolves events **without human review**.

```
new connection
    └── LLM triage
            ├── mark_as_normal     → silently added to baseline
            └── auto_resolve       → confirmed or rejected directly
                    ├── confirmed  → added to baseline
                    └── rejected   → IP flagged (+ blocked if pf enabled)
```

**Use Autonomous mode when:**
- The baseline is stable and alerts are mostly routine
- You want to run netmon passively in the background
- You're away from your machine and want protection without noise
- You trust the LLM model's judgment for your typical traffic

!!! warning "Autonomous mode bypasses human review"
    In Autonomous mode, suspicious connections are rejected and IPs blocked without your confirmation. False positives can disrupt connectivity. Start with Review mode until you're confident in the baseline.

---

## Switching modes

**From the panel** — click the **Auto** button in the panel header. It toggles between `👁 Review` and `🤖 Auto`.

**From the API:**

```bash
TOKEN=$(cat ~/.netmon/panel_token)

# Enable autonomous
curl -X POST http://localhost:6543/config \
  -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"autonomous": true}'

# Back to review
curl -X POST http://localhost:6543/config \
  -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"autonomous": false}'
```

The mode is persisted in `~/.netmon/config.json` and survives restarts.

---

## How the LLM decides in each mode

The LLM receives the same context regardless of mode: the event details, RAG-retrieved past decisions, and the current baseline. The only difference is which tools are available:

| Tool | Review mode | Autonomous mode |
|------|-------------|-----------------|
| `send_notification` | Available | Not available |
| `auto_resolve` | Not available | Available |
| `mark_as_normal` | Available | Available |

In Review mode, the LLM must use `send_notification` for anything suspicious. In Autonomous mode, it calls `auto_resolve(decision="confirmed")` or `auto_resolve(decision="rejected")` directly.
