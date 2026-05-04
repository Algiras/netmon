#!/usr/bin/env python3
"""
~/.netmon/analyze.py
granite4.1:3b reviews network anomaly threads with RAG short-term memory.
- Embeds each event with nomic-embed-text-v2-moe
- Retrieves similar past events from SQLite for context (RAG)
- Calls tools: send_notification, add_to_review, mark_as_normal
- Stores every event + embedding in the DB for the panel UI
"""

import json
import subprocess
import urllib.error
import urllib.request
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from sys import exit

import db
import embed as emb

NETMON_DIR    = Path.home() / ".netmon"
ANOMALY_LOG   = NETMON_DIR / "anomalies.log"
ANALYSIS_LOG  = NETMON_DIR / "analysis.log"
CURSOR_FILE   = NETMON_DIR / ".analyze_cursor"
CONFIG_FILE   = NETMON_DIR / "config.json"
PANEL_URL     = "http://localhost:6543"
MENUBAR_BIN   = NETMON_DIR / "NetmonMenuBar.app" / "Contents" / "MacOS" / "NetmonMenuBar"


def read_config() -> dict:
    try:
        return json.loads(CONFIG_FILE.read_text())
    except Exception:
        return {"autonomous_mode": False}

OLLAMA_URL = "http://localhost:11434/api/chat"

# ── Tools ─────────────────────────────────────────────────────────────────────

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "send_notification",
            "description": (
                "Send a macOS notification and queue the event for user review in the panel. "
                "Only call for genuine concerns. Use severity: "
                "info=FYI, warning=investigate, critical=act-now."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "process":  {"type": "string", "description": "The offending process name"},
                    "remote":   {"type": "string", "description": "remote_ip:port"},
                    "title":    {"type": "string", "description": "Short alert title (≤50 chars)"},
                    "message":  {"type": "string", "description": "What was detected and why suspicious (≤200 chars)"},
                    "severity": {"type": "string", "enum": ["info", "warning", "critical"]},
                },
                "required": ["process", "remote", "title", "message", "severity"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "auto_resolve",
            "description": (
                "Autonomous mode only. Directly mark a connection as confirmed (benign, add to baseline) "
                "or rejected (suspicious, flag in DB) without user review. "
                "Use for clear-cut cases. For genuine critical threats, use send_notification instead."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "process":  {"type": "string"},
                    "remote":   {"type": "string", "description": "ip:port"},
                    "decision": {"type": "string", "enum": ["confirmed", "rejected"]},
                    "reason":   {"type": "string", "description": "One-line explanation"},
                },
                "required": ["process", "remote", "decision", "reason"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "mark_as_normal",
            "description": "Record that a process→remote pair is expected and add it to the baseline.",
            "parameters": {
                "type": "object",
                "properties": {
                    "process": {"type": "string"},
                    "remote":  {"type": "string", "description": "ip:port"},
                    "reason":  {"type": "string"},
                },
                "required": ["process", "remote"],
            },
        },
    },
]


# ── Tool implementations ───────────────────────────────────────────────────────

