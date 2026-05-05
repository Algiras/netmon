import AppKit
import SwiftUI

// ── Data models ───────────────────────────────────────────────────────────────

struct IPRepInfo {
    let country: String
    let isp: String
    let org: String
    let asn: String
    let isHosting: Bool

    var badge: String {
        var parts: [String] = []
        if !country.isEmpty { parts.append(country) }
        let label = org.isEmpty ? isp : org
        if !label.isEmpty { parts.append(label) }
        if isHosting { parts.append("Datacenter") }
        return parts.joined(separator: " · ")
    }
}

struct ModelEntry: Decodable, Hashable {
    let name: String
    let size: String
}

struct OllamaModels: Decodable {
    let available: Bool
    let llm:       [ModelEntry]
    let embed:     [ModelEntry]
    let config:    NetmonConfig?
}

// ── View-model ────────────────────────────────────────────────────────────────

@MainActor
class PanelModel: ObservableObject {
    @Published var pending:        [Event] = []
    @Published var recent:         [Event] = []
    @Published var autonomousMode  = false
    @Published var llmModels:      [ModelEntry] = []
    @Published var embedModels:    [ModelEntry] = []
    @Published var selectedLLM     = ""
    @Published var selectedEmbed   = ""
    @Published var ollamaAvailable = true
    @Published var isResolving     = false
    @Published var resolveLog:     [String] = []
    @Published var isPulling       = false
    @Published var pullLog:        [String] = []
    @Published var lastAnalyzed:   String = ""
    @Published var ipRepCache:     [String: IPRepInfo] = [:]
    @Published var blockedIPs:     [String] = []
    @Published var isRechecking    = false

