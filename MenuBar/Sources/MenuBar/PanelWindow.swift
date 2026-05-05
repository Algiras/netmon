import AppKit
import SwiftUI

// ── Data models ───────────────────────────────────────────────────────────────

struct ModelEntry: Decodable, Hashable {
    let name: String
    let size: String
}

struct OllamaModels: Decodable {
    let llm:   [ModelEntry]
    let embed: [ModelEntry]
    let config: [String: String]?
}

// ── View-model ────────────────────────────────────────────────────────────────

@MainActor
class PanelModel: ObservableObject {
    @Published var pending:       [Event] = []
    @Published var recent:        [Event] = []
    @Published var autonomousMode = false
    @Published var llmModels:     [ModelEntry] = []
    @Published var embedModels:   [ModelEntry] = []
    @Published var selectedLLM    = ""
    @Published var selectedEmbed  = ""
    @Published var isResolving    = false
    @Published var resolveLog:    [String] = []

    func refresh() {
        fetchEvents { [weak self] r in
            guard let self, let r else { return }
            self.pending       = r.pending
            self.recent        = r.recent
            self.autonomousMode = r.config?.autonomous_mode ?? self.autonomousMode
            if let m = r.config?.llm_model,   !m.isEmpty { self.selectedLLM   = m }
            if let m = r.config?.embed_model, !m.isEmpty { self.selectedEmbed = m }
        }
        guard let url = URL(string: "http://localhost:6543/api/models") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data,
                  let m = try? JSONDecoder().decode(OllamaModels.self, from: data) else { return }
            DispatchQueue.main.async {
                self.llmModels   = m.llm
                self.embedModels = m.embed
                if self.selectedLLM.isEmpty,   let first = m.llm.first   { self.selectedLLM   = first.name }
                if self.selectedEmbed.isEmpty, let first = m.embed.first  { self.selectedEmbed = first.name }
            }
        }.resume()
    }

    func confirm(_ id: Int) {
        postAction(id: id, action: "confirmed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }
    func reject(_ id: Int) {
        postAction(id: id, action: "rejected")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }
    func toggleMode() {
        toggleAutonomousMode()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }

    func setLLM(_ name: String) {
        postConfig(["llm_model": name])
        selectedLLM = name
    }
    func setEmbed(_ name: String) {
        postConfig(["embed_model": name, "_clear_embeddings": "true"])
        selectedEmbed = name
    }

    // Trigger analyze.py to process all pending events immediately
    func resolveAll() {
        guard !isResolving else { return }
        isResolving = true
        resolveLog  = ["Starting analysis…"]
        DispatchQueue.global().async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3")
            task.arguments     = ["\(NSHomeDirectory())/.netmon/analyze.py"]
            task.currentDirectoryURL = URL(fileURLWithPath: "\(NSHomeDirectory())/.netmon")
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError  = pipe
            try? task.run()
            // Stream output
            pipe.fileHandleForReading.readabilityHandler = { fh in
                let s = String(data: fh.availableData, encoding: .utf8) ?? ""
                if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DispatchQueue.main.async { self.resolveLog.append(s.trimmingCharacters(in: .newlines)) }
                }
            }
            task.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.isResolving = false
                self.resolveLog.append("✓ Done.")
                self.refresh()
            }
        }
    }

    private func postConfig(_ body: [String: String]) {
        guard let url  = URL(string: "http://localhost:6543/config"),
              let data = try? JSONEncoder().encode(body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody   = data
        URLSession.shared.dataTask(with: req).resume()
    }
}

// ── Event row ─────────────────────────────────────────────────────────────────

struct EventRow: View {
    let event: Event
    var onConfirm: (() -> Void)? = nil
    var onReject:  (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(icon(event.severity))
                Text(event.process).fontWeight(.semibold)
                Text("→").foregroundStyle(.secondary)
                Text(event.remote).foregroundStyle(.secondary)
                Spacer()
                Text(String(event.ts.prefix(16))).font(.caption).foregroundStyle(.tertiary)
            }
            if !event.summary.isEmpty {
                Text(event.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if let confirm = onConfirm, let reject = onReject {
                HStack(spacing: 8) {
                    Button("✓ Confirm", action: confirm)
                        .buttonStyle(.borderedProminent).tint(.green)
                    Button("✗ Reject", action: reject)
                        .buttonStyle(.borderedProminent).tint(.red)
                }
            } else {
                Text(event.status.uppercased())
                    .font(.caption2).bold()
                    .foregroundStyle(event.status == "confirmed" ? Color.green : .red)
            }
        }
        .padding(.vertical, 4)
    }

