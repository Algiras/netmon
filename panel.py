#!/usr/bin/env python3
"""
~/.netmon/panel.py — netmon review panel (http://localhost:6543)
Single-file web server. No external dependencies.
Reads/writes ~/.netmon/netmon.db via db.py.
"""

import json
import os
import sys
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).parent))
import db

PORT       = 6543
CONFIG_FILE = Path.home() / ".netmon" / "config.json"


def read_config() -> dict:
    try:
        return json.loads(CONFIG_FILE.read_text())
    except Exception:
        return {"autonomous_mode": False}


def write_config(data: dict):
    CONFIG_FILE.write_text(json.dumps(data, indent=2))


def list_ollama_models() -> list[dict]:
    """Return installed Ollama models that support tool calling."""
    try:
        req = urllib.request.Request("http://localhost:11434/api/tags")
        with urllib.request.urlopen(req, timeout=5) as r:
            tags = json.loads(r.read())
    except Exception:
        return []

    # Embedding-only model families to exclude
    EMBED_FAMILIES = {"nomic-bert-moe", "bert", "clip"}

    results = []
    for m in tags.get("models", []):
        name   = m["name"]
        family = m.get("details", {}).get("family", "")
        if family in EMBED_FAMILIES:
            continue
        try:
            req2 = urllib.request.Request(
                "http://localhost:11434/api/show",
                data=json.dumps({"model": name}).encode(),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req2, timeout=5) as r:
                info = json.loads(r.read())
            caps = info.get("capabilities", [])
            tools_ok = "tools" in caps
        except Exception:
            tools_ok = False
        results.append({
            "name":    name,
            "size":    m.get("details", {}).get("parameter_size", "?"),
            "tools":   tools_ok,
            "caps":    caps if isinstance(caps, list) else [],
        })
    return results

# ── HTML template ──────────────────────────────────────────────────────────────

