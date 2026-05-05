#!/usr/bin/env python3
"""
~/.netmon/panel.py — netmon review panel (http://localhost:6543)
Single-file web server. No external dependencies.
Reads/writes ~/.netmon/netmon.db via db.py.
"""

import json
import os
import re
import sys
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).parent))
import baseline as _baseline
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


RAG_CASCADE_SIM   = 0.88
_BLOCKED_META_FILE = Path.home() / ".netmon" / "blocked_ips_meta.json"


def _remove_blocked_meta(bare_ip: str):
    """Remove the metadata entry for an IP when it's unblocked."""
    if not _BLOCKED_META_FILE.exists():
        return
    try:
        meta = json.loads(_BLOCKED_META_FILE.read_text())
        if bare_ip in meta:
            del meta[bare_ip]
            _BLOCKED_META_FILE.write_text(json.dumps(meta, indent=2))
    except Exception:
        pass


def _cascade_decision(event_id: int, decision: str) -> int:
    """After a manual confirm/reject, auto-resolve similar pending events in one transaction."""
    return db.cascade_decision(event_id, decision, RAG_CASCADE_SIM)


def _ollama_available() -> bool:
    try:
        urllib.request.urlopen(
            urllib.request.Request("http://localhost:11434/api/tags"), timeout=3
        )
        return True
    except Exception:
        return False


def list_ollama_models() -> dict:
    """Return installed Ollama models split into llm (tools) and embed categories."""
    try:
        req = urllib.request.Request("http://localhost:11434/api/tags")
        with urllib.request.urlopen(req, timeout=5) as r:
            tags = json.loads(r.read())
    except Exception:
        return {"available": False, "llm": [], "embed": []}

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
    return {"available": True, "llm": llm, "embed": embed}

# ── HTTP handler ───────────────────────────────────────────────────────────────

_ALLOWED_ACTIONS     = {"confirmed", "rejected", "revert", "pending"}
_ALLOWED_CONFIG_KEYS = {"autonomous_mode", "llm_model", "embed_model", "abuseipdb_key",
                        "backend", "anthropic_api_key"}
