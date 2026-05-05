#!/usr/bin/env python3
"""
~/.netmon/volume_check.py — connection-count spike detector
Called by monitor.sh after each lsof snapshot (every 60 s).

For each (process, remote) pair, tracks a 30-sample rolling window of
simultaneous ESTABLISHED connection counts.  Emits [VOLUME_ANOMALY] to
anomalies.log when the current count spikes well above the pair's baseline.
"""

import json
import subprocess
from datetime import datetime
from pathlib import Path

NETMON_DIR    = Path.home() / ".netmon"
COUNTS_FILE   = NETMON_DIR / "connection_counts.json"
ANOMALY_LOG   = NETMON_DIR / "anomalies.log"

WINDOW_SIZE   = 30    # samples kept (~30 min at 60-s intervals)
MIN_SAMPLES   = 10    # minimum history before alerting (avoid cold-start noise)
SPIKE_FACTOR  = 4.0   # current must exceed N × historical mean to alert
SPIKE_MIN     = 5     # absolute minimum count to ever alert
ALERT_COOLDOWN = 600  # seconds between repeat alerts for the same pair


def _get_counts() -> dict:
    """Return {proc|remote: int} for current ESTABLISHED TCP connections."""
    try:
        out = subprocess.check_output(
            ["lsof", "-i", "tcp", "-n", "-P"],
            stderr=subprocess.DEVNULL, timeout=10,
        ).decode(errors="replace")
    except Exception:
        return {}
    counts: dict = {}
    for line in out.splitlines():
        if "ESTABLISHED" not in line:
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        addr_field = parts[-2] if len(parts) >= 2 else ""
        if "->" not in addr_field:
            continue
        remote = addr_field.split("->", 1)[1]
        if remote.startswith("127.0.0.1:") or remote.startswith("[::1]:"):
            continue
        key = f"{parts[0]}|{remote}"
        counts[key] = counts.get(key, 0) + 1
    return counts


def _load() -> dict:
    try:
        return json.loads(COUNTS_FILE.read_text()) if COUNTS_FILE.exists() else {}
    except Exception:
        return {}


def _save(h: dict):
    COUNTS_FILE.write_text(json.dumps(h))


def main():
    now_ts = datetime.now().timestamp()
    connections = _get_counts()
    history     = _load()

    alerts: list[str] = []

    for key, count in connections.items():
        entry   = history.setdefault(key, {"samples": [], "alerted_at": None})
        samples = entry["samples"]
        samples.append(count)
        if len(samples) > WINDOW_SIZE:
            samples[:] = samples[-WINDOW_SIZE:]

        # Not enough history yet — keep collecting
        if len(samples) < MIN_SAMPLES:
            continue

        # Historical mean excludes the current sample
        hist = samples[:-1]
        mean = sum(hist) / len(hist)

        # Alert conditions: high absolute count AND well above baseline
        if count < SPIKE_MIN:
            continue
        if mean <= 0 or count < mean * SPIKE_FACTOR:
            continue

        # Cooldown
        last = entry.get("alerted_at")
        if last and (now_ts - last) < ALERT_COOLDOWN:
            continue

        entry["alerted_at"] = now_ts
        proc, remote = key.split("|", 1)
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        alerts.append(
            f"[{ts}] [VOLUME_ANOMALY] {proc} -> {remote} "
            f"({count} connections, baseline avg {mean:.1f})"
        )

    if alerts:
        with ANOMALY_LOG.open("a") as f:
            f.write("\n".join(alerts) + "\n")

    _save(history)


if __name__ == "__main__":
    main()