    private func icon(_ s: String) -> String {
        switch s { case "critical": return "🚨"; case "warning": return "⚠️"; default: return "ℹ️" }
    }
}

// ── Main panel view ───────────────────────────────────────────────────────────

struct PanelView: View {
    @StateObject private var model = PanelModel()
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabPicker
            Divider()
            content
        }
        .frame(minWidth: 620, minHeight: 460)
        .onAppear { model.refresh() }
    }

    // MARK: Header
    private var header: some View {
        HStack(spacing: 12) {
            Text("⚡ netmon").font(.headline)
            if model.pending.count > 0 {
                Text("\(model.pending.count) pending")
                    .foregroundStyle(.orange).font(.subheadline)
            }
            Spacer()
            Button(action: { model.toggleMode() }) {
                Label(
                    model.autonomousMode ? "🤖 Autonomous" : "👁 Review",
                    systemImage: model.autonomousMode ? "brain" : "eye"
                )
            }
            Button(action: { model.refresh() }) {
                Image(systemName: "arrow.clockwise")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: Tabs
    private var tabPicker: some View {
        Picker("", selection: $tab) {
            Text("Pending (\(model.pending.count))").tag(0)
            Text("History (\(model.recent.count))").tag(1)
            Text("Settings").tag(2)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: Content
    @ViewBuilder
    private var content: some View {
        switch tab {
        case 0:  pendingTab
        case 1:  historyTab
        default: settingsTab
        }
    }

    private var pendingTab: some View {
        Group {
            if model.pending.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "checkmark.shield").font(.largeTitle).foregroundStyle(.green)
                    Text("No pending alerts").foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                List(model.pending, id: \.id) { e in
                    EventRow(event: e,
                             onConfirm: { model.confirm(e.id) },
                             onReject:  { model.reject(e.id) })
                    Divider()
                }
            }
        }
    }

    private var historyTab: some View {
        List(model.recent, id: \.id) { e in
            EventRow(event: e)
            Divider()
        }
    }

    private var settingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Autonomous mode
                GroupBox("Mode") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Autonomous mode", isOn: Binding(
                            get: { model.autonomousMode },
                            set: { _ in model.toggleMode() }
                        ))
                        Text(model.autonomousMode
                             ? "LLM auto-resolves events without human review."
                             : "LLM flags events for your approval.")
                            .font(.caption).foregroundStyle(.secondary)

                        Divider()

                        Button(action: { model.resolveAll() }) {
                            HStack {
                                if model.isResolving {
                                    ProgressView().scaleEffect(0.7)
                                }
                                Text(model.isResolving ? "Analysing…" : "▶  Run analysis now (all pending)")
                            }
                        }
                        .disabled(model.isResolving)

                        if !model.resolveLog.isEmpty {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(model.resolveLog, id: \.self) { line in
                                        Text(line).font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                            }
                            .frame(height: 100)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(6)
                        }
                    }
                    .padding(8)
                }

                // LLM model
                GroupBox("LLM Model  (tool-capable)") {
                    Picker("", selection: Binding(
                        get: { model.selectedLLM },
                        set: { model.setLLM($0) }
                    )) {
                        ForEach(model.llmModels, id: \.name) { m in
                            Text("\(m.name)  (\(m.size))").tag(m.name)
                        }
                        if model.llmModels.isEmpty {
                            Text(model.selectedLLM.isEmpty ? "Loading…" : model.selectedLLM)
                                .tag(model.selectedLLM)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(4)
                }

                // Embedding model
                GroupBox("Embedding Model  (RAG memory)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: Binding(
                            get: { model.selectedEmbed },
                            set: { model.setEmbed($0) }
                        )) {
                            ForEach(model.embedModels, id: \.name) { m in
                                Text("\(m.name)  (\(m.size))").tag(m.name)
                            }
                            if model.embedModels.isEmpty {
                                Text(model.selectedEmbed.isEmpty ? "Loading…" : model.selectedEmbed)
                                    .tag(model.selectedEmbed)
                            }
                        }
                        .pickerStyle(.menu)
                        Text("Changing the embedding model clears all stored RAG embeddings.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(4)
                }
            }
            .padding(16)
        }
    }
}

// ── Window controller ─────────────────────────────────────────────────────────

class PanelWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PanelWindowController()

    private init() {
        let hosting = NSHostingView(rootView: PanelView())
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable],
            backing:     .buffered,
            defer:       false
        )
        win.title              = "netmon"
        win.contentView        = hosting
        win.setFrameAutosaveName("NetmonPanel")
        win.center()
        super.init(window: win)
        win.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func showPanel() {
        if window?.isVisible == false { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
