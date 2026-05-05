# IP Blocking & pf

When you reject an event, the remote IP is added to `~/.netmon/blocked_ips.txt`. With pf enforcement enabled, that IP is also blocked at the macOS firewall level — no process on your machine can reach it.

---

## How blocking works

### Without pf (default)

Blocked IPs are tracked in `blocked_ips.txt` and `blocked_ips_meta.json`. If the same IP appears in a future `lsof` snapshot, it's flagged as `[BLOCKED]` — a Critical severity event that bypasses the LLM and goes straight to the pending queue.

This is **detection without enforcement** — the connection is flagged but not prevented.

### With pf enforcement

After running `setup-pf.sh` and enabling `pf_enforcement` in config, blocking does two things:

1. Appends the IP to the in-memory pf anchor ruleset immediately
2. On every subsequent analyze run, regenerates the anchor file from `blocked_ips.txt`

New connections to blocked IPs are refused at the kernel level — they never reach the application layer.

---

## Setting up pf enforcement

```bash
bash ~/.netmon/setup-pf.sh
```

This script:
1. Creates `/etc/pf.anchors/netmon` (the anchor file)
2. Adds the anchor reference to `/etc/pf.conf`
3. Writes a sudoers entry to `/etc/sudoers.d/netmon` so `analyze.py` can reload the anchor without a password prompt

After setup, enable enforcement in config:

```bash
TOKEN=$(cat ~/.netmon/panel_token)
curl -X POST http://localhost:6543/config \
  -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"pf_enforcement": true}'
```

Or use the panel: **Settings → Network Enforcement → toggle**.

---

## Viewing blocked IPs

From the **Settings tab** scroll to the Blocked IPs section, or from the API:

```bash
TOKEN=$(cat ~/.netmon/panel_token)
curl -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
     http://localhost:6543/api/blocked-ips
```

Each entry includes:
- `ip` — the blocked IP address
- `reason` — LLM summary or "manual block"
- `blocked_at` — ISO timestamp

---

## Unblocking an IP

From the panel: navigate to Settings → Blocked IPs, click **Unblock**.

From the API:
```bash
TOKEN=$(cat ~/.netmon/panel_token)
curl -X POST http://localhost:6543/unblock-ip \
  -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"ip": "198.51.100.7"}'
```

This removes the IP from `blocked_ips.txt` and regenerates the pf anchor.

---

## Checking pf status

```bash
TOKEN=$(cat ~/.netmon/panel_token)
curl -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
     http://localhost:6543/api/pf-status
```

```json
{
  "sudoers_configured": true,
  "anchor_configured": true,
  "enforcement_active": true,
  "pf_enforcement": true,
  "setup_script": "/Users/you/.netmon/setup-pf.sh"
}
```

`enforcement_active` is `true` only when all three conditions are met: `pf_enforcement: true` in config, sudoers entry present, and anchor file present.

---

## Manually inspect the anchor

```bash
sudo pfctl -a netmon -s rules
```

Expected output when IPs are blocked:

```
block drop out quick from any to 198.51.100.7
block drop out quick from any to 203.0.113.42
```
