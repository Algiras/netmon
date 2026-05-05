# Process Policy

`~/.netmon/process_policy.json` defines expected CIDR ranges per process. Connections outside the declared ranges are flagged as **Process Policy Violations** — bypassing the LLM entirely and going straight to the pending queue as Critical severity.

This is designed for AI agent processes (Claude Code, Cursor, Copilot, etc.) that should only talk to known endpoints. A violation means the agent is connecting somewhere unexpected — a strong signal of prompt injection, supply-chain compromise, or exfiltration.

---

## Format

```json
{
  "_comment": "process_name (as shown by lsof) → list of allowed CIDRs",
  "2.1.119": [
    "160.79.104.0/24",
    "34.0.0.0/8",
    "35.0.0.0/8",
    "76.76.21.0/24",
    "64.239.123.0/24"
  ],
  "node": [
    "0.0.0.0/0"
  ]
}
```

### Rules

- **Key** — process name exactly as reported by `lsof -i 4` in the `COMMAND` column (usually truncated to 15 chars)
- **Value** — list of allowed CIDR strings. Use `"0.0.0.0/0"` to allow any IPv4 (effectively disables policy for that process)
- Processes not listed in the policy file are subject to normal LLM triage only

---

## Example: Claude Code

Claude Code's process name in lsof is typically `2.1.119` (the Electron wrapper version). It should only talk to Anthropic's infrastructure and its CDN:

```json
{
  "2.1.119": [
    "160.79.104.0/24",
    "34.0.0.0/8",
    "35.0.0.0/8",
    "76.76.21.0/24",
    "64.239.123.0/24"
  ]
}
```

If Claude Code ever connects to an unexpected IP (e.g., an attacker's exfiltration server injected via a prompt), netmon fires a Critical Process Policy Violation immediately.

---

## Finding your process names

```bash
# Show all current connections with process names
lsof -i 4 -n -P | awk '{print $1}' | sort -u
```

Or watch live:

```bash
lsof -i 4 -n -P -r 2 | grep ESTABLISHED
```

---

## Updating via API

```bash
TOKEN=$(cat ~/.netmon/panel_token)

curl http://localhost:6543/api/process-policy \
  -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN"
```

Policy is read from disk on every analyze cycle — no restart required after editing the file.

---

## Responding to violations

Process Policy Violations appear in the Pending tab with a red **Process Policy Violation** badge. They are inserted directly into the DB without LLM involvement, so the summary is the raw policy mismatch message.

- **Confirm** — if the connection is legitimate (e.g., a new CDN endpoint), you may want to update the policy file to add the new CIDR. Then confirm to baseline this specific IP.
- **Reject** — blocks the IP. Consider whether the process itself is compromised.

!!! tip "Keep CIDRs tight"
    Overly broad ranges like `/8` are a starting point. Tighten them as you learn the real ranges each process uses. The History tab shows confirmed IPs you can use to narrow down the actual subnets.
