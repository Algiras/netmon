#!/usr/bin/env bash
# install.sh — set up netmon from scratch on a new machine
set -e

NETMON="$HOME/.netmon"
AGENTS="$HOME/Library/LaunchAgents"

echo "==> Checking dependencies..."
command -v python3 >/dev/null || { echo "✗ python3 not found (brew install python)"; exit 1; }
command -v ollama  >/dev/null || { echo "✗ ollama not found (brew install ollama)"; exit 1; }
command -v xcrun   >/dev/null || { echo "✗ Xcode CLT not found (xcode-select --install)"; exit 1; }

PY=$(command -v python3)
echo "  python3: $PY ($(python3 --version))"

echo ""
echo "==> Pulling Ollama models..."
ollama pull granite4.1:3b
ollama pull nomic-embed-text-v2-moe

echo ""
echo "==> Installing Python dependencies..."
pip3 install -q --upgrade pip
pip3 install -q -r "$NETMON/requirements.txt"

echo ""
echo "==> Writing LaunchAgent plists..."
mkdir -p "$AGENTS"

write_plist() {
    local label="$1" program="$2" args="$3" interval="$4"
    local file="$AGENTS/${label}.plist"
    local prog_args="    <string>$program</string>"
    if [ -n "$args" ]; then
        prog_args="$prog_args
    <string>$args</string>"
    fi
    cat > "$file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
${prog_args}
  </array>
  <key>RunAtLoad</key>
  <true/>
  $([ -n "$interval" ] && echo "<key>StartInterval</key><integer>$interval</integer>" || echo "<key>KeepAlive</key><true/>")
  <key>WorkingDirectory</key>
  <string>${NETMON}</string>
  <key>StandardOutPath</key>
  <string>${NETMON}/$(echo $label | sed 's/com.user.netmon.//').log</string>
  <key>StandardErrorPath</key>
  <string>${NETMON}/$(echo $label | sed 's/com.user.netmon.//').err</string>
</dict>
</plist>
EOF
    echo "  ✓ $file"
}

write_plist "com.user.netmon" "$PY" "$NETMON/monitor.sh" ""
# monitor.sh uses bash so special-case it
cat > "$AGENTS/com.user.netmon.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.user.netmon</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${NETMON}/monitor.sh</string>
  </array>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${NETMON}/monitor.log</string>
  <key>StandardErrorPath</key>
  <string>${NETMON}/monitor.err</string>
</dict>
</plist>
EOF

cat > "$AGENTS/com.user.netmon.analyze.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.user.netmon.analyze</string>
  <key>ProgramArguments</key>
  <array>
    <string>${PY}</string>
    <string>${NETMON}/analyze.py</string>
  </array>
  <key>StartInterval</key>
  <integer>300</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>WorkingDirectory</key>
  <string>${NETMON}</string>
  <key>StandardOutPath</key>
  <string>${NETMON}/analyze.log</string>
  <key>StandardErrorPath</key>
  <string>${NETMON}/analyze.err</string>
</dict>
</plist>
EOF

cat > "$AGENTS/com.user.netmon.panel.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.user.netmon.panel</string>
  <key>ProgramArguments</key>
  <array>
    <string>${PY}</string>
    <string>${NETMON}/panel.py</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>WorkingDirectory</key>
  <string>${NETMON}</string>
  <key>StandardOutPath</key>
  <string>${NETMON}/panel.log</string>
  <key>StandardErrorPath</key>
  <string>${NETMON}/panel.err</string>
</dict>
</plist>
EOF

cat > "$AGENTS/com.user.netmon.heartbeat.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.user.netmon.heartbeat</string>
  <key>ProgramArguments</key>
  <array>
    <string>${PY}</string>
    <string>${NETMON}/analyze.py</string>
    <string>--recheck</string>
  </array>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>WorkingDirectory</key>
  <string>${NETMON}</string>
  <key>StandardOutPath</key>
  <string>${NETMON}/analysis.log</string>
  <key>StandardErrorPath</key>
  <string>${NETMON}/analyze.err</string>
</dict>
</plist>
EOF
echo "  ✓ $AGENTS/com.user.netmon.heartbeat.plist"

cat > "$AGENTS/com.user.netmon.menubar.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.user.netmon.menubar</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Applications/NetmonMenuBar.app/Contents/MacOS/NetmonMenuBar</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${NETMON}/menubar.log</string>
  <key>StandardErrorPath</key>
  <string>${NETMON}/menubar.err</string>
