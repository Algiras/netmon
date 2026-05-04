#!/usr/bin/env bash
# ~/.netmon/monitor.sh — network anomaly detector
# Runs every 60s via launchd. Alerts on process->IP pairs not in baseline.

NETMON_DIR="$HOME/.netmon"
BASELINE="$NETMON_DIR/baseline.txt"
LOG="$NETMON_DIR/anomalies.log"
CURRENT="$NETMON_DIR/.current.tmp"
MAX_LOG_LINES=5000

mkdir -p "$NETMON_DIR"

# Capture ESTABLISHED IPv4 connections: "process|remote_ip:port"
# Uses NF-1 (second-to-last field) which is always the address in lsof -n -P output
lsof -i 4 -n -P 2>/dev/null \
  | awk '/ESTABLISHED/ && $(NF-1) ~ /->/ {
      split($(NF-1), a, "->")
      print $1 "|" a[2]
    }' \
  | grep -v '127\.0\.0\.1:\|^$' \
  | sort -u > "$CURRENT"

# First run: create baseline and exit
if [ ! -f "$BASELINE" ]; then
  cp "$CURRENT" "$BASELINE"
  COUNT=$(wc -l < "$BASELINE" | tr -d ' ')
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INIT] Baseline created with $COUNT entries" >> "$LOG"
  exit 0
fi

# Find connections present now but not in baseline
ANOMALIES=$(comm -23 "$CURRENT" "$BASELINE")

if [ -n "$ANOMALIES" ]; then
  TS=$(date '+%Y-%m-%d %H:%M:%S')
  NOTIF_LINES=()

  while IFS='|' read -r proc remote; do
    [ -z "$proc" ] && continue
    echo "[$TS] [ANOMALY] $proc -> $remote" | tee -a "$LOG"
    NOTIF_LINES+=("$proc → $remote")
  done <<< "$ANOMALIES"

  if [ ${#NOTIF_LINES[@]} -gt 0 ]; then
    # Show up to 3 connections in the notification
    MSG=$(printf '%s\n' "${NOTIF_LINES[@]}" | head -3 | paste -sd ', ' -)
    [ ${#NOTIF_LINES[@]} -gt 3 ] && MSG="$MSG (+$((${#NOTIF_LINES[@]}-3)) more)"
    osascript -e "display notification \"$MSG\" with title \"⚠️ New Network Connection\" sound name \"Basso\"" 2>/dev/null
  fi
fi

# Rotate log to avoid unbounded growth
if [ -f "$LOG" ]; then
  LINE_COUNT=$(wc -l < "$LOG" | tr -d ' ')
  if [ "$LINE_COUNT" -gt "$MAX_LOG_LINES" ]; then
    tail -n $((MAX_LOG_LINES / 2)) "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
  fi
fi