HTML_TEMPLATE = """\
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>netmon — network review panel</title>
  <style>
    :root {{
      --bg: #0f1117; --surface: #1a1d27; --border: #2a2d3a;
      --text: #e2e8f0; --muted: #8892a4; --accent: #6366f1;
      --warn: #f59e0b; --crit: #ef4444; --ok: #22c55e; --info: #3b82f6;
    }}
    * {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{ background: var(--bg); color: var(--text); font: 14px/1.6 'SF Mono', monospace;
            min-height: 100vh; padding: 24px; }}
    h1 {{ font-size: 18px; color: var(--accent); margin-bottom: 4px; }}
    .meta {{ color: var(--muted); font-size: 12px; margin-bottom: 24px; }}
    .tabs {{ display: flex; gap: 8px; margin-bottom: 20px; }}
    .tab {{ padding: 6px 16px; border-radius: 6px; border: 1px solid var(--border);
             background: transparent; color: var(--muted); cursor: pointer; font-size: 13px; }}
    .tab.active {{ background: var(--accent); color: #fff; border-color: var(--accent); }}
    .section {{ display: none; }}
    .section.active {{ display: block; }}
    .empty {{ color: var(--muted); padding: 20px 0; }}
    table {{ width: 100%; border-collapse: collapse; }}
    th {{ text-align: left; color: var(--muted); font-size: 11px; text-transform: uppercase;
           letter-spacing: .05em; padding: 8px 12px; border-bottom: 1px solid var(--border); }}
    td {{ padding: 10px 12px; border-bottom: 1px solid var(--border); vertical-align: top; }}
    tr:hover td {{ background: var(--surface); }}
    .badge {{ display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 11px;
               font-weight: 600; text-transform: uppercase; }}
    .badge.critical {{ background: #7f1d1d; color: var(--crit); }}
    .badge.warning  {{ background: #451a03; color: var(--warn); }}
    .badge.info     {{ background: #1e3a5f; color: var(--info); }}
    .badge.unknown  {{ background: var(--border); color: var(--muted); }}
    .badge.confirmed{{ background: #14532d; color: var(--ok); }}
    .badge.rejected {{ background: #7f1d1d; color: var(--crit); }}
    .badge.pending  {{ background: #451a03; color: var(--warn); }}
    .btn {{ padding: 4px 12px; border-radius: 4px; border: none; cursor: pointer;
             font-size: 12px; font-family: inherit; margin-right: 4px; }}
    .btn-ok   {{ background: #166534; color: #86efac; }}
    .btn-no   {{ background: #7f1d1d; color: #fca5a5; }}
    .btn-ok:hover {{ background: #15803d; }}
    .btn-no:hover {{ background: #991b1b; }}
    .proc  {{ font-weight: 600; color: #a5f3fc; }}
    .remote{{ color: #fde68a; }}
    .ts    {{ color: var(--muted); font-size: 12px; }}
    .summary {{ color: var(--text); font-size: 13px; max-width: 400px; }}
    .count-badge {{ background: var(--crit); color: #fff; border-radius: 10px;
                    padding: 0 6px; font-size: 11px; margin-left: 6px; }}
    .refresh {{ float: right; color: var(--muted); font-size: 12px; }}
    a {{ color: var(--accent); text-decoration: none; }}
    .model-bar {{ display:flex; align-items:center; gap:10px; margin-bottom:20px;
                  padding:10px 14px; background:var(--surface); border-radius:8px;
                  border:1px solid var(--border); }}
    .model-bar label {{ color:var(--muted); font-size:12px; white-space:nowrap; }}
    .model-select {{ background:var(--bg); color:var(--text); border:1px solid var(--border);
                     border-radius:5px; padding:4px 8px; font-family:inherit; font-size:13px;
                     flex:1; cursor:pointer; }}
    .model-select:focus {{ outline:none; border-color:var(--accent); }}
    .tools-badge {{ font-size:11px; padding:2px 7px; border-radius:4px;
                    background:#1e3a2f; color:#4ade80; white-space:nowrap; }}
  </style>
</head>
<body>
  <h1>⚡ netmon</h1>
  <p class="meta">Network anomaly review panel &nbsp;·&nbsp; <a href="/">refresh</a>
    &nbsp;·&nbsp; <span class="refresh">auto-refreshes every 30s</span></p>

  <div class="model-bar">
    <label>🤖 LLM</label>
    <select class="model-select" id="model-select" onchange="setModel(this.value)">
      {model_options}
    </select>
    <span class="tools-badge">⚙ tool calling</span>
  </div>

  <div style="display:flex;align-items:center;gap:12px;margin-bottom:20px;">
    <div class="tabs" style="margin:0">
      <button class="tab active" onclick="show('pending')">
        Pending{pending_count}
      </button>
      <button class="tab" onclick="show('history')">History</button>
    </div>
    <button id="auto-btn" class="btn" onclick="toggleAuto()"
      style="margin-left:auto;padding:6px 14px;font-size:13px;border-radius:6px;border:1px solid;{auto_btn_style}">
      {auto_label}
    </button>
  </div>

  <div id="pending" class="section active">
    {pending_html}
  </div>
  <div id="history" class="section">
    {history_html}
  </div>

  <script>
    function show(id) {{
      document.querySelectorAll('.section').forEach(s => s.classList.remove('active'));
      document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
      document.getElementById(id).classList.add('active');
      event.target.classList.add('active');
    }}
    function act(id, action) {{
      fetch('/action', {{
        method: 'POST',
        headers: {{'Content-Type': 'application/json'}},
        body: JSON.stringify({{id, action}})
      }}).then(() => location.reload());
    }}
    function setModel(name) {{
      fetch('/config', {{
        method: 'POST',
        headers: {{'Content-Type': 'application/json'}},
        body: JSON.stringify({{model: name}})
      }});
    }}
    function toggleAuto() {{
      fetch('/config', {{
        method: 'POST',
        headers: {{'Content-Type': 'application/json'}},
        body: JSON.stringify({{toggle: 'autonomous_mode'}})
      }}).then(() => location.reload());
    }}
    setTimeout(() => location.reload(), 30000);
  </script>
</body>
</html>
"""

EVENTS_TABLE = """\
<table>
  <tr>
    <th>Time</th><th>Process</th><th>Remote</th>
    <th>Severity</th><th>Summary</th>{action_col}
  </tr>
  {rows}
</table>"""

EVENT_ROW = """\
<tr>
  <td class="ts">{ts}</td>
  <td class="proc">{process}</td>
  <td class="remote">{remote}</td>
  <td><span class="badge {severity}">{severity}</span></td>
  <td class="summary">{summary}</td>
  {action_cell}
</tr>"""

PENDING_ACTION_COL  = "<th>Action</th>"
PENDING_ACTION_CELL = """\
<td>
  <button class="btn btn-ok" onclick="act({id},'confirmed')">✓ Confirm</button>
  <button class="btn btn-no" onclick="act({id},'rejected')">✗ Reject</button>
</td>"""

