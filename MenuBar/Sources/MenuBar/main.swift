// ~/.netmon/MenuBar/Sources/MenuBar/main.swift
// netmon menu bar agent — shows pending alert count, recent events, quick actions.
// Compile via: swift build -c release  (from ~/.netmon/MenuBar/)
// Run as a background agent via LaunchAgent (LSUIElement=1 equivalent).

import AppKit
import Foundation
import UserNotifications

// ── Panel API client ──────────────────────────────────────────────────────────

struct Event: Decodable {
    let id: Int
    let ts: String
    let process: String
    let remote: String
    let severity: String
    let summary: String
    let status: String
}

struct NetmonConfig: Decodable {
    let autonomous_mode: Bool
}

struct ApiResponse: Decodable {
    let pending: [Event]
    let recent: [Event]
    let config: NetmonConfig?
}

func fetchEvents(completion: @escaping (ApiResponse?) -> Void) {
    guard let url = URL(string: "http://localhost:6543/api/events") else {
        completion(nil); return
    }
    URLSession.shared.dataTask(with: url) { data, _, _ in
        guard let data, let r = try? JSONDecoder().decode(ApiResponse.self, from: data) else {
            completion(nil); return
        }
        completion(r)
    }.resume()
}

func postAction(id: Int, action: String) {
    guard let url = URL(string: "http://localhost:6543/action") else { return }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = "{\"id\":\(id),\"action\":\"\(action)\"}".data(using: .utf8)
    URLSession.shared.dataTask(with: req).resume()
}

// ── Menu bar controller ───────────────────────────────────────────────────────

func toggleAutonomousMode() {
    guard let url = URL(string: "http://localhost:6543/config") else { return }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = "{\"toggle\":\"autonomous_mode\"}".data(using: .utf8)
    URLSession.shared.dataTask(with: req).resume()
}

class NetmonMenuBar: NSObject {
    private let statusItem: NSStatusItem = {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "netmon"
        item.isVisible = true
        return item
    }()
    private var timer: Timer?
    private var lastPendingCount = 0
    private var autonomousMode = false
    var notificationsEnabled = true

    override init() {
        super.init()
        setButton("⚡")
        statusItem.menu = NSMenu()
        startPolling()
    }

