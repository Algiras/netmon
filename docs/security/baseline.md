# Baseline Management

The baseline is the foundation of netmon's signal-to-noise ratio. A well-maintained baseline means only genuinely new or unexpected connections generate alerts.

---

## What the baseline is

`~/.netmon/baseline.txt` contains one `process|remote` pair per line:

```
node|52.207.53.37:443
node|54.147.10.57:443
Slack|18.160.0.0:443
chrome|142.250.80.110:443
```

When `monitor.sh` runs, it compares the current `lsof` snapshot against `baseline.txt` using `comm -23`. Only pairs **not** in the baseline produce `[ANOMALY]` lines in the log — everything else is silently discarded.

---

## How entries are added

| Path | Trigger |
|------|---------|
| **LLM calls `mark_as_normal`** | LLM determined the connection is routine |
| **User clicks Confirm** | Manual confirmation in the panel or notification |
| **LLM calls `auto_resolve(decision="confirmed")`** | Autonomous mode confirmation |

Entries are appended atomically; duplicates are automatically deduplicated on the next monitor cycle.

---

## Viewing the baseline

From the panel **Baseline tab**:

![Baseline tab](../assets/screenshots/panel-baseline.png)

The footer shows the total count. Use the filter bar to search by process name or IP.

From the API:
```bash
TOKEN=$(cat ~/.netmon/panel_token)
curl -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
     http://localhost:6543/api/baseline
```

---

## Removing entries

Click **Remove** next to any entry in the Baseline tab. The entry is deleted from `baseline.txt` immediately. The next `monitor.sh` run will treat that process×IP pair as new again.

From the API:
```bash
TOKEN=$(cat ~/.netmon/panel_token)
curl -X POST http://localhost:6543/baseline/remove \
  -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"entry": "node|52.207.53.37:443"}'
```

---

## Keeping the baseline clean

Over time, IPs change (CDNs rotate, services migrate). Stale entries don't cause harm — they just mean netmon silently allows a connection to an IP that's no longer used. Periodically audit the baseline:

```bash
# Show the 20 most common processes in the baseline
sort ~/.netmon/baseline.txt | cut -d'|' -f1 | sort | uniq -c | sort -rn | head -20
```

Remove entries for processes you no longer use, or for IPs that have changed to a new range.

---

## Baseline vs process policy

The baseline silences known-good connections **after** LLM confirmation. [Process policy](../configuration/process-policy.md) enforces **expected ranges** before the LLM is ever consulted — it's a proactive control, not a learned list. Use both together: process policy for high-value AI agent processes, baseline for everything else.