HISTORY_STATUS_COL  = "<th>Status</th>"
HISTORY_STATUS_CELL = '<td><span class="badge {status}">{status}</span></td>'


def _render_table(events: list[dict], pending: bool) -> str:
    if not events:
        return '<p class="empty">No events.</p>'
    rows = []
    for e in events:
        action_cell = (
            PENDING_ACTION_CELL.format(id=e["id"]) if pending
            else HISTORY_STATUS_CELL.format(status=e.get("status",""))
        )
        rows.append(EVENT_ROW.format(
            ts          = e["ts"],
            process     = e["process"],
            remote      = e["remote"],
            severity    = e.get("severity","unknown"),
            summary     = e.get("summary","")[:120],
            action_cell = action_cell,
        ))
    return EVENTS_TABLE.format(
        action_col = PENDING_ACTION_COL if pending else HISTORY_STATUS_COL,
        rows       = "\n".join(rows),
    )


def _render_page() -> str:
    db.init()
    pending = db.get_pending()
    history = db.get_recent(limit=100)
    cnt     = len(pending)
    badge   = f'<span class="count-badge">{cnt}</span>' if cnt else ""
    cfg     = read_config()
    auto    = cfg.get("autonomous_mode", False)
    current_model = cfg.get("model", "granite4.1:3b")

    if auto:
        auto_label     = "🤖 Autonomous: ON"
        auto_btn_style = "background:#1e3a2f;color:#4ade80;border-color:#166534;"
    else:
        auto_label     = "👁 Review Mode"
        auto_btn_style = "background:#1a1d27;color:#8892a4;border-color:#2a2d3a;"

    models = list_ollama_models()
    tool_models = [m for m in models if m["tools"]]
    if not tool_models:
        tool_models = [{"name": current_model, "size": "?"}]

    options = []
    for m in tool_models:
        sel = ' selected' if m["name"] == current_model else ''
        options.append(f'<option value="{m["name"]}"{sel}>{m["name"]}  ({m["size"]})</option>')

    return HTML_TEMPLATE.format(
        pending_count  = badge,
        pending_html   = _render_table(pending, pending=True),
        history_html   = _render_table(history, pending=False),
        auto_label     = auto_label,
        auto_btn_style = auto_btn_style,
        model_options  = "\n      ".join(options),
    )


# ── HTTP handler ───────────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # silence access log

    def _respond(self, code: int, body: str, content_type: str = "text/html"):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", f"{content_type}; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self._respond(200, _render_page())
        elif self.path == "/api/events":
            db.init()
            cfg  = read_config()
            data = json.dumps({
                "pending": db.get_pending(),
                "recent":  db.get_recent(),
                "config":  cfg,
            })
            self._respond(200, data, "application/json")
        elif self.path == "/api/config":
            self._respond(200, json.dumps(read_config()), "application/json")
        elif self.path == "/api/models":
            self._respond(200, json.dumps(list_ollama_models()), "application/json")
        else:
            self._respond(404, "not found")

    def do_POST(self):
        if self.path == "/config":
            length = int(self.headers.get("Content-Length", 0))
            body   = json.loads(self.rfile.read(length))
            cfg    = read_config()
            if "toggle" in body:
                key     = body["toggle"]
                cfg[key] = not cfg.get(key, False)
            else:
                cfg.update(body)
            write_config(cfg)
            self._respond(200, json.dumps(cfg), "application/json")
        elif self.path == "/action":
            length = int(self.headers.get("Content-Length", 0))
            body   = json.loads(self.rfile.read(length))
            db.update_status(int(body["id"]), body["action"])

            # If confirmed, add to baseline
            if body["action"] == "confirmed":
                with db._conn() as c:
                    row = c.execute(
                        "SELECT process,remote FROM events WHERE id=?", (body["id"],)
                    ).fetchone()
                if row:
                    baseline = Path.home() / ".netmon" / "baseline.txt"
                    entry = f"{row['process']}|{row['remote']}"
                    if baseline.exists():
                        existing = set(baseline.read_text().splitlines())
                        if entry not in existing:
                            with baseline.open("a") as f:
                                f.write(entry + "\n")

            self._respond(200, '{"ok":true}', "application/json")
        else:
            self._respond(404, "not found")


# ── Entry ──────────────────────────────────────────────────────────────────────

def main():
    db.init()
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"netmon panel → http://localhost:{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