    private func setButton(_ text: String, color: NSColor? = nil) {
        if let color {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                .baselineOffset: 0.5,
            ]
            statusItem.button?.attributedTitle = NSAttributedString(string: text, attributes: attrs)
        } else {
            // No explicit color — let the system use the default menu bar tint (works in both light and dark mode)
            statusItem.button?.attributedTitle = NSAttributedString(string: "")
            statusItem.button?.title = text
        }
    }

    private func startPolling() {
        checkNotificationPermission()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkNotificationPermission()
            self?.refresh()
        }
    }

    func refresh() {
        fetchEvents { [weak self] response in
            DispatchQueue.main.async {
                self?.updateMenu(response: response)
            }
        }
    }

    func checkNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.notificationsEnabled = settings.authorizationStatus == .authorized
            }
        }
    }

    private func updateMenu(response: ApiResponse?) {
        let pending = response?.pending ?? []
        let count   = pending.count
        autonomousMode = response?.config?.autonomous_mode ?? autonomousMode

        // Update button
        if count > 0 {
            let color: NSColor = count > 2 ? .systemRed : .systemOrange
            setButton("⚡ \(count)", color: color)
        } else {
            let label = autonomousMode ? "⚡ 🤖" : "⚡"
            setButton(label, color: autonomousMode ? .systemGreen : nil)
        }

        // Rebuild menu
        let menu = NSMenu()

        // Header
        let header = NSMenuItem(title: "netmon", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if !notificationsEnabled {
            let warn = NSMenuItem(
                title: "⚠️  Notifications disabled — click to fix",
                action: #selector(openNotificationSettings),
                keyEquivalent: ""
            )
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        if pending.isEmpty {
            let ok = NSMenuItem(title: "✓  No pending alerts", action: nil, keyEquivalent: "")
            ok.isEnabled = false
            menu.addItem(ok)
        } else {
            let label = NSMenuItem(title: "\(count) pending alert\(count == 1 ? "" : "s")", action: nil, keyEquivalent: "")
            label.isEnabled = false
            menu.addItem(label)
            menu.addItem(.separator())

            for event in pending.prefix(5) {
                let icon  = severityIcon(event.severity)
                let title = "\(icon)  \(event.process) → \(event.remote)"
                let item  = NSMenuItem(title: title, action: nil, keyEquivalent: "")

                // Submenu with confirm/reject
                let sub = NSMenu()
                let summary = NSMenuItem(title: event.summary.prefix(60).description, action: nil, keyEquivalent: "")
                summary.isEnabled = false
                sub.addItem(summary)
                sub.addItem(.separator())

                let confirm = NSMenuItem(title: "✓ Confirm (add to baseline)", action: #selector(confirmEvent(_:)), keyEquivalent: "")
                confirm.target  = self
                confirm.tag     = event.id
                sub.addItem(confirm)

                let reject = NSMenuItem(title: "✗ Reject (flag as suspicious)", action: #selector(rejectEvent(_:)), keyEquivalent: "")
                reject.target = self
                reject.tag    = event.id
                sub.addItem(reject)

                item.submenu = sub
                menu.addItem(item)
            }

            if count > 5 {
                let more = NSMenuItem(title: "  … +\(count - 5) more in panel", action: nil, keyEquivalent: "")
                more.isEnabled = false
                menu.addItem(more)
            }
        }

        menu.addItem(.separator())

        let modeTitle = autonomousMode ? "🤖  Autonomous: ON" : "👁  Review Mode: ON"
        let modeItem  = NSMenuItem(title: modeTitle, action: #selector(toggleMode), keyEquivalent: "m")
        modeItem.target = self
        menu.addItem(modeItem)

        menu.addItem(.separator())

        let openPanel = NSMenuItem(title: "Open Review Panel", action: #selector(openPanel), keyEquivalent: "p")
        openPanel.target = self
        menu.addItem(openPanel)

        let runNow = NSMenuItem(title: "Run Analysis Now", action: #selector(runAnalysis), keyEquivalent: "r")
        runNow.target = self
        menu.addItem(runNow)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit netmon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        lastPendingCount = count
    }

    private func severityIcon(_ s: String) -> String {
        switch s {
        case "critical": return "🚨"
        case "warning":  return "⚠️"
        default:         return "ℹ️"
        }
    }

    @objc private func confirmEvent(_ sender: NSMenuItem) {
        postAction(id: sender.tag, action: "confirmed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    @objc private func rejectEvent(_ sender: NSMenuItem) {
        postAction(id: sender.tag, action: "rejected")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    @objc private func toggleMode() {
        toggleAutonomousMode()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }

    @objc private func openPanel() {
        NSWorkspace.shared.open(URL(string: "http://localhost:6543")!)
    }

    @objc private func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
    }

    @objc private func runAnalysis() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments     = ["\(NSHomeDirectory())/.netmon/analyze.py"]
        task.currentDirectoryURL = URL(fileURLWithPath: "\(NSHomeDirectory())/.netmon")
        try? task.run()
    }
}

// ── Notification delegate (lives on the menu bar app) ────────────────────────

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var menuBarController: NetmonMenuBar?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = NetmonMenuBar()   // icon first — always visible
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            setupNotifications(delegate: self)
        }
    }

    // Receive action taps (Confirm / Reject buttons)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler handler: @escaping () -> Void
    ) {
        defer { handler() }
        let notifID = response.notification.request.identifier
        switch response.actionIdentifier {
        case "CONFIRM": postAction(id: Int(notifID) ?? 0, action: "confirmed")
        case "REJECT":  postAction(id: Int(notifID) ?? 0, action: "rejected")
        case UNNotificationDefaultActionIdentifier:
            NSWorkspace.shared.open(URL(string: "http://localhost:6543")!)
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.menuBarController?.refreshFromDelegate()
        }
    }

    // Show banners even when app is "foreground"
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        handler([.banner, .sound, .list])
    }
}

// ── App entry ─────────────────────────────────────────────────────────────────

let app      = NSApplication.shared
let delegate = AppDelegate()

// If called as: netmon-menubar notify <id> <title> <body> <severity>
// fire the notification immediately (used by analyze.py) and keep running.
let args = CommandLine.arguments
if args.count >= 6, args[1] == "notify" {
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    // Notification will be sent after app finishes launching via the delegate
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        sendNotification(eventID: args[2], title: args[3], body: args[4], severity: args[5])
    }
} else {
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
}

app.run()
