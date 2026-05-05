# Process Policy

`~/.netmon/process_policy.json` defines expected CIDR ranges per process. Connections outside declared ranges are **Process Policy Violations** — Critical severity, no LLM, straight to the pending queue.

This is designed specifically for AI agent processes (Claude Code, Cursor, Copilot) that should only talk to known endpoints. A violation means the agent connected somewhere unexpected — a strong signal of prompt injection exfiltration, supply-chain compromise, or malware.

## How it works

```mermaid
flowchart LR
    E[New anomaly\nprocess|IP:port] --> PP

    PP{"Process in\npolicy.json?"}
    PP -->|"No"| LLM["Normal LLM triage"]
    PP -->|"Yes"| CIDR

    CIDR{"IP within\nexpected CIDRs?"}
    CIDR -->|"Yes"| OK["Continue to\nnormal triage"]
    CIDR -->|"No"| VIOL["🚨 POLICY_VIOLATION\nCritical · no LLM\nPending queue immediately"]
```

---

## Format

```json
{
  "_comment": "process_name → list of allowed CIDRs",
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

| Field | Notes |
|-------|-------|
| **Key** | Process name exactly as shown in `lsof COMMAND` column — truncated to 15 chars |
| **Value** | List of allowed CIDR strings |
| `"0.0.0.0/0"` | Allows any IPv4 — effectively disables policy checks for this process |
| Missing key | Process is subject to normal LLM triage only |

---

## Runbook: setting up policy for a new process

### Step 1 — Find the process name

```bash
# Watch live connections and their process names
lsof -i 4 -n -P | grep ESTABLISHED | awk '{print $1, $9}' | sort -u
```

!!! tip "Process names are truncated"
    `lsof` truncates `COMMAND` to 15 characters. Claude Code running as Electron shows as `2.1.119` (the version string), not `Claude Code`.

### Step 2 — Collect the real IPs

Let the process run normally for a day. Collect all IPs it connects to:

```bash
# All IPs for a specific process name
lsof -i 4 -n -P -c 2.1.119 | awk 'NR>1 {print $9}' | cut -d: -f1 | sort -u
```

### Step 3 — Identify the CIDRs

Look up each IP's network range:

```bash
# Identify the /24 or larger block for each IP
whois 160.79.104.10 | grep -i "cidr\|route\|netrange"
```

Or use a bulk lookup service. Group IPs by provider (Cloudflare, AWS, Anthropic, etc.) and use their published IP ranges.

### Step 4 — Write the policy

```json
{
  "2.1.119": [
    "160.79.104.0/24",
    "34.0.0.0/8",
    "35.0.0.0/8"
  ]
}
```

Start broad (e.g., `/8`), observe for false positives, tighten to `/24` once you know the actual range.

### Step 5 — Verify

Policy is read on every analyze cycle — no restart needed. Trigger a test by confirming a few events via the panel, then watch the next cycle:

```bash
# Check recent events for policy violations
TOKEN=$(cat ~/.netmon/panel_token)
curl -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
     http://localhost:6543/api/events | python3 -c "
import sys, json
data = json.load(sys.stdin)
for e in data['pending'] + data['recent']:
    if e.get('type') == 'policy_violation':
        print(e['process'], e['remote'], e['summary'])
"
```

---

## Common AI agent policies

=== "Claude Code"

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
    Covers Anthropic API, AWS us-east CDN, and Vercel edge network.

=== "Cursor"

    ```json
    {
      "Cursor": [
        "0.0.0.0/0"
      ]
    }
    ```
    Start permissive. Monitor History tab for a week, then tighten once you know Cursor's actual endpoints.

=== "VS Code"

    ```json
    {
      "Code Helper": [
        "13.107.42.0/24",
        "20.0.0.0/8",
        "40.0.0.0/8"
      ]
    }
    ```
    Microsoft Azure ranges. Adjust based on your region.

---

## Responding to violations

Violations appear in **Pending** with a red **Process Policy Violation** badge.

- **Confirm** — if legitimate, add the new CIDR to the policy file and confirm this event to baseline it
- **Reject** — blocks the IP; consider whether the process itself may be compromised

!!! danger "Violations require human investigation"
    A process policy violation is not a false positive to dismiss quickly. The process connected somewhere it was explicitly not expected to. Investigate before confirming.
