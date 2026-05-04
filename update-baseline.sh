#!/usr/bin/env bash
# ~/.netmon/update-baseline.sh
# Run this after reviewing the anomaly log to approve new connections.
# Merges the last captured snapshot into the baseline.

NETMON_DIR="$HOME/.netmon"
BASELINE="$NETMON_DIR/baseline.txt"
CURRENT="$NETMON_DIR/.current.tmp"
LOG="$NETMON_DIR/anomalies.log"

if [ ! -f "$CURRENT" ]; then
  echo "No snapshot found. Wait for monitor.sh to run first."
  exit 1
fi

BEFORE=$(wc -l < "$BASELINE" | tr -d ' ')
sort -u "$BASELINE" "$CURRENT" > "${BASELINE}.new"
mv "${BASELINE}.new" "$BASELINE"
AFTER=$(wc -l < "$BASELINE" | tr -d ' ')
ADDED=$((AFTER - BEFORE))

echo "[$(date '+%Y-%m-%d %H:%M:%S')] [BASELINE] Updated: +$ADDED new entries (total $AFTER)" | tee -a "$LOG"
echo "Baseline now has $AFTER entries (+$ADDED added)."
