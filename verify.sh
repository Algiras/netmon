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

# 5. Panel server responding
if curl -sf --max-time 3 http://localhost:6543/api/config > /dev/null 2>&1; then
    ok "panel server up (localhost:6543)"
else
    fail "panel server not responding — check: launchctl list com.user.netmon.panel"
fi

# 6. LaunchAgents loaded (scheduled jobs may have no PID between runs — check by label existence)
for label in com.user.netmon com.user.netmon.analyze com.user.netmon.panel com.user.netmon.menubar; do
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

# 7. Binary installed
BIN=/Applications/NetmonMenuBar.app/Contents/MacOS/NetmonMenuBar
[[ -x "$BIN" ]] && ok "binary: $BIN" || fail "binary missing: $BIN"

# 8. Ollama reachable
curl -sf --max-time 3 http://localhost:11434/api/tags > /dev/null 2>&1 \
    && ok "Ollama running" || fail "Ollama not running (brew services start ollama)"

echo ""
echo "  $PASS passed  ·  $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "✓ All checks passed." || { echo "✗ $FAIL check(s) need attention."; exit 1; }
