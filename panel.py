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

PORT        = 6543
CONFIG_FILE = Path.home() / ".netmon" / "config.json"


def read_config() -> dict:
    try:
        return json.loads(CONFIG_FILE.read_text())
    except Exception:
        return {"autonomous_mode": False}


def write_config(data: dict):
    CONFIG_FILE.write_text(json.dumps(data, indent=2))


def list_ollama_models() -> dict:
    """Return installed Ollama models split into llm (tools) and embed categories."""
    try:
        req = urllib.request.Request("http://localhost:11434/api/tags")
        with urllib.request.urlopen(req, timeout=5) as r:
            tags = json.loads(r.read())
    except Exception:
        return {"llm": [], "embed": []}

    llm, embed = [], []
    for m in tags.get("models", []):
        name = m["name"]
        size = m.get("details", {}).get("parameter_size", "?")
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
        except Exception:
            caps = []
        entry = {"name": name, "size": size, "caps": caps}
        if "tools" in caps:
            llm.append(entry)
        elif "embedding" in caps:
            embed.append(entry)
    return {"llm": llm, "embed": embed}

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
        if self.path == "/api/events":
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
            data = {**list_ollama_models(), "config": read_config()}
            self._respond(200, json.dumps(data), "application/json")
        else:
            self._respond(404, "not found")

    def do_POST(self):
        if self.path == "/config":
            length = int(self.headers.get("Content-Length", 0))
            body   = json.loads(self.rfile.read(length))
            cfg    = read_config()
            clear_emb = body.pop("_clear_embeddings", False)
            if "toggle" in body:
                key      = body["toggle"]
                cfg[key] = not cfg.get(key, False)
            else:
                cfg.update(body)
            write_config(cfg)
            if clear_emb:
                db.init()
                db.clear_embeddings()
            self._respond(200, json.dumps(cfg), "application/json")
        elif self.path == "/action":
            length = int(self.headers.get("Content-Length", 0))
            body   = json.loads(self.rfile.read(length))
            db.update_status(int(body["id"]), body["action"])

            action = body["action"]

            with db._conn() as c:
                row = c.execute(
                    "SELECT process,remote,status FROM events WHERE id=?", (body["id"],)
                ).fetchone()

            # If confirmed, add to baseline
            if action == "confirmed" and row:
                baseline = Path.home() / ".netmon" / "baseline.txt"
                entry = f"{row['process']}|{row['remote']}"
                if baseline.exists():
                    existing = set(baseline.read_text().splitlines())
                    if entry not in existing:
                        with baseline.open("a") as f:
                            f.write(entry + "\n")

            # Revert: reset to pending, undo baseline/block side-effects
            if action == "revert" and row:
                db.update_status(int(body["id"]), "pending")
                # Remove from baseline if it was confirmed
                baseline = Path.home() / ".netmon" / "baseline.txt"
                entry = f"{row['process']}|{row['remote']}"
                if baseline.exists():
                    lines = baseline.read_text().splitlines()
                    new_lines = [l for l in lines if l.strip() != entry]
                    if len(new_lines) != len(lines):
                        baseline.write_text("\n".join(new_lines) + ("\n" if new_lines else ""))
                # Remove IP from blocked list if it was rejected
                blocked_file = Path.home() / ".netmon" / "blocked_ips.txt"
                bare_ip = row['remote'].split(":")[0]
                if blocked_file.exists():
                    ips = blocked_file.read_text().splitlines()
                    new_ips = [ip for ip in ips if ip.strip() != bare_ip]
                    if len(new_ips) != len(ips):
                        blocked_file.write_text("\n".join(new_ips) + ("\n" if new_ips else ""))
                self._respond(200, '{"ok":true}', "application/json")
                return

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
