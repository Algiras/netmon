#!/usr/bin/env bash
# ~/.netmon/build.sh — build the Swift menu bar binary and reload LaunchAgents

set -e
NETMON="$HOME/.netmon"
APP="$NETMON/NetmonMenuBar.app"
BINARY="$APP/Contents/MacOS/NetmonMenuBar"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

echo "==> Building netmon-menubar (Swift menu bar + notifier)..."
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -sdk "$SDK" \
  -framework Foundation -framework AppKit -framework UserNotifications \
  "$NETMON/MenuBar/Sources/MenuBar/Notifier.swift" \
  "$NETMON/MenuBar/Sources/MenuBar/NetmonMenuBar.swift" \
  "$NETMON/MenuBar/Sources/MenuBar/main.swift" \
  -o "$BINARY"

if [ -f "$BINARY" ]; then
    cp "$NETMON/MenuBar/Info.plist" "$APP/Contents/Info.plist"
    codesign --force --deep --sign - "$APP" 2>/dev/null
    echo "✓ Binary: $BINARY"
    echo ""
    echo "==> Loading LaunchAgents..."
    for plist in \
        "$HOME/Library/LaunchAgents/com.user.netmon.plist" \
        "$HOME/Library/LaunchAgents/com.user.netmon.analyze.plist" \
        "$HOME/Library/LaunchAgents/com.user.netmon.panel.plist" \
        "$HOME/Library/LaunchAgents/com.user.netmon.menubar.plist"
    do
        launchctl unload "$plist" 2>/dev/null || true
        launchctl load   "$plist"
        echo "  ✓ $(basename "$plist")"
    done
    echo ""
    echo "✓ netmon is running."
    echo "  Menu bar: ⚡ (top right)"
    echo "  Panel:    http://localhost:6543"
    echo "  Log:      $NETMON/anomalies.log"
else
    echo "✗ Build failed — check output above."
    exit 1
fi
