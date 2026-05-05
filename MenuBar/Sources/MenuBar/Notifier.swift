// Notifier.swift — UNUserNotification sender called by analyze.py
// Usage: netmon-menubar notify <event_id> <title> <body> <severity>
// When action buttons are tapped, POSTs to the panel and refreshes the menu.

import AppKit
import Foundation
import UserNotifications

let CATEGORY_ID = "netmon.review"

// Called once at startup to register the category and delegate
func setupNotifications(delegate: UNUserNotificationCenterDelegate) {
    guard Bundle.main.bundleIdentifier != nil else { return }
    let center = UNUserNotificationCenter.current()
    center.delegate = delegate

    let confirmAction = UNNotificationAction(
        identifier: "CONFIRM", title: "✓ Confirm", options: []
    )
    let rejectAction = UNNotificationAction(
        identifier: "REJECT", title: "✗ Reject", options: [.destructive]
    )
    let category = UNNotificationCategory(
        identifier: CATEGORY_ID,
        actions: [confirmAction, rejectAction],
        intentIdentifiers: [], options: [.customDismissAction]
    )
    center.setNotificationCategories([category])

    center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
}

func sendNotification(eventID: String, title: String, body: String,
                      severity: String, recommendedAction: String = "investigate") {
    let center  = UNUserNotificationCenter.current()
    let content = UNMutableNotificationContent()

    let icons: [String: String] = ["info": "ℹ️", "warning": "⚠️", "critical": "🚨"]
    let icon = icons[severity] ?? "⚠️"

    // Action label shown as subtitle so the user knows urgency at a glance
    let actionLabels: [String: String] = [
        "confirm":      "Looks safe — confirm?",
        "reject":       "Suspicious — reject?",
        "block_ip":     "Block IP recommended",
        "kill_process": "Kill process recommended",
        "investigate":  "Needs investigation",
    ]
    let actionLabel = actionLabels[recommendedAction] ?? "Needs review"

    content.title              = "\(icon) \(title)"
    content.subtitle           = "AI: \(actionLabel)"
    content.body               = body
    content.categoryIdentifier = CATEGORY_ID

    switch severity {
    case "critical": content.sound = .defaultCritical
    case "info":     content.sound = .init(named: UNNotificationSoundName("Glass"))
    default:         content.sound = .init(named: UNNotificationSoundName("Basso"))
    }

    center.add(UNNotificationRequest(identifier: eventID, content: content, trigger: nil))
}