</dict>
</plist>
EOF
echo "  ✓ $AGENTS/com.user.netmon.menubar.plist"

echo ""
echo "==> Writing watchdog script..."
cat > "$NETMON/watchdog.sh" << 'WATCHDOG_EOF'
#!/usr/bin/env bash
# watchdog.sh — alert if netmon processes are not running
NETMON="$HOME/.netmon"

check_process() {
    local name="$1"
    local label="$2"
    if ! pgrep -f "$name" > /dev/null 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WATCHDOG] $label is not running" >> "$NETMON/watchdog.log"
        osascript -e "display notification \"$label has stopped — network monitoring may be inactive\" with title \"⚡ netmon WARNING\" sound name \"Basso\"" 2>/dev/null || true
    fi
}

check_process "monitor.sh" "monitor"
check_process "panel.py" "panel server"
WATCHDOG_EOF
chmod +x "$NETMON/watchdog.sh"
echo "  ✓ $NETMON/watchdog.sh"

cat > "$AGENTS/com.user.netmon.watchdog.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.user.netmon.watchdog</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${NETMON}/watchdog.sh</string>
  </array>
  <key>StartInterval</key>
  <integer>300</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${NETMON}/watchdog.log</string>
  <key>StandardErrorPath</key>
  <string>${NETMON}/watchdog.err</string>
</dict>
</plist>
EOF
echo "  ✓ $AGENTS/com.user.netmon.watchdog.plist"

echo ""
echo "==> Writing sudoers rules for pfctl + tcpdump..."
PFCTL_BIN=$(command -v pfctl 2>/dev/null || echo "/sbin/pfctl")
TCPDUMP_BIN=$(command -v tcpdump 2>/dev/null || echo "/usr/sbin/tcpdump")
CURRENT_USER=$(whoami)
SUDOERS_FILE="/etc/sudoers.d/netmon"
TMP_SUDOERS=$(mktemp)
cat > "$TMP_SUDOERS" << SUDOERS_CONTENT
# netmon — least-privilege sudo rules for pfctl (IP blocking) and tcpdump (DNS monitor)
${CURRENT_USER} ALL=(root) NOPASSWD: ${PFCTL_BIN} -t netmon_blocked -T add *
${CURRENT_USER} ALL=(root) NOPASSWD: ${PFCTL_BIN} -t netmon_blocked -T delete *
${CURRENT_USER} ALL=(root) NOPASSWD: ${PFCTL_BIN} -t netmon_blocked -T show
${CURRENT_USER} ALL=(root) NOPASSWD: ${PFCTL_BIN} -a netmon -s rules
${CURRENT_USER} ALL=(root) NOPASSWD: ${PFCTL_BIN} -s tables
${CURRENT_USER} ALL=(root) NOPASSWD: ${TCPDUMP_BIN} -l -n udp port 53
SUDOERS_CONTENT
if sudo visudo -c -f "$TMP_SUDOERS" 2>/dev/null; then
    sudo cp "$TMP_SUDOERS" "$SUDOERS_FILE"
    sudo chmod 440 "$SUDOERS_FILE"
    echo "  ✓ $SUDOERS_FILE"
else
    echo "  ✗ sudoers syntax check failed — skipping (IP blocking + DNS monitor require manual sudo)"
fi
rm -f "$TMP_SUDOERS"

echo ""
echo "==> Writing DNS monitor LaunchAgent..."
cat > "$AGENTS/com.user.netmon.dns.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.user.netmon.dns</string>
  <key>ProgramArguments</key>
  <array>
    <string>${PY}</string>
    <string>${NETMON}/dns_monitor.py</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>WorkingDirectory</key>
  <string>${NETMON}</string>
  <key>StandardOutPath</key>
  <string>${NETMON}/dns.log</string>
  <key>StandardErrorPath</key>
  <string>${NETMON}/dns.err</string>
</dict>
</plist>
EOF
echo "  ✓ $AGENTS/com.user.netmon.dns.plist"

echo ""
echo "==> Setting menu bar visibility..."
defaults write com.apple.controlcenter "NSStatusItem Visible netmon" -bool true

echo ""
echo "==> Building Swift menu bar app..."
bash "$NETMON/build.sh"

echo ""
echo "✓ netmon installed and running."
echo "  Menu bar: ⚡ (top right)"
echo "  Panel:    http://localhost:6543"
