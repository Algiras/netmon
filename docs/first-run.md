# First Run

## What happens in the first few minutes

After `install.sh` completes:

1. **Menu bar icon appears** — look for `⚡` in the top-right of your screen

    ![netmon menu bar icon](assets/screenshots/menubar-icon.png)

    The lightning bolt is orange/yellow when there are pending events, and dim when everything is quiet.

2. **monitor.sh fires immediately** — `lsof -i 4` captures a snapshot of all current TCP/UDP connections. Because `baseline.txt` is empty, every active connection is written as an `[ANOMALY]` line to `anomalies.log`.

3. **analyze.py runs within 5 minutes** — it reads the anomaly log, embeds each event, and sends them to the LLM for triage. This first run may take a few minutes as it processes the initial burst of connections.

4. **The panel populates** — click `⚡` in the menu bar, then **Open Panel** to see events in the review queue.

---

## The first wave of alerts

Your first run will likely produce dozens of events — every browser tab, background app, and system service that was connected when netmon started. This is normal.

**Recommended workflow for the first day:**

- Switch to **Autonomous mode** (click the `Auto` button in the panel header) so the LLM can quickly classify and baseline routine traffic without interrupting you.
- After a few cycles (15–30 minutes), review the **Baseline** tab — it should now contain all the routine connections the LLM marked as normal.
- Switch back to **Review mode** once the noise settles. Going forward, only genuinely new or suspicious connections will trigger alerts.

---

## Panel at a glance

![netmon pending tab](assets/screenshots/panel-pending.png)

| Element | What it does |
|---------|-------------|
| `⚡ netmon` (top left) | App name and brand |
| **N pending** badge | Number of events waiting for your review |
| **Last run** timestamp | When analyze.py last ran |
| **Auto / Review** button | Toggle autonomous vs. review mode |
| **Refresh** (↺) icon | Manually refresh the event list |
| **Pending / History / Baseline / Settings** tabs | Navigate between views |

---

## Accessing the panel

The panel is embedded in the native Swift menu bar app — click `⚡` in the menu bar to open it.

You can also curl the API directly. Your auth token is at `~/.netmon/panel_token`:

```bash
TOKEN=$(cat ~/.netmon/panel_token)
curl -H "Host: localhost:6543" -H "X-Netmon-Token: $TOKEN" \
     http://localhost:6543/api/events
```

---

## Next steps

- [Panel UI](user-guide/panel.md) — full walkthrough of every panel view
- [Review vs Autonomous modes](user-guide/modes.md) — when to use each
- [Configuration](configuration/config.md) — tune thresholds and models
