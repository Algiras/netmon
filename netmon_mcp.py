#!/usr/bin/env python3
"""
~/.netmon/netmon_mcp.py — MCP server exposing netmon to Claude Code.

Provides tools to list, confirm, reject, and revert anomaly events,
read the anomaly log, inspect config, and update config settings.
Communicates with the running panel at http://localhost:6543.
"""

import json
import sys
import urllib.request
from pathlib import Path

from mcp.server.fastmcp import FastMCP

PANEL = "http://localhost:6543"
NETMON = Path.home() / ".netmon"

mcp = FastMCP("netmon")


def _panel_get(path: str) -> dict:
    req = urllib.request.Request(
        f"{PANEL}{path}",
        headers={"Host": "localhost:6543"},
    )
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read())


def _panel_post(path: str, payload: dict) -> dict:
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{PANEL}{path}",
        data=data,
        headers={
            "Host": "localhost:6543",
            "Content-Type": "application/json",
            "Content-Length": str(len(data)),
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read())


# ── Tools ──────────────────────────────────────────────────────────────────────

@mcp.tool()
def get_pending_events() -> str:
    """Return all pending anomaly events waiting for a decision."""
    data = _panel_get("/api/events")
    pending = data.get("pending", [])
    if not pending:
        return "No pending events."
    lines = [f"id={e['id']}  {e['process']} → {e['remote']}  severity={e['severity']}\n  {e.get('summary','')}"
             for e in pending]
    return "\n\n".join(lines)


@mcp.tool()
def get_recent_events(limit: int = 20) -> str:
    """Return the most recently resolved anomaly events."""
    data = _panel_get("/api/events")
    recent = data.get("recent", [])[:limit]
    if not recent:
        return "No recent events."
    lines = [f"id={e['id']}  [{e['status'].upper()}]  {e['process']} → {e['remote']}  severity={e['severity']}\n  {e.get('summary','')}"
             for e in recent]
    return "\n\n".join(lines)


@mcp.tool()
def confirm_event(event_id: int) -> str:
    """
    Confirm an anomaly event as benign. Adds it to the baseline so
    future identical connections are not flagged. Similar pending events
    are auto-resolved by cascade.
    """
    result = _panel_post("/action", {"id": event_id, "action": "confirmed"})
    return f"Event {event_id} confirmed. {result}"


@mcp.tool()
def reject_event(event_id: int) -> str:
    """
    Reject an anomaly event as suspicious/malicious. Similar pending
    events are auto-resolved by cascade.
    """
    result = _panel_post("/action", {"id": event_id, "action": "rejected"})
    return f"Event {event_id} rejected. {result}"


@mcp.tool()
def revert_event(event_id: int) -> str:
    """Revert a confirmed or rejected event back to pending for re-review."""
    result = _panel_post("/action", {"id": event_id, "action": "revert"})
    return f"Event {event_id} reverted to pending. {result}"


@mcp.tool()
def read_anomaly_log(lines: int = 50) -> str:
    """Read the last N lines of the netmon anomaly log."""
    log = NETMON / "anomalies.log"
    if not log.exists():
        return "Anomaly log not found."
    all_lines = log.read_text().splitlines()
    tail = all_lines[-lines:]
    return "\n".join(tail) if tail else "Log is empty."


@mcp.tool()
def get_config() -> str:
    """Return the current netmon configuration (autonomous mode, models, etc.)."""
    return json.dumps(_panel_get("/api/config"), indent=2)


@mcp.tool()
def set_autonomous_mode(enabled: bool) -> str:
    """Enable or disable autonomous mode (LLM auto-resolves anomalies)."""
    cfg = _panel_get("/api/config")
    if cfg.get("autonomous_mode") == enabled:
        state = "enabled" if enabled else "disabled"
        return f"Autonomous mode already {state}."
    result = _panel_post("/config", {"toggle": "autonomous_mode"})
    state = "enabled" if result.get("autonomous_mode") else "disabled"
    return f"Autonomous mode is now {state}."


@mcp.tool()
def set_model(model_name: str, model_type: str = "llm") -> str:
    """
    Set the LLM or embedding model used by netmon.
    model_type: 'llm' (analysis) or 'embed' (similarity/RAG).
    """
    if model_type not in ("llm", "embed"):
        return "model_type must be 'llm' or 'embed'."
    key = "llm_model" if model_type == "llm" else "embed_model"
    result = _panel_post("/config", {key: model_name})
    return f"{key} set to {result.get(key)!r}."


@mcp.tool()
def list_available_models() -> str:
    """List Ollama models installed locally, split by capability (LLM vs embed)."""
    data = _panel_get("/api/models")
    if not data.get("available"):
        return "Ollama is not running."
    llm = [f"  {m['name']} ({m['size']})" for m in data.get("llm", [])]
    emb = [f"  {m['name']} ({m['size']})" for m in data.get("embed", [])]
    parts = []
    if llm:
        parts.append("LLM models (tool-capable):\n" + "\n".join(llm))
    if emb:
        parts.append("Embedding models:\n" + "\n".join(emb))
    cfg = data.get("config", {})
    parts.append(f"Active: llm={cfg.get('llm_model','?')}  embed={cfg.get('embed_model','?')}")
    return "\n\n".join(parts) if parts else "No models found."


@mcp.tool()
def get_ip_reputation(ip: str) -> str:
    """Look up geolocation, ISP/org, ASN, and hosting flag for an IP address via ip-api.com."""
    import sys
    sys.path.insert(0, str(Path.home() / ".netmon"))
    import analyze
    return analyze.check_ip_reputation(ip)


if __name__ == "__main__":
    mcp.run(transport="stdio")
