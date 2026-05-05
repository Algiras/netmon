# ADR-004: Connection-count spike detection via rolling window

**Status:** Accepted  
**Date:** 2026-05

## Context

`monitor.sh` detects new process×IP pairs but is blind to call-volume changes on already-baselined pairs. A compromised agent repeatedly calling a trusted API endpoint (data exfiltration, prompt flooding) would generate no alerts.

## Decision

`volume_check.py` runs each monitor cycle (60 s). It counts simultaneous ESTABLISHED TCP connections per pair via `lsof`, maintains a 30-sample rolling window per pair in `connection_counts.json`, and emits `[VOLUME_ANOMALY]` to the anomaly log when:

1. Current count ≥ `SPIKE_MIN` (5 connections)  
2. Current count > `SPIKE_FACTOR` (4×) × historical mean  
3. At least `MIN_SAMPLES` (10) history samples exist  
4. Alert cooldown (`ALERT_COOLDOWN` = 600 s) has expired for this pair

`[VOLUME_ANOMALY]` lines follow the same log format as `[ANOMALY]` and flow through the same LLM triage pipeline.

## Limitations

- lsof counts simultaneous TCP sockets, not HTTP request rate. Under HTTP/2 multiplexing, many API calls share one socket — this metric is therefore a coarse proxy.
- A single large file upload or streaming response holds one socket open but is not a spike in socket count. Not caught by this approach.
- Processes that legitimately open many parallel connections (browsers, download managers) may need their pair added to an exclusion list.

## Future work

ADR-005 (not yet written): HTTP-level monitoring via a local MITM proxy for per-endpoint call rate.
