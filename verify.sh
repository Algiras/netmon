#!/usr/bin/env bash
# ~/.netmon/verify.sh — quick system smoke-check; run after build or deploy
set -euo pipefail
NETMON="$HOME/.netmon"
PY=/opt/homebrew/bin/python3
PASS=0; FAIL=0

ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

echo "==> netmon verify"

# 1. Python version
PY_VER=$("$PY" -c "import sys; print(sys.version_info.major * 100 + sys.version_info.minor)")
PY_DISP=$("$PY" --version 2>&1)
if [[ "$PY_VER" -ge 310 ]]; then ok "$PY_DISP"; else fail "Need Python 3.10+, got $PY_DISP"; fi

# 2. Python syntax check on all .py files
for f in "$NETMON"/*.py; do
    "$PY" -m py_compile "$f" 2>/dev/null && ok "syntax: $(basename "$f")" || fail "syntax error: $f"
done

# 3. Module imports work
"$PY" -c "import sys; sys.path.insert(0,'$NETMON'); import db, embed, panel, analyze" \
    && ok "all modules import cleanly" || fail "module import failed"

# 4. Unit tests
_pt=$("$PY" -m pytest "$NETMON/tests/" -q --tb=no 2>&1 | tail -1)
echo "$_pt" | grep -q "passed" \
    && ok "unit tests: $_pt" \
    || fail "unit tests failed — run: python3 -m pytest $NETMON/tests/ -v"

# 5. File permissions on sensitive files
for f in "$NETMON/config.json" "$NETMON/panel_token" "$NETMON/baseline.sha256"; do
    [[ -f "$f" ]] || continue
    perms=$(stat -f "%OLp" "$f" 2>/dev/null || stat -c "%a" "$f" 2>/dev/null)
    if [[ "$perms" == "600" ]]; then
        ok "permissions 0600: $(basename "$f")"
    else
        fail "permissions $perms (want 600): $(basename "$f")"
    fi
done

# 6. Baseline tamper detection — sha256 file must exist and match
BASELINE="$NETMON/baseline.txt"
CHECKSUM="$NETMON/baseline.sha256"
if [[ -f "$BASELINE" && -f "$CHECKSUM" ]]; then
    actual=$(shasum -a 256 "$BASELINE" | awk '{print $1}')
    stored=$(cat "$CHECKSUM")
    if [[ "$actual" == "$stored" ]]; then
        ok "baseline.txt checksum matches"
    else
        fail "baseline.txt tampered (checksum mismatch!)"
    fi
elif [[ -f "$BASELINE" ]]; then
    fail "baseline.sha256 missing — open panel to generate"
else
    ok "no baseline.txt yet (first run)"
fi

# 7. Panel auth token present and correct length (64 hex chars)
TOKEN_FILE="$NETMON/panel_token"
if [[ -f "$TOKEN_FILE" ]]; then
    tok=$(cat "$TOKEN_FILE")
    if [[ ${#tok} -eq 64 && "$tok" =~ ^[0-9a-f]+$ ]]; then
        ok "panel_token valid (64 hex chars)"
    else
        fail "panel_token invalid format (got ${#tok} chars)"
    fi
else
    fail "panel_token missing — start the panel service to create it"
fi

# 8. Panel server: unauthenticated request → 401
_TOKEN="$(cat "$NETMON/panel_token" 2>/dev/null || echo '')"
_status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 \
    -H "Host: localhost:6543" http://localhost:6543/api/config 2>/dev/null || echo "000")
if [[ "$_status" == "401" ]]; then
    ok "panel rejects unauthenticated requests (401)"
else
    fail "panel did not return 401 for unauthenticated request (got $_status)"
fi

# 9. Panel server: wrong token → 401
_bad=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 \
    -H "Host: localhost:6543" -H "X-Netmon-Token: deadbeef" \
    http://localhost:6543/api/config 2>/dev/null || echo "000")
if [[ "$_bad" == "401" ]]; then
    ok "panel rejects wrong token (401)"
else
    fail "panel wrong-token check failed (got $_bad)"
fi

# 10. Panel server: correct token → 200
if curl -sf --max-time 3 \
    -H "Host: localhost:6543" -H "X-Netmon-Token: $_TOKEN" \
    http://localhost:6543/api/config > /dev/null 2>&1; then
    ok "panel server up and authenticated (localhost:6543)"
else
    fail "panel server not responding — check: launchctl list com.user.netmon.panel"
fi

# 11. IP validation: private IPs rejected, TEST-NET IPs allowed
_ip_check=$("$PY" -c "
import sys; sys.path.insert(0,'$NETMON'); import analyze
errors = []
for ip in ['10.0.0.1','172.16.0.1','192.168.1.1']:
    try:
        analyze._validate_ip(ip)
        errors.append(f'RFC1918 {ip} not rejected')
    except ValueError: pass
for ip in ['198.51.100.1','203.0.113.5','1.1.1.1']:
    try:
        analyze._validate_ip(ip)
    except ValueError as e:
        errors.append(f'Public {ip} wrongly rejected: {e}')
print('OK' if not errors else '; '.join(errors))
" 2>&1)
if [[ "$_ip_check" == "OK" ]]; then
    ok "IP validation: RFC1918 blocked, TEST-NET/public allowed"
else
    fail "IP validation issue: $_ip_check"
fi

# 12. Sudoers file present and covers tcpdump + pfctl
SUDOERS_FILE="/etc/sudoers.d/netmon"
if [[ -f "$SUDOERS_FILE" ]]; then
    perms=$(stat -f "%OLp" "$SUDOERS_FILE" 2>/dev/null || stat -c "%a" "$SUDOERS_FILE" 2>/dev/null)
    if [[ "$perms" == "440" || "$perms" == "400" ]]; then
        ok "sudoers file present (mode $perms): $SUDOERS_FILE"
    else
        fail "sudoers file has wrong permissions ($perms, want 440): $SUDOERS_FILE"
    fi
    if grep -q "tcpdump" "$SUDOERS_FILE" 2>/dev/null; then
        ok "sudoers covers tcpdump (DNS monitor)"
    else
        fail "sudoers missing tcpdump entry — DNS monitor will fail to start"
    fi
else
    fail "sudoers not configured: $SUDOERS_FILE missing — run install.sh or see docs/security/dns-exfil.md"
fi

# 13. dns_monitor syntax and import
"$PY" -m py_compile "$NETMON/dns_monitor.py" 2>/dev/null \
    && ok "syntax: dns_monitor.py" || fail "syntax error: dns_monitor.py"

# 14. LaunchAgents loaded
for label in com.user.netmon com.user.netmon.analyze com.user.netmon.panel com.user.netmon.menubar com.user.netmon.dns; do
    info=$(launchctl list "$label" 2>/dev/null || true)
    if [[ -z "$info" ]]; then
        fail "LaunchAgent not loaded: $label"
    else
        pid=$(echo "$info" | grep '"PID"' | grep -o '[0-9]*' || true)
        on_demand=$(echo "$info" | grep -q '"OnDemand" = true' && echo yes || true)
        if [[ -n "$pid" ]]; then
            ok "LaunchAgent $label (pid $pid)"
        elif [[ "$on_demand" == "yes" ]]; then
            ok "LaunchAgent $label (scheduled, idle between runs)"
        else
            fail "LaunchAgent $label loaded but not running"
        fi
    fi
done

# 15. Binary installed
BIN=/Applications/NetmonMenuBar.app/Contents/MacOS/NetmonMenuBar
[[ -x "$BIN" ]] && ok "binary: $BIN" || fail "binary missing: $BIN"

# 16. Ollama reachable
curl -sf --max-time 3 http://localhost:11434/api/tags > /dev/null 2>&1 \
    && ok "Ollama running" || fail "Ollama not running (brew services start ollama)"

# 17. pf status (informational — not a hard failure)
if sudo pfctl -s tables 2>/dev/null | grep -q "netmon_blocked"; then
    count=$(sudo pfctl -t netmon_blocked -T show 2>/dev/null | wc -l | tr -d ' ')
    ok "pf anchor netmon_blocked active ($count entries)"
else
    ok "pf anchor not loaded (pf_enforcement likely off)"
fi

echo ""
echo "  $PASS passed  ·  $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "✓ All checks passed." || { echo "✗ $FAIL check(s) need attention."; exit 1; }