def send_notification(process, remote, title, message, severity) -> str:
    icons = {"info": "ℹ️", "warning": "⚠️", "critical": "🚨"}

    # Insert into DB first to get the row ID (needed for notification action callbacks)
    vector   = emb.embed_event(process, remote, message)
    event_id = db.insert_event(
        process=process, remote=remote,
        severity=severity, summary=f"{title}: {message}",
        embedding=vector,
    )

    # Swift menu bar app → native UNUserNotification with Confirm/Reject buttons
    # Falls back to osascript if the binary isn't built yet
    if MENUBAR_BIN.exists():
        subprocess.Popen(
            [str(MENUBAR_BIN), "notify", str(event_id), title, message, severity],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    else:
        sounds  = {"info": "Glass", "warning": "Basso", "critical": "Sosumi"}
        heading = f"{icons.get(severity,'⚠️')} {title}"
        subprocess.Popen(
            ["osascript", "-e",
             f'display notification "{message}  → {PANEL_URL}" '
             f'with title "{heading}" sound name "{sounds.get(severity,"Basso")}"'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

    _log(f"[NOTIFY/{severity.upper()}] {title}: {message}")
    return "queued for review"


def auto_resolve(process, remote, decision, reason) -> str:
    vector   = emb.embed_event(process, remote, reason)
    severity = "info" if decision == "confirmed" else "warning"
    event_id = db.insert_event(
        process=process, remote=remote,
        severity=severity,
        summary=f"[AUTO-{decision.upper()}] {reason}",
        embedding=vector,
    )
    db.update_status(event_id, decision)
    if decision == "confirmed":
        mark_as_normal(process, remote, reason)
    _log(f"[AUTO/{decision.upper()}] {process} → {remote}: {reason}")
    return f"auto-{decision}"


def mark_as_normal(process, remote, reason="") -> str:
    baseline = NETMON_DIR / "baseline.txt"
    entry = f"{process}|{remote}"
    if baseline.exists():
        existing = set(baseline.read_text().splitlines())
        if entry in existing:
            return "already in baseline"
        with baseline.open("a") as f:
            f.write(entry + "\n")
    _log(f"[BASELINE+] {entry}  reason={reason!r}")
    return "added to baseline"


def dispatch(name: str, args: dict) -> str:
    if isinstance(args, str):
        try:
            args = json.loads(args)
        except json.JSONDecodeError:
            args = {}
    if name == "send_notification":
        return send_notification(
            process  = args.get("process", "unknown"),
            remote   = args.get("remote",  "unknown"),
            title    = args.get("title",   "Network Alert"),
            message  = args.get("message", ""),
            severity = args.get("severity","warning"),
        )
    if name == "auto_resolve":
        return auto_resolve(
            process  = args.get("process",  ""),
            remote   = args.get("remote",   ""),
            decision = args.get("decision", "confirmed"),
            reason   = args.get("reason",   ""),
        )
    if name == "mark_as_normal":
        return mark_as_normal(
            process = args.get("process", ""),
            remote  = args.get("remote",  ""),
            reason  = args.get("reason",  ""),
        )
    return f"unknown tool: {name}"


# ── Ollama ─────────────────────────────────────────────────────────────────────

def chat(messages: list, tools: list | None = None, timeout: int = 90, model: str = "") -> dict:
    payload: dict = {"model": model or read_config().get("model", "granite4.1:3b"), "messages": messages, "stream": False}
    if tools:
        payload["tools"] = tools
    req = urllib.request.Request(
        OLLAMA_URL,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    except Exception as e:
        _log(f"[ERROR] Ollama: {e}")
        return {}


def run_with_tools(messages: list) -> str:
    for _ in range(6):
        resp = chat(messages, tools=TOOLS)
        if not resp:
            return ""
        msg        = resp.get("message", {})
        tool_calls = msg.get("tool_calls") or []

        if not tool_calls:
            return msg.get("content", "")

        messages.append(msg)
        for call in tool_calls:
            fn     = call.get("function", {})
            result = dispatch(fn.get("name", ""), fn.get("arguments", {}))
            messages.append({"role": "tool", "name": fn.get("name"), "content": result})

    return ""


# ── Data helpers ───────────────────────────────────────────────────────────────

def _log(msg: str):
    ts   = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line)
    with open(ANALYSIS_LOG, "a") as f:
        f.write(line + "\n")


def load_new_anomalies() -> list[str]:
    if not ANOMALY_LOG.exists():
        return []
    all_lines = [l for l in ANOMALY_LOG.read_text().splitlines() if "[ANOMALY]" in l]
    cursor = 0
    if CURSOR_FILE.exists():
        try:
            cursor = int(CURSOR_FILE.read_text().strip())
        except ValueError:
            pass
    new = all_lines[cursor:]
    CURSOR_FILE.write_text(str(len(all_lines)))
    return new


def build_context(lines: list[str]) -> tuple[str, list[dict]]:
    """
    Returns (summary_text, list_of_parsed_events).
    Also does per-event RAG lookup and embeds similar-past-events context.
    """
    buckets: dict[str, list[str]]   = defaultdict(list)
    process_counts: dict[str, int]  = defaultdict(int)
    parsed: list[dict]              = []
    rag_snippets: list[str]         = []

    for line in lines:
        try:
            ts_str  = line[1:20]
            rest    = line.split("] [ANOMALY] ", 1)[-1]
            proc, remote = rest.split(" -> ", 1)
            remote = remote.strip()
            ts      = datetime.strptime(ts_str, "%Y-%m-%d %H:%M:%S")
            bucket  = ts.strftime("%Y-%m-%d %H:%M")[:-1] + "0"
            buckets[bucket].append(f"  {proc} → {remote}")
            process_counts[proc] += 1
            parsed.append({"ts": ts_str, "process": proc, "remote": remote})

            # RAG: look up past similar events
            vector = emb.embed_event(proc, remote)
            if vector:
                similar = db.find_similar(vector, top_k=3, min_sim=0.78)
                for s in similar:
                    rag_snippets.append(
                        f"  [{s['ts']}] {s['process']} → {s['remote']} "
                        f"(status={s['status']}, sim={s['similarity']}): {s['summary']}"
                    )
        except Exception:
            continue

    lines_out = [f"New anomalies this cycle: {len(lines)}"]
    lines_out.append("\nProcess frequency:")
    for proc, cnt in sorted(process_counts.items(), key=lambda x: -x[1]):
        lines_out.append(f"  {proc}: {cnt}")

    lines_out.append("\nTimeline (10-min buckets, most recent last):")
    for bucket in sorted(buckets)[-15:]:
        lines_out.append(f"\n[{bucket}]")
        lines_out.extend(buckets[bucket][:8])
        extra = len(buckets[bucket]) - 8
        if extra > 0:
            lines_out.append(f"  … +{extra} more")

    if rag_snippets:
        lines_out.append("\n── Similar past events (RAG memory) ──")
        lines_out.extend(dict.fromkeys(rag_snippets))  # deduplicate, preserve order

    return "\n".join(lines_out), parsed


# ── System prompts ─────────────────────────────────────────────────────────────

SYSTEM = """\
You are a network security analyst for a macOS developer machine.
You see NEW outbound TCP connections (process→remote IP) not in the known-good baseline,
plus any similar past events retrieved from short-term memory (marked with similarity scores).

Decision guide:
• SKIP alerting: Chrome/Google, Slack, Bitwarden, Dropbox, OneDrive → any CDN/cloud IP on 443.
  node/npm → GitHub IPs (185.199.x.x, 140.82.x.x). Single new CDN hop for known apps.
• ALERT (send_notification):
  - Unknown or scripting processes (python3, bash, sh) connecting to external IPs
  - Any process connecting to non-443/non-80 ports
  - Repeated new connections from the same process in one cycle (possible scanning/exfil)
  - Connections matching previously-rejected patterns in memory
  - AI agent tooling calling unexpected APIs
• mark_as_normal: when a connection is clearly routine but not yet in baseline.

Past events with status='confirmed' are approved by the user — treat similarly.
Past events with status='rejected' are suspicious — alert if seen again.

Be conservative: one high-quality alert beats five noisy ones."""

SYSTEM_AUTONOMOUS = """\
You are an AUTONOMOUS network security agent for a macOS developer machine.
You see NEW outbound TCP connections not in the known-good baseline.
You have full authority to make final decisions — no human review will follow.

For every event call exactly one tool:
• auto_resolve(..., "confirmed"): clearly routine traffic (CDN, cloud, known dev tools on 443/80).
  Chrome, Slack, Bitwarden, Dropbox, node/npm to GitHub, Apple services → always confirm.
• auto_resolve(..., "rejected"): genuinely suspicious (scripting processes to unusual IPs,
  non-standard ports, repeated scanning pattern, matches a previously-rejected event in memory).
• send_notification: ONLY for critical active threats needing immediate human attention
  (e.g. data exfiltration in progress, known malware IPs, reverse shell indicators).

Past events with status='confirmed' → confirm similar ones.
Past events with status='rejected' → reject similar ones.

Be accurate. False positives waste resources; false negatives miss real threats.
Decide every event — do not skip or leave unresolved."""


# ── Entry point ────────────────────────────────────────────────────────────────

def main():
    db.init()
    new_lines = load_new_anomalies()

    if not new_lines:
        _log("[ANALYZE] No new anomalies — skipping")
        return

    cfg      = read_config()
    auto     = cfg.get("autonomous_mode", False)
    mode_tag = "AUTONOMOUS" if auto else "REVIEW"
    _log(f"[ANALYZE/{mode_tag}] {len(new_lines)} new anomalie(s)")
    system_prompt = SYSTEM_AUTONOMOUS if auto else SYSTEM

    # Group by process so each LLM call handles one process at a time (more reliable tool use)
    groups: dict[str, list[str]] = defaultdict(list)
    for line in new_lines:
        try:
            proc = line.split("] [ANOMALY] ", 1)[-1].split(" -> ")[0].strip()
            groups[proc].append(line)
        except Exception:
            continue

    for proc, lines in groups.items():
        summary, _parsed = build_context(lines)
        messages = [
            {"role": "system", "content": system_prompt},
            {"role": "user",   "content":
                f"Review these anomalies for process '{proc}' "
                f"({len(lines)} connection(s)):\n\n{summary}\n\n"
                f"Call a tool for EVERY unique process→remote pair. Do not skip any."},
        ]
        result = run_with_tools(messages)
        if result:
            _log(f"[SUMMARY/{proc}] {result[:300]}")


if __name__ == "__main__":
    main()
