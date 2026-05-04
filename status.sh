#!/usr/bin/env bash
# ~/.netmon/status.sh — show monitoring status and recent anomalies

NETMON_DIR="$HOME/.netmon"
BASELINE="$NETMON_DIR/baseline.txt"
LOG="$NETMON_DIR/anomalies.log"

echo "=== netmon status ==="
if [ -f "$BASELINE" ]; then
  echo "Baseline: $(wc -l < "$BASELINE" | tr -d ' ') known entries"
else
  echo "Baseline: not yet created"
fi

PLIST="$HOME/Library/LaunchAgents/com.user.netmon.plist"
if launchctl list com.user.netmon 2>/dev/null | grep -q '"Label"'; then
  echo "Daemon:   running (launchd)"
else
  echo "Daemon:   NOT loaded"
fi

echo ""
echo "=== last 20 anomalies ==="
if [ -f "$LOG" ]; then
  grep '\[ANOMALY\]' "$LOG" | tail -20
  echo ""
  echo "Total anomalies: $(grep -c '\[ANOMALY\]' "$LOG")"
else
  echo "(no log yet)"
fi