_MODEL_RE            = re.compile(r"^[\w][\w.\-:/]{0,100}$")
MAX_BODY             = 65_536  # 64 KB — enough for any legitimate panel request


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

    def _check_host(self) -> bool:
        host = self.headers.get("Host", "")
        return host in ("localhost:6543", "127.0.0.1:6543")

    def do_GET(self):
        if not self._check_host():
            self._respond(403, '{"error":"forbidden"}', "application/json"); return
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
        elif self.path == "/api/blocked-ips":
            blocked_file = Path.home() / ".netmon" / "blocked_ips.txt"
            meta_file    = Path.home() / ".netmon" / "blocked_ips_meta.json"
            ips  = [ip for ip in (blocked_file.read_text().splitlines() if blocked_file.exists() else []) if ip.strip()]
            try:
                meta = json.loads(meta_file.read_text()) if meta_file.exists() else {}
            except Exception:
                meta = {}
            entries = [{"ip": ip, **meta.get(ip, {})} for ip in ips]
            self._respond(200, json.dumps({"ips": entries}), "application/json")
        else:
            self._respond(404, "not found")

    def do_POST(self):
        if not self._check_host():
            self._respond(403, '{"error":"forbidden"}', "application/json"); return
        length = min(int(self.headers.get("Content-Length", 0)), MAX_BODY)
        try:
            raw_body = json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, ValueError):
            self._respond(400, '{"error":"invalid JSON"}', "application/json"); return
        if self.path == "/config":
            body   = raw_body
            cfg    = read_config()
            clear_emb = body.pop("_clear_embeddings", False)
            if "toggle" in body:
                key = body["toggle"]
                if key == "autonomous_mode" and not cfg.get("autonomous_mode", False):
                    backend = cfg.get("backend", "ollama")
                    if backend == "claude":
                        import os as _os
                        api_key = cfg.get("anthropic_api_key", "") or _os.environ.get("ANTHROPIC_API_KEY", "")
                        if not api_key:
                            self._respond(409,
                                json.dumps({"error": "No ANTHROPIC_API_KEY configured — cannot enable autonomous mode"}),
                                "application/json")
                            return
                    elif not _ollama_available():
                        self._respond(409,
                            json.dumps({"error": "Ollama not available — cannot enable autonomous mode"}),
                            "application/json")
                        return
                cfg[key] = not cfg.get(key, False)
            else:
                # Allowlist keys and validate model name format
                for k, v in body.items():
                    if k not in _ALLOWED_CONFIG_KEYS:
                        continue
                    if k in ("llm_model", "embed_model") and not _MODEL_RE.fullmatch(str(v)):
                        continue
                    cfg[k] = v
            write_config(cfg)
            if clear_emb:
                db.init()
                db.clear_embeddings()
            self._respond(200, json.dumps(cfg), "application/json")
        elif self.path == "/action":
            body   = raw_body
            action = body.get("action", "")
            if action not in _ALLOWED_ACTIONS:
                self._respond(400, '{"error":"invalid action"}', "application/json"); return

            try:
                event_id = int(body["id"])
                if event_id <= 0:
                    raise ValueError
            except (KeyError, TypeError, ValueError):
                self._respond(400, '{"error":"invalid id"}', "application/json"); return

            with db._conn() as c:
                row = c.execute(
                    "SELECT process,remote,status FROM events WHERE id=?", (event_id,)
                ).fetchone()

            if row is None:
                self._respond(404, '{"error":"event not found"}', "application/json"); return

            if action != "revert":
                db.update_status(event_id, action)
                if action in ("confirmed", "rejected"):
                    _cascade_decision(event_id, action)

            # If confirmed, add to baseline (sorted — comm requires sorted input)
            if action == "confirmed" and row:
                _baseline.add_entry(
                    Path.home() / ".netmon" / "baseline.txt",
                    f"{row['process']}|{row['remote']}",
                )

            # Revert: reset to pending, undo baseline/block side-effects
            if action == "revert" and row:
                db.update_status(event_id, "pending")
                _baseline.remove_entry(
                    Path.home() / ".netmon" / "baseline.txt",
                    f"{row['process']}|{row['remote']}",
                )
                # Remove IP from blocked list + metadata if it was rejected
                blocked_file = Path.home() / ".netmon" / "blocked_ips.txt"
                bare_ip = row['remote'].split(":")[0]
                if blocked_file.exists():
                    ips = blocked_file.read_text().splitlines()
                    new_ips = [ip for ip in ips if ip.strip() != bare_ip]
                    if len(new_ips) != len(ips):
                        blocked_file.write_text("\n".join(new_ips) + ("\n" if new_ips else ""))
                        _remove_blocked_meta(bare_ip)
                self._respond(200, '{"ok":true}', "application/json")
                return

            self._respond(200, '{"ok":true}', "application/json")
        elif self.path == "/unblock-ip":
            body    = raw_body
            bare_ip = str(body.get("ip", "")).strip()
            import ipaddress as _ipmod
            try:
                bare_ip = str(_ipmod.ip_address(bare_ip))
            except ValueError:
                self._respond(400, '{"error":"invalid ip"}', "application/json"); return
            blocked_file = Path.home() / ".netmon" / "blocked_ips.txt"
            if blocked_file.exists():
                ips = blocked_file.read_text().splitlines()
                new_ips = [ip for ip in ips if ip.strip() != bare_ip]
                blocked_file.write_text("\n".join(new_ips) + ("\n" if new_ips else ""))
            _remove_blocked_meta(bare_ip)
            self._respond(200, '{"ok":true}', "application/json")
        elif self.path == "/recheck":
            cfg = read_config()
            if not cfg.get("autonomous_mode", False):
                self._respond(409,
                    '{"error":"recheck only available in autonomous mode"}',
                    "application/json")
                return
            analyze_script = Path.home() / ".netmon" / "analyze.py"
            import subprocess as _sp
            _sp.Popen(
                [sys.executable, str(analyze_script), "--recheck"],
                stdout=_sp.DEVNULL, stderr=_sp.DEVNULL,
            )
            self._respond(200, '{"ok":true,"message":"recheck started"}', "application/json")
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
