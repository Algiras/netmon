#!/usr/bin/env bash
# ~/.netmon/monitor.sh — network anomaly detector
# Runs every 60s via launchd. Alerts on process->IP pairs not in baseline.

NETMON_DIR="$HOME/.netmon"
BASELINE="$NETMON_DIR/baseline.txt"
LOG="$NETMON_DIR/anomalies.log"
CURRENT="$NETMON_DIR/.current.tmp"
MAX_LOG_LINES=5000

mkdir -p "$NETMON_DIR"

# Baseline tamper detection: verify SHA256 checksum before doing anything
CHECKSUM_FILE="$HOME/.netmon/baseline.sha256"
if [ -f "$CHECKSUM_FILE" ] && [ -f "$BASELINE" ]; then
    EXPECTED=$(cat "$CHECKSUM_FILE")
    ACTUAL=$(shasum -a 256 "$BASELINE" | cut -d' ' -f1)
    if [ "$EXPECTED" != "$ACTUAL" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [TAMPER_ALERT] baseline.txt checksum mismatch — possible tampering detected" >> "$HOME/.netmon/anomalies.log"
        osascript -e 'display notification "baseline.txt checksum mismatch — possible tampering" with title "⚡ netmon SECURITY ALERT" sound name "Basso"' 2>/dev/null || true
    fi
fi

# Capture ESTABLISHED TCP connections (IPv4 + IPv6): "process|remote_ip:port"
# Uses NF-1 (second-to-last field) which is always the address in lsof -n -P output
lsof -i tcp -n -P 2>/dev/null \
  | awk '/ESTABLISHED/ && $(NF-1) ~ /->/ {
      split($(NF-1), a, "->")
      print $1 "|" a[2]
    }' \
  | grep -v '127\.0\.0\.1:\|^\[::1\]\|^$' \
  | sort -u > "$CURRENT"

# First run: create baseline and exit
if [ ! -f "$BASELINE" ]; then
  cp "$CURRENT" "$BASELINE"
  COUNT=$(wc -l < "$BASELINE" | tr -d ' ')
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INIT] Baseline created with $COUNT entries" >> "$LOG"
  exit 0
fi

# Ensure baseline is sorted (comm requires sorted input on both sides)
sort -u "$BASELINE" -o "$BASELINE"

# Find connections present now but not in baseline
ANOMALIES=$(comm -23 "$CURRENT" "$BASELINE")

if [ -n "$ANOMALIES" ]; then
  TS=$(date '+%Y-%m-%d %H:%M:%S')
  NOTIF_LINES=()

  # Rate limiting: max 20 anomaly lines per unique process per cycle
  declare -A _PROC_COUNT
  declare -A _PROC_CAPPED

  while IFS='|' read -r proc remote; do
    [ -z "$proc" ] && continue
    _PROC_COUNT["$proc"]=$(( ${_PROC_COUNT["$proc"]:-0} + 1 ))
    if [ "${_PROC_COUNT["$proc"]}" -gt 20 ]; then
      if [ -z "${_PROC_CAPPED["$proc"]}" ]; then
        echo "[$TS] [RATE_LIMITED] $proc exceeded 20 anomalies this cycle" | tee -a "$LOG"
        _PROC_CAPPED["$proc"]=1
      fi
      continue
    fi
    echo "[$TS] [ANOMALY] $proc -> $remote" | tee -a "$LOG"
    NOTIF_LINES+=("$proc → $remote")
  done <<< "$ANOMALIES"

  if [ ${#NOTIF_LINES[@]} -gt 0 ]; then
    # Show up to 3 connections in the notification
    MSG=$(printf '%s\n' "${NOTIF_LINES[@]}" | head -3 | paste -sd ',' - | sed 's/,/, /g')
    [ ${#NOTIF_LINES[@]} -gt 3 ] && MSG="$MSG (+$((${#NOTIF_LINES[@]}-3)) more)"
    SAFE_MSG="${MSG//\\/\\\\}"  # escape backslashes first
    SAFE_MSG="${SAFE_MSG//\"/\'}"
    osascript -e "display notification \"$SAFE_MSG\" with title \"⚠️ New Network Connection\" sound name \"Basso\"" 2>/dev/null
  fi
fi

# Volume spike check (runs after baseline comparison so the counts file is always fresh)
python3 "$NETMON_DIR/volume_check.py" 2>/dev/null

# Rotate log to avoid unbounded growth
if [ -f "$LOG" ]; then
  LINE_COUNT=$(wc -l < "$LOG" | tr -d ' ')
  if [ "$LINE_COUNT" -gt "$MAX_LOG_LINES" ]; then
    tail -n $((MAX_LOG_LINES / 2)) "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
  fi
fi
