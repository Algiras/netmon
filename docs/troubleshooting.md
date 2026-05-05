# Troubleshooting

## Quick diagnostics

```bash
~/.netmon/verify.sh
```

This runs 30+ automated checks across runtime, security, and services, and reports pass/fail for each. Run this first.

---

## Common issues

### ⚡ icon not showing in menu bar

The menu bar app may not be running.

```bash
# Check if it's running
pgrep -l NetmonMenuBar

# Restart it
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.user.netmon.menubar.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.user.netmon.menubar.plist
```

If it crashes on launch, check the error log:
```bash
tail -f ~/.netmon/menubar.err
```

Common causes:
- The app binary was replaced without re-signing. Fix: `codesign --force --sign - /Applications/NetmonMenuBar.app`
- Missing `panel_token` file. Fix: restart the panel service (token is created on first panel boot)

---

### Panel shows "unauthorized"

The panel token may have changed or the token header is missing.

```bash
# Test with the current token
TOKEN=$(cat ~/.netmon/panel_token)
curl -i -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" http://localhost:6543/api/config
# Expect: HTTP/1.0 200
```

If the curl returns 200 but the Swift app shows errors, the app may be using an old token cached from before a token rotation. Restart the menu bar app.

---

### Models not loading in Settings tab

The Ollama server may not be running or the panel can't reach it.

```bash
# Check Ollama
curl http://localhost:11434/api/tags | python3 -m json.tool | grep name

# Restart Ollama if needed
brew services restart ollama
```

The models dropdown only shows models that support the required capability (`tools` for LLM, `embedding` for vectors). If a model you expect isn't showing, verify it was pulled with the correct tag:

```bash
ollama list
```

---

### No events are being generated

If the Pending and History tabs are empty after 10+ minutes:

**1. Check monitor.sh is running:**
```bash
launchctl list | grep com.user.netmon
# Look for com.user.netmon with a PID (not just a 0 exit code)
```

**2. Check for anomalies:**
```bash
tail -20 ~/.netmon/anomalies.log
```

If the file is empty or old, monitor.sh may not be writing. Check:
```bash
tail -f ~/.netmon/monitor.err
```

**3. Check analyze.py is running:**
```bash
tail -20 ~/.netmon/analysis.log
```

If the timestamps are old, the analyze LaunchAgent may have crashed:
```bash
tail -f ~/.netmon/analyze.err
```

**4. Trigger a manual analysis:**
```bash
TOKEN=$(cat ~/.netmon/panel_token)
curl -X POST http://localhost:6543/recheck \
  -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN"
```

---

### Too many alerts / all connections are flagged

This usually happens right after install when the baseline is empty. Two options:

**Option A — Use Autonomous mode for the first pass:**
Enable autonomous mode and let the LLM baseline routine traffic for 15–30 minutes. Then switch back to Review mode.

**Option B — Pre-seed the baseline manually:**
```bash
# Add all current connections as baseline (useful on a known-clean machine)
lsof -i 4 -n -P | awk 'NR>1 {print $1"|"$9}' | sort -u >> ~/.netmon/baseline.txt
```

---

### Analysis is slow

**LLM model too large:** Try a smaller model like `granite4.1:3b` or `qwen3.5:2b`.

**Ollama not using GPU:** Check that Metal is being used:
```bash
ollama run granite4.1:3b "hello" 2>&1 | grep -i "metal\|gpu"
```

**Too many events in one cycle:** If hundreds of anomalies accumulate, the first analyze run after a quiet period may take several minutes. Subsequent runs process fewer events.

---

### DNS monitor not running

The DNS monitor requires `/etc/sudoers.d/netmon` and `tcpdump` at `/usr/sbin/tcpdump`.

```bash
# Check if it's running
launchctl list com.user.netmon.dns
tail -20 ~/.netmon/dns.err

# Verify sudoers
cat /etc/sudoers.d/netmon

# Verify tcpdump can run without password
sudo /usr/sbin/tcpdump -l -n udp port 53 &
sleep 2 && kill %1
```

If sudoers is missing, run `bash ~/.netmon/install.sh` or create it manually — see [DNS Exfiltration Detection](security/dns-exfil.md#sudoers-requirement).

Restart the DNS monitor:
```bash
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.user.netmon.dns.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.user.netmon.dns.plist
```

---

### pf enforcement not blocking IPs

```bash
# Check pf anchor status
sudo pfctl -a netmon -s rules

# If empty, regenerate
TOKEN=$(cat ~/.netmon/panel_token)
curl -X POST http://localhost:6543/config \
  -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"pf_enforcement": true}'
```

If `setup-pf.sh` hasn't been run:
```bash
bash ~/.netmon/setup-pf.sh
```

---

### Rebuilding the menu bar app

If you pull an update or modify Swift source:

```bash
bash ~/.netmon/build.sh
```

After a successful build, re-sign the app:
```bash
codesign --force --sign - /Applications/NetmonMenuBar.app
```

Then reload the LaunchAgent:
```bash
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.user.netmon.menubar.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.user.netmon.menubar.plist
```

---

## Log files

| File | Contains |
|------|---------|
| `~/.netmon/anomalies.log` | Raw lsof detections (monitor.sh output) |
| `~/.netmon/analysis.log` | LLM decisions, summaries, triage results |
| `~/.netmon/dns.log` | dns_monitor.py stdout |
| `~/.netmon/dns.err` | dns_monitor.py errors (tcpdump failures here) |
| `~/.netmon/panel.log` | HTTP access log for panel.py |
| `~/.netmon/panel.err` | panel.py errors |
| `~/.netmon/analyze.err` | analyze.py errors |
| `~/.netmon/monitor.err` | monitor.sh errors |
| `~/.netmon/menubar.err` | Swift app crash log |
| `~/.netmon/watchdog.log` | Watchdog alerts when services stop |

---

## Getting help

- [GitHub Issues](https://github.com/Algiras/netmon/issues) — bug reports and feature requests
- Run `~/.netmon/verify.sh` and include its output in any bug report