    func refresh() {
        fetchEvents { [weak self] r in
            guard let self, let r else { return }
            self.pending        = r.pending
            self.recent         = r.recent
            self.autonomousMode = r.config?.autonomous_mode ?? self.autonomousMode
            if let m = r.config?.llm_model,   !m.isEmpty { self.selectedLLM   = m }
            if let m = r.config?.embed_model, !m.isEmpty { self.selectedEmbed = m }
            // Fetch IP reputation for all unique pending IPs
            let ips = Set(r.pending.map { $0.remote.split(separator: ":").first.map(String.init) ?? $0.remote })
            for ip in ips where self.ipRepCache[ip] == nil {
                self.fetchIPReputation(ip)
            }
        }
        guard let url = URL(string: "http://localhost:6543/api/models") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data,
                  let m = try? JSONDecoder().decode(OllamaModels.self, from: data) else { return }
            DispatchQueue.main.async {
                self.ollamaAvailable = m.available
                self.llmModels       = m.llm
                self.embedModels     = m.embed
                if self.selectedLLM.isEmpty,   let first = m.llm.first   { self.selectedLLM   = first.name }
                if self.selectedEmbed.isEmpty, let first = m.embed.first  { self.selectedEmbed = first.name }
            }
        }.resume()
        refreshLastAnalyzed()
        fetchBlockedIPs()
    }

    func fetchBlockedIPs() {
        guard let url = URL(string: "http://localhost:6543/api/blocked-ips") else { return }
        var req = URLRequest(url: url)
        req.setValue("localhost:6543", forHTTPHeaderField: "Host")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ips = obj["ips"] as? [String] else { return }
            DispatchQueue.main.async { self.blockedIPs = ips }
        }.resume()
    }

    func unblockIP(_ ip: String) {
        guard let url  = URL(string: "http://localhost:6543/unblock-ip"),
              let data = try? JSONSerialization.data(withJSONObject: ["ip": ip]) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("localhost:6543", forHTTPHeaderField: "Host")
        req.httpBody = data
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.fetchBlockedIPs() }
        }.resume()
    }

    private func fetchIPReputation(_ ip: String) {
        guard let url = URL(string: "http://ip-api.com/json/\(ip)?fields=status,country,isp,org,as,hosting") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["status"] as? String) == "success" else { return }
            let info = IPRepInfo(
                country:   obj["country"]  as? String ?? "",
                isp:       obj["isp"]      as? String ?? "",
                org:       obj["org"]      as? String ?? "",
                asn:       obj["as"]       as? String ?? "",
                isHosting: obj["hosting"]  as? Bool   ?? false
            )
            DispatchQueue.main.async { self.ipRepCache[ip] = info }
        }.resume()
    }

    private func refreshLastAnalyzed() {
        DispatchQueue.global().async {
            let logPath = NSHomeDirectory() + "/.netmon/analysis.log"
            guard let lines = try? String(contentsOfFile: logPath, encoding: .utf8).components(separatedBy: "\n"),
                  let last  = lines.reversed().first(where: { $0.contains("[ANALYZE") || $0.contains("[AUTO") || $0.contains("[SWEEP") }) else { return }
            let ts = String(last.dropFirst().prefix(19))  // "[YYYY-MM-DD HH:MM:SS]" → drop "[", take 19
            DispatchQueue.main.async { self.lastAnalyzed = ts }
        }
    }

    func confirm(_ id: Int) {
        postAction(id: id, action: "confirmed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }
    func reject(_ id: Int) {
        postAction(id: id, action: "rejected")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }
    func revert(_ id: Int) {
        postAction(id: id, action: "revert")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }
    func toggleMode() {
        // Turning autonomous ON requires Ollama — panel.py enforces this server-side too
        if !autonomousMode && !ollamaAvailable { return }
        toggleAutonomousMode()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }

    func pullModels() {
        guard !isPulling else { return }
        isPulling = true
        pullLog   = ["Pulling models via Ollama…"]
        let cfg   = (try? JSONDecoder().decode(NetmonConfig.self,
                      from: (try? Data(contentsOf: URL(fileURLWithPath:
                        NSHomeDirectory() + "/.netmon/config.json"))) ?? Data()))
        let llm   = cfg?.llm_model   ?? "granite4.1:3b"
        let emb   = cfg?.embed_model ?? "nomic-embed-text-v2-moe"
        DispatchQueue.global().async {
            for model in [llm, emb] {
                DispatchQueue.main.async { self.pullLog.append("→ ollama pull \(model)") }
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ollama")
                task.arguments     = ["pull", model]
                let pipe = Pipe()
                task.standardOutput = pipe; task.standardError = pipe
                try? task.run()
                pipe.fileHandleForReading.readabilityHandler = { fh in
                    if let s = String(data: fh.availableData, encoding: .utf8),
                       !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DispatchQueue.main.async { self.pullLog.append(s.trimmingCharacters(in: .newlines)) }
                    }
                }
                task.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                let ok = task.terminationStatus == 0
                DispatchQueue.main.async {
                    self.pullLog.append(ok ? "✓ \(model) ready" : "✗ failed to pull \(model)")
                }
            }
            DispatchQueue.main.async {
                self.isPulling = false
                self.pullLog.append("✓ Done. Refreshing…")
                self.refresh()
            }
        }
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
            let py = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/python3")
                ? "/opt/homebrew/bin/python3" : "/usr/bin/python3"
            task.executableURL = URL(fileURLWithPath: py)
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

    func recheck() {
        guard autonomousMode, !isRechecking else { return }
        isRechecking = true
        guard let url = URL(string: "http://localhost:6543/recheck") else {
            isRechecking = false; return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody   = "{}".data(using: .utf8)
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self?.isRechecking = false
                self?.refresh()
            }
        }.resume()
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
    var ipRep:    IPRepInfo? = nil
    var onConfirm: (() -> Void)? = nil
    var onReject:  (() -> Void)? = nil
    var onRevert:  (() -> Void)? = nil

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
            // IP reputation badge
            if let rep = ipRep, !rep.badge.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: rep.isHosting ? "server.rack" : "globe")
                        .font(.caption2)
                    Text(rep.badge)
                        .font(.caption2)
                }
                .foregroundStyle(rep.isHosting ? Color.orange : Color.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(rep.isHosting ? Color.orange.opacity(0.1) : Color.secondary.opacity(0.08))
                .cornerRadius(4)
            }
            if !event.summary.isEmpty {
                Text(event.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if let confirm = onConfirm, let reject = onReject {
                HStack(spacing: 8) {
                    Button("✓ Confirm  (allow)", action: confirm)
                        .buttonStyle(.borderedProminent).tint(.green)
                    Button("✗ Reject  (flag)", action: reject)
                        .buttonStyle(.borderedProminent).tint(.red)
                }
            } else {
                HStack(spacing: 8) {
                    Text(event.status.uppercased())
                        .font(.caption2).bold()
                        .foregroundStyle(statusColor(event.status))
                    if let revert = onRevert {
                        Button(action: revert) {
                            Label("Revert", systemImage: "arrow.uturn.backward")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(severityTint(event.severity))
        .cornerRadius(6)
    }

    private func icon(_ s: String) -> String {
        switch s { case "critical": return "🚨"; case "warning": return "⚠️"; default: return "ℹ️" }
    }

    private func statusColor(_ s: String) -> Color {
        switch s {
        case "confirmed": return .green
        case "rejected":  return .red
        default:          return .secondary
        }
    }

    private func severityTint(_ s: String) -> Color {
        switch s {
        case "critical": return Color.red.opacity(0.07)
        case "warning":  return Color.orange.opacity(0.05)
        default:         return Color.clear
        }
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
        HStack(spacing: 10) {
            Text("⚡ netmon").font(.headline)
            if model.pending.count > 0 {
                Text("\(model.pending.count) pending")
                    .foregroundStyle(.orange).font(.subheadline)
            }
            Spacer()
            if !model.lastAnalyzed.isEmpty {
                Text("Last run \(model.lastAnalyzed)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            // Compact mode chip — tap to toggle
            Button(action: { model.toggleMode() }) {
                HStack(spacing: 4) {
                    Image(systemName: model.autonomousMode ? "brain" : "eye")
                        .font(.caption)
                    Text(model.autonomousMode ? "Auto" : "Review")
                        .font(.caption).fontWeight(.medium)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(model.autonomousMode
                    ? Color.purple.opacity(0.15)
                    : Color.blue.opacity(0.12))
                .foregroundStyle(model.autonomousMode ? Color.purple : Color.blue)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(!model.ollamaAvailable)
            Button(action: { model.refresh() }) {
                Image(systemName: "arrow.clockwise").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
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
                VStack(spacing: 0) {
                    // Recheck banner — only shown in autonomous mode
                    if model.autonomousMode {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .foregroundStyle(.orange)
                            Text("\(model.pending.count) event(s) pending in autonomous mode")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(action: { model.recheck() }) {
                                HStack(spacing: 4) {
                                    if model.isRechecking {
                                        ProgressView().scaleEffect(0.6)
                                    }
                                    Text(model.isRechecking ? "Rechecking…" : "Recheck")
                                        .font(.caption)
                                }
                            }
                            .buttonStyle(.borderedProminent).tint(.orange)
                            .disabled(model.isRechecking)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(Color.orange.opacity(0.08))
                        Divider()
                    }
                    List(model.pending, id: \.id) { e in
                        EventRow(
                            event:     e,
                            ipRep:     model.ipRepCache[String(e.remote.split(separator: ":").first ?? Substring(e.remote))],
                            onConfirm: { model.confirm(e.id) },
                            onReject:  { model.reject(e.id) }
                        )
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    }
                }
            }
        }
    }

    private var historyTab: some View {
        Group {
            if model.recent.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No history yet").foregroundStyle(.secondary)
                    Text("Resolved events will appear here.")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                }
            } else {
                List(model.recent, id: \.id) { e in
                    EventRow(
                        event:    e,
                        onRevert: e.status != "pending" ? { model.revert(e.id) } : nil
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                }
            }
        }
    }

    private var settingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // ── Status banner (Ollama down / models missing) ──────────────
                if !model.ollamaAvailable {
                    statusBanner(
                        icon: "exclamationmark.triangle.fill", color: .orange,
                        title: "Ollama not running",
                        message: "Start Ollama to enable LLM analysis and autonomous mode."
                    ) {
                        Button("Start Ollama") {
                            let t = Process()
                            t.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ollama")
                            t.arguments = ["serve"]
                            try? t.run()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.refresh() }
                        }
                        .buttonStyle(.borderedProminent).tint(.orange)
                    }
                } else if model.llmModels.isEmpty || model.embedModels.isEmpty {
                    statusBanner(
                        icon: "arrow.down.circle.fill", color: .blue,
                        title: "Models not downloaded",
                        message: "LLM and embedding models are required for analysis."
                    ) {
                        Button(action: { model.pullModels() }) {
                            HStack(spacing: 4) {
                                if model.isPulling { ProgressView().scaleEffect(0.7) }
                                Text(model.isPulling ? "Downloading…" : "Download Models")
                            }
                        }
                        .buttonStyle(.borderedProminent).disabled(model.isPulling)
                    }
                    if !model.pullLog.isEmpty { logView(model.pullLog, height: 80) }
                }

                // ── Analysis ─────────────────────────────────────────────────
                // Groups mode toggle + LLM model picker + run button together
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        // Mode toggle row
                        HStack(alignment: .top, spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { model.autonomousMode },
                                set: { _ in model.toggleMode() }
                            ))
                            .labelsHidden()
                            .disabled(!model.ollamaAvailable)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Autonomous mode").fontWeight(.medium)
                                Text(
                                    !model.ollamaAvailable
                                    ? "Ollama required — manual review only."
                                    : model.autonomousMode
                                        ? "LLM resolves all events automatically without your review."
                                        : "LLM flags events and waits for your confirm/reject."
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        // LLM model picker
                        HStack {
                            Text("Model").font(.caption).foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
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
                        }
                        Divider()
                        // Run button
                        HStack {
                            Button(action: { model.resolveAll() }) {
                                HStack(spacing: 6) {
                                    if model.isResolving {
                                        ProgressView().scaleEffect(0.7)
                                    } else {
                                        Image(systemName: "play.fill").font(.caption)
                                    }
                                    Text(model.isResolving ? "Analysing…" : "Run analysis now")
                                }
                            }
                            .disabled(model.isResolving || !model.ollamaAvailable)
                            Spacer()
                        }
                        if !model.resolveLog.isEmpty { logView(model.resolveLog, height: 100) }
                    }
                    .padding(8)
                } label: {
                    Label("Analysis", systemImage: "brain").font(.caption).foregroundStyle(.secondary)
                }

                // ── Memory ───────────────────────────────────────────────────
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Model").font(.caption).foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
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
                        }
                        Text("Changing the embedding model clears all stored RAG memory.")
                            .font(.caption2).foregroundStyle(.tertiary).padding(.leading, 52)
                    }
                    .padding(8)
                } label: {
                    Label("Memory  (RAG embeddings)", systemImage: "memorychip").font(.caption).foregroundStyle(.secondary)
                }

                // ── Blocked IPs ───────────────────────────────────────────────
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.blockedIPs.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                                Text("No IPs currently blocked")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        } else {
                            ForEach(model.blockedIPs, id: \.self) { ip in
                                HStack(spacing: 8) {
                                    Image(systemName: "nosign").foregroundStyle(.red).font(.caption)
                                    Text(ip).font(.system(size: 12, design: .monospaced))
                                    Spacer()
                                    Button("Unblock") { model.unblockIP(ip) }
                                        .buttonStyle(.bordered).controlSize(.mini).tint(.orange)
                                }
                            }
                        }
                        Text("IPs blocked by the LLM's block_ip tool. Unblock to allow connections again.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(8)
                } label: {
                    Label("Blocked IPs", systemImage: "shield.slash").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }

    // MARK: Helpers
    @ViewBuilder
    private func statusBanner<A: View>(
        icon: String, color: Color, title: String, message: String,
        @ViewBuilder action: () -> A
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            action()
        }
        .padding(10)
        .background(color.opacity(0.08))
        .cornerRadius(8)
    }

    private func logView(_ lines: [String], height: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .frame(height: height)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(6)
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
