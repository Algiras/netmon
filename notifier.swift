// ~/.netmon/notifier.swift
// Compile: swiftc -framework Foundation -framework UserNotifications notifier.swift -o netmon-notify
//
// Usage: netmon-notify <event_id> <title> <body> <severity>
//   event_id  — integer DB row id (passed to panel /action endpoint)
//   title     — notification title
//   body      — notification body
//   severity  — info | warning | critical
//
// Action buttons ("✓ Confirm" / "✗ Reject") POST to http://localhost:6543/action.
// Tapping the notification body opens the panel in the browser.
// Process exits after the user responds or after TIMEOUT seconds.

import Foundation
import UserNotifications

// ── Config ────────────────────────────────────────────────────────────────────

let PANEL_URL    = "http://localhost:6543"
let CATEGORY_ID  = "netmon.review"
let TIMEOUT: TimeInterval = 180

// ── Args ──────────────────────────────────────────────────────────────────────

let args = CommandLine.arguments
guard args.count >= 5 else {
    fputs("Usage: netmon-notify <event_id> <title> <body> <severity>\n", stderr)
    exit(1)
}

let eventID  = args[1]          // DB row id as string
let title    = args[2]
let body     = args[3]
let severity = args[4]

// ── Notification delegate ─────────────────────────────────────────────────────

class NetmonDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let done = DispatchSemaphore(value: 0)

    // Called when the notification is delivered while the process is foregrounded.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        handler([.banner, .sound, .list])
    }

    // Called when the user interacts with the notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler handler: @escaping () -> Void
    ) {
        defer {
            handler()
            done.signal()
        }

        let action = response.actionIdentifier
        switch action {
        case "CONFIRM":
            postAction("confirmed")
        case "REJECT":
            postAction("rejected")
        case UNNotificationDefaultActionIdentifier:
            // User tapped notification body → open panel
            openPanel()
        default:
            break
        }
    }

    func wait() {
        _ = done.wait(timeout: .now() + TIMEOUT)
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private func postAction(_ status: String) {
        guard
            let id   = Int(eventID),
            let url  = URL(string: "\(PANEL_URL)/action")
        else { return }

        let payload = "{\"id\":\(id),\"action\":\"\(status)\"}"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload.data(using: .utf8)

        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in sema.signal() }.resume()
        _ = sema.wait(timeout: .now() + 5)
    }

    private func openPanel() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [PANEL_URL]
        try? proc.run()
    }
}

// ── Setup ─────────────────────────────────────────────────────────────────────

let center   = UNUserNotificationCenter.current()
let delegate = NetmonDelegate()
center.delegate = delegate

// Register action category
let confirmAction = UNNotificationAction(
    identifier: "CONFIRM",
    title: "✓ Confirm",
    options: []
)
let rejectAction = UNNotificationAction(
    identifier: "REJECT",
    title: "✗ Reject",
    options: [.destructive]
)
let category = UNNotificationCategory(
    identifier: CATEGORY_ID,
    actions: [confirmAction, rejectAction],
    intentIdentifiers: [],
    options: [.customDismissAction]
)
center.setNotificationCategories([category])

// Request permission (first run only; persists in System Settings)
let permSema = DispatchSemaphore(value: 0)
center.requestAuthorization(options: [.alert, .sound, .criticalAlert]) { granted, error in
    if let error { fputs("Permission error: \(error.localizedDescription)\n", stderr) }
    if !granted  { fputs("Notifications not permitted — grant access in System Settings.\n", stderr) }
    permSema.signal()
}
permSema.wait()

// ── Build notification ────────────────────────────────────────────────────────

let content = UNMutableNotificationContent()

let icons: [String: String]  = ["info": "ℹ️", "warning": "⚠️", "critical": "🚨"]
let icon = icons[severity] ?? "⚠️"
content.title = "\(icon) \(title)"
content.body  = "\(body)\n→ \(PANEL_URL)"
content.categoryIdentifier = CATEGORY_ID

switch severity {
case "critical":
    content.sound = .defaultCritical
case "info":
    content.sound = .init(named: UNNotificationSoundName("Glass"))
default:
    content.sound = .init(named: UNNotificationSoundName("Basso"))
}

let request = UNNotificationRequest(
    identifier: eventID,
    content: content,
    trigger: nil   // deliver immediately
)

let sendSema = DispatchSemaphore(value: 0)
center.add(request) { error in
    if let error { fputs("Failed to send: \(error.localizedDescription)\n", stderr) }
    sendSema.signal()
}
sendSema.wait()

// ── Wait for user action or timeout ──────────────────────────────────────────
// Run the main RunLoop so the delegate can receive callbacks.

let timer = Timer.scheduledTimer(withTimeInterval: TIMEOUT, repeats: false) { _ in
    exit(0)
}
RunLoop.main.add(timer, forMode: .common)

// Spin the run loop — delegate callbacks land here.
// The delegate signals `done` when the user taps, which causes wait() to return.
// We then stop the run loop and exit cleanly.
DispatchQueue.global().async {
    delegate.wait()
    DispatchQueue.main.async { exit(0) }
}

RunLoop.main.run()
