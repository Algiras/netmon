# Notifications

netmon delivers macOS system notifications for events that need your attention. Notifications are sent when the LLM calls `send_notification` — in Review mode this is the primary way you interact with alerts.

---

## Notification anatomy

Each notification shows:

- **Title** — process name and remote IP:port
- **Body** — the LLM's one-line summary of why the connection is suspicious
- **Action buttons** — **Confirm** and **Reject** (appear when the notification is expanded or in Notification Center)

---

## Responding to notifications

You can respond directly from the notification without opening the panel:

| Action | Effect |
|--------|--------|
| Click **Confirm** | Marks the event as confirmed-safe, adds to baseline |
| Click **Reject** | Marks the event as suspicious, flags the IP |
| Click the notification body | Opens the netmon panel to the Pending tab |
| Dismiss (swipe away) | Event stays pending — review it in the panel later |

---

## Enabling notifications

macOS may ask for notification permission when the menu bar app first launches. If you missed the prompt:

1. Open **System Settings → Notifications**
2. Find **NetmonMenuBar** in the list
3. Set alert style to **Alerts** (not Banners) so the action buttons remain on screen

!!! tip "Alerts vs Banners"
    **Alerts** stay on screen until you dismiss them — ideal for security tools. Banners disappear after a few seconds, which may cause you to miss the action buttons.

---

## Notification volume

In **Autonomous mode** the LLM does not call `send_notification` for events it resolves automatically — only events that the LLM explicitly marks as requiring review will trigger a notification. This means notifications in Autonomous mode represent higher-confidence alerts.

In **Review mode** every event the LLM flags (rather than silently marking as normal) generates a notification.

To reduce noise during the initial learning period, use Autonomous mode for the first few hours and switch to Review mode once the baseline is stable. See [Review vs Autonomous](modes.md).
