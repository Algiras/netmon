#!/usr/bin/env bash
# ~/.netmon/setup-pf.sh
# Grants netmon permission to manage a dedicated pf firewall table.
# Run once. Requires sudo for the sudoers entry and pf anchor setup.
set -euo pipefail

NETMON_DIR="$HOME/.netmon"
SUDOERS_FILE="/etc/sudoers.d/netmon"
ANCHOR_FILE="/etc/pf.anchors/netmon"
PF_CONF="/etc/pf.conf"
USER_NAME="$(whoami)"

cat <<INFO

netmon pf enforcement setup
─────────────────────────────────────────────────────────────────
This script will:

  1. Create a pf anchor file at $ANCHOR_FILE
     (blocks outbound traffic to IPs in the netmon_blocked table)

  2. Add "anchor netmon" to $PF_CONF so the rules survive reboots

  3. Write $SUDOERS_FILE
     Grants ONLY these two pfctl commands without a password:
       sudo pfctl -t netmon_blocked -T add <ip>
       sudo pfctl -t netmon_blocked -T delete <ip>
     No other sudo rights are granted.

  4. Enable pf_enforcement in ~/.netmon/config.json

Nothing is changed in your firewall until you explicitly block an IP
from the netmon review panel or via the AI's block_ip tool.
─────────────────────────────────────────────────────────────────
INFO

read -r -p "Continue? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted — no changes made."
    exit 0
fi

# ── 1. Create pf anchor rules ─────────────────────────────────────────────────
echo "==> Creating pf anchor at $ANCHOR_FILE…"
sudo tee "$ANCHOR_FILE" > /dev/null <<'RULES'
# netmon anchor — blocks outbound connections to manually blocked IPs
table <netmon_blocked> persist
block out quick proto { tcp udp } from any to <netmon_blocked>
RULES
echo "    done."

# ── 2. Wire anchor into pf.conf if not already present ────────────────────────
echo "==> Checking pf.conf…"
if ! sudo grep -q 'anchor "netmon"' "$PF_CONF" 2>/dev/null; then
    echo "    Adding anchor line to $PF_CONF"
    sudo sh -c "printf '\nanchor \"netmon\"\nload anchor \"netmon\" from \"$ANCHOR_FILE\"\n' >> $PF_CONF"
else
    echo "    anchor already in pf.conf — skipping."
fi

# ── 3. Add scoped sudoers entry ───────────────────────────────────────────────
echo "==> Writing $SUDOERS_FILE…"
sudo tee "$SUDOERS_FILE" > /dev/null <<SUDOERS
# netmon — allow managing the netmon_blocked pf table without a password.
# Scope is intentionally narrow: only add/delete from this specific table.
$USER_NAME ALL=(ALL) NOPASSWD: \\
    /sbin/pfctl -t netmon_blocked -T add *, \\
    /sbin/pfctl -t netmon_blocked -T delete *
SUDOERS
sudo chmod 440 "$SUDOERS_FILE"
echo "    done."

# ── 4. Enable pf_enforcement in config ───────────────────────────────────────
echo "==> Enabling pf_enforcement in config…"
CONFIG_FILE="$NETMON_DIR/config.json"
if [ -f "$CONFIG_FILE" ]; then
    python3 - "$CONFIG_FILE" <<'PY'
import json, sys
path = sys.argv[1]
cfg = json.loads(open(path).read())
cfg["pf_enforcement"] = True
open(path, "w").write(json.dumps(cfg, indent=2))
PY
else
    echo '{"pf_enforcement": true}' > "$CONFIG_FILE"
fi
echo "    done."

# ── 5. Load anchor now (best effort) ─────────────────────────────────────────
echo "==> Loading pf anchor…"
sudo pfctl -a netmon -f "$ANCHOR_FILE" 2>/dev/null && echo "    loaded." || echo "    (pf may not be running — rules will apply after next reboot or 'sudo pfctl -e')"

echo ""
echo "✓ Setup complete. netmon will now enforce IP blocks at the firewall level."
echo "  To disable: toggle 'Network enforcement' off in the netmon Settings tab."
echo "  To uninstall: sudo rm $SUDOERS_FILE $ANCHOR_FILE"
