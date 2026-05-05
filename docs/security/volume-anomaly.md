# Volume Anomaly Detection

Volume anomaly detection catches connections that are unusual not because they're new, but because they're happening at an abnormal rate. A process you've already baselined can still be exfiltrating data — it just makes 200 connections per minute instead of its usual 2.

---

## How it works

`volume_check.py` runs alongside `monitor.sh` on every 60-second cycle:

1. **Counts** the current number of active connections per `process|remote` pair using `lsof`
2. **Updates** the rolling history in `~/.netmon/connection_counts.json`
3. **Computes** the rolling average over the last `volume_window` samples (default 10)
4. If the current count exceeds `rolling_average × volume_threshold` (default 3.0), writes a `[VOLUME_ANOMALY]` line to `anomalies.log`

Volume anomalies are fed into the standard `analyze.py` triage pipeline — the LLM sees them with extra context about the count spike.

---

## Configuration

| Key | Default | Meaning |
|-----|---------|---------|
| `volume_threshold` | `3.0` | Multiplier above rolling average that triggers an anomaly |
| `volume_window` | `10` | Number of 60-second samples in the rolling window (= 10 min) |

Tune these in `~/.netmon/config.json`:

```json
{
  "volume_threshold": 2.5,
  "volume_window": 15
}
```

Lower `volume_threshold` → more sensitive (more false positives).  
Higher `volume_window` → slower to react to sudden spikes but less sensitive to brief bursts.

---

## The connection_counts.json file

```json
{
  "node|52.207.53.37:443": [1, 1, 2, 1, 1, 2, 1, 1, 15, 22],
  "chrome|142.250.80.110:443": [3, 4, 3, 2, 3]
}
```

Each array is a circular buffer of the last `volume_window` connection counts. A sudden jump in the most recent values triggers the anomaly.

---

## Example alert

When a volume anomaly fires, the LLM receives context like:

```
[VOLUME_ANOMALY] node|52.207.53.37:443
Current count: 22 connections
Rolling average (last 10 min): 1.4 connections
Ratio: 15.7x above average
```

The LLM then decides whether to notify you, auto-resolve, or add context to a pending alert.

---

## Limitations

- Volume anomaly detects **rate** spikes, not absolute counts. A process that constantly makes 100 connections will not trigger this (it's "normal" for that process).
- Short-lived spikes during a single 60-second window may not accumulate enough samples to trigger detection.
- DNS, ICMP, and non-TCP/UDP traffic is not captured by `lsof -i 4`.
