#!/usr/bin/env python3
"""
~/.netmon/dns_monitor.py — DNS exfiltration detection.

Captures UDP port 53 traffic via `sudo tcpdump` (requires the
/etc/sudoers.d/netmon entry created by install.sh).

Detection heuristics — each query is checked for:
  1. Long subdomain label (>= LABEL_LEN_LIMIT chars)
  2. High-entropy label (Shannon entropy >= ENTROPY_THRESHOLD for labels
     >= MIN_LABEL_LEN chars) — base32/base64-encoded exfil data
  3. TXT record flood (>= TXT_FLOOD_COUNT queries to same parent in window)
  4. Unique-subdomain flood (>= SUBDOMAIN_FLOOD_COUNT distinct subdomains
     under one parent in window) — classic DNS tunnel pattern

Detected events go into the netmon DB and are picked up by the existing
analyze/notification pipeline exactly like TCP connection anomalies.
"""

from __future__ import annotations

import math
import re
import subprocess
import sys
import time
from collections import defaultdict, deque
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import db

# ── Tunable thresholds ────────────────────────────────────────────────────────

ENTROPY_THRESHOLD     = 3.5   # bits/char; base32 ≈ 3.32, base64 ≈ 4.0
MIN_LABEL_LEN         = 20    # only score entropy for labels this long or longer
LABEL_LEN_LIMIT       = 45    # single label ≥ this → flag unconditionally
TXT_FLOOD_COUNT       = 5     # TXT queries to same parent within window
SUBDOMAIN_FLOOD_COUNT = 20    # unique subdomains under same parent in window
WINDOW_SECS           = 60    # rolling time window for flood detection

# ── Per-domain sliding-window state ──────────────────────────────────────────

# Each value: deque of (monotonic_time, item)
_txt_hits: dict[str, deque] = defaultdict(deque)   # parent → timestamps
_sub_hits: dict[str, deque] = defaultdict(deque)   # parent → (ts, subdomain)


# ── Analysis helpers ──────────────────────────────────────────────────────────

def shannon_entropy(s: str) -> float:
    """Shannon entropy in bits per character."""
    if not s:
        return 0.0
    s = s.lower()
    counts: dict[str, int] = {}
    for ch in s:
        counts[ch] = counts.get(ch, 0) + 1
    n = len(s)
    return -sum((c / n) * math.log2(c / n) for c in counts.values())


def _prune_window(window: deque, now: float) -> None:
    while window and now - window[0][0] > WINDOW_SECS:
        window.popleft()


def analyze_query(qname: str, qtype: str) -> str | None:
    """
    Return a human-readable reason string if this DNS query looks like
    exfiltration, or None if it appears normal.
    """
    qname = qname.rstrip(".")
    labels = qname.split(".")
    if len(labels) < 2:
        return None

    first  = labels[0]
    # e.g. for abc.evil.com → parent = evil.com
    parent = ".".join(labels[-2:]) if len(labels) >= 2 else qname
    now    = time.monotonic()

    # 1. Long label — data stuffed into a single label
    if len(first) >= LABEL_LEN_LIMIT:
        return (f"long DNS label ({len(first)} chars) under {parent!r} "
                f"— possible encoded payload")

    # 2. High-entropy label — base32/base64-encoded exfil
    if len(first) >= MIN_LABEL_LEN:
        ent = shannon_entropy(first)
        if ent >= ENTROPY_THRESHOLD:
            return (f"high-entropy DNS label (entropy={ent:.2f} bits/char, "
                    f"len={len(first)}) under {parent!r} "
                    f"— looks like base32/base64 encoded data")

    # 3. TXT record flood — TXT used as a C2 channel
    if qtype.upper() == "TXT":
        w = _txt_hits[parent]
        _prune_window(w, now)
        w.append((now, qname))
        if len(w) >= TXT_FLOOD_COUNT:
            return (f"TXT query flood: {len(w)} TXT queries to {parent!r} "
                    f"in {WINDOW_SECS}s — common C2 / DNS exfil channel")

    # 4. Unique-subdomain flood — classic DNS tunnelling
    if len(labels) >= 3:
        w = _sub_hits[parent]
        _prune_window(w, now)
        seen = {e[1] for e in w}
        if first not in seen:
            w.append((now, first))
        if len(w) >= SUBDOMAIN_FLOOD_COUNT:
            return (f"subdomain flood: {len(w)} unique subdomains under "
                    f"{parent!r} in {WINDOW_SECS}s — classic DNS tunnel pattern")

    return None


def _attr_processes() -> str:
    """Best-effort: return names of processes with open UDP:53 connections."""
    try:
        out = subprocess.check_output(
            ["lsof", "-i", "UDP:53", "-n", "-P"],
            stderr=subprocess.DEVNULL, text=True, timeout=3,
        )
        names = {ln.split()[0] for ln in out.splitlines()[1:] if ln.strip()}
        return ", ".join(sorted(names)) or "unknown"
    except Exception:
        return "unknown"


# ── tcpdump output parser ─────────────────────────────────────────────────────

# Matches a DNS query (not response) in standard tcpdump output:
#   HH:MM:SS.us IP src.port > dst.53: ID+ QTYPE? qname. (bytes)
_LINE_RE = re.compile(
    r"\d{2}:\d{2}:\d{2}\.\d+\s+IP.*?>\s+\S+\.53:\s+\d+[+\-]?\s+(\w+)\?\s+(\S+)",
    re.IGNORECASE,
)


def monitor() -> None:
    """Block forever, reading tcpdump output and inserting alerts into the DB."""
    db.init()

    cmd = ["sudo", "/usr/sbin/tcpdump", "-l", "-n", "udp", "port", "53"]
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
    except FileNotFoundError:
        print("[dns_monitor] tcpdump not found at /usr/sbin/tcpdump", file=sys.stderr)
        sys.exit(1)

    try:
        for line in proc.stdout:
            m = _LINE_RE.search(line)
            if not m:
                continue
            qtype, qname = m.group(1), m.group(2)
            reason = analyze_query(qname, qtype)
            if reason:
                procs = _attr_processes()
                db.insert_event(
                    process=procs,
                    remote=qname.rstrip("."),
                    severity="high",
                    summary=f"[DNS] {reason}",
                )
    except KeyboardInterrupt:
        pass
    finally:
        proc.terminate()


if __name__ == "__main__":
    monitor()
