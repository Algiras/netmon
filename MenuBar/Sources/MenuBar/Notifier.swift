// Notifier.swift — UNUserNotification sender called by analyze.py
// Usage: netmon-menubar notify <event_id> <title> <body> <severity>
// When action buttons are tapped, POSTs to the panel and refreshes the menu.

import AppKit
import Foundation
import UserNotifications

let CATEGORY_ID = "netmon.review"

// Called once at startup to register the category and delegate
func setupNotifications(delegate: UNUserNotificationCenterDelegate) {
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

func sendNotification(eventID: String, title: String, body: String, severity: String) {
    let center  = UNUserNotificationCenter.current()
    let content = UNMutableNotificationContent()

    let icons: [String: String] = ["info": "ℹ️", "warning": "⚠️", "critical": "🚨"]
    content.title              = "\(icons[severity] ?? "⚠️") \(title)"
    content.body               = "\(body)  ·  localhost:6543"
    content.categoryIdentifier = CATEGORY_ID

    switch severity {
    case "critical": content.sound = .defaultCritical
    case "info":     content.sound = .init(named: UNNotificationSoundName("Glass"))
    default:         content.sound = .init(named: UNNotificationSoundName("Basso"))
    }

    center.add(UNNotificationRequest(identifier: eventID, content: content, trigger: nil))
}
