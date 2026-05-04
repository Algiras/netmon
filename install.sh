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
echo "==> Building Swift menu bar app..."
bash "$NETMON/build.sh"

echo ""
echo "✓ netmon installed and running."
echo "  Menu bar: ⚡ (top right)"
echo "  Panel:    http://localhost:6543"
