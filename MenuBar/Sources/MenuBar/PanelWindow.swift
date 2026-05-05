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

struct BaselineEntry: Identifiable {
    let entry:   String   // raw "process|remote" key used for removal
    let process: String
    let remote:  String
    var id: String { entry }
}

struct BlockedIPEntry: Identifiable {
    let ip:      String
    let ts:      String?
    let process: String?
    let remote:  String?
    let reason:  String?
    var id: String { ip }
}

struct OllamaModels: Decodable {
    let available: Bool
    let llm:       [ModelEntry]
    let embed:     [ModelEntry]
    let config:    NetmonConfig?
}

// ── Summary helpers ────────────────────────────────────────────────────────────

/// Parse the [ACTION] prefix stored in event.summary by analyze.py.
struct ParsedSummary {
    let action: String   // e.g. "BLOCK_IP", "AUTO-CONFIRMED", "CONFIRM", "BLOCKED" — empty if absent
    let text: String     // clean text after the prefix (prose explanation)
    let policy: String   // non-empty only for BLOCKED events — the named injection rule that fired
    var isAuto: Bool     { action.hasPrefix("AUTO") }
}

func parseSummary(_ raw: String) -> ParsedSummary {
    guard raw.hasPrefix("["), let close = raw.firstIndex(of: "]") else {
        return ParsedSummary(action: "", text: raw, policy: "")
    }
    let action = String(raw[raw.index(after: raw.startIndex)..<close]).uppercased()
    let rest   = String(raw[raw.index(after: close)...]).trimmingCharacters(in: .whitespaces)

    // For BLOCKED events extract the policy name: "policy: <name>"
    var policy = ""
    if action == "BLOCKED" {
        if let pRange = rest.range(of: "policy: ") {
            let afterPolicy = rest[pRange.upperBound...]
            // take up to the next period, comma, or end of string
            policy = String(afterPolicy.prefix(while: { $0 != "." && $0 != "," && !$0.isNewline }))
                .trimmingCharacters(in: .whitespaces)
        }
    }
    return ParsedSummary(action: action, text: rest, policy: policy)
}

/// Decode lsof \xNN escape sequences in process names (e.g. "Slack\x20" → "Slack").
func decodeEscapes(_ s: String) -> String {
    var result = s
    while let range = result.range(of: #"\\x[0-9a-fA-F]{2}"#, options: .regularExpression) {
        let hex = String(result[result.index(range.lowerBound, offsetBy: 2)..<range.upperBound])
        if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
            result.replaceSubrange(range, with: String(Character(scalar)))
        } else { break }
    }
    return result.trimmingCharacters(in: .whitespaces)
}

// ── Action badge ───────────────────────────────────────────────────────────────

/// Color-coded badge showing what the AI recommended (or auto-decided).
struct ActionBadge: View {
    let action: String
    var large = false

    private var info: (label: String, icon: String, color: Color) {
        switch action {
        case "CONFIRM":        return ("AI: Looks safe",         "checkmark.shield.fill",        .green)
        case "REJECT":         return ("AI: Suspicious",         "exclamationmark.shield.fill",  .orange)
        case "BLOCK_IP":       return ("AI: Block this IP",      "nosign",                       .red)
        case "KILL_PROCESS":   return ("AI: Kill process",       "xmark.octagon.fill",           .red)
        case "INVESTIGATE":    return ("AI: Needs investigation","magnifyingglass",               .blue)
        case "AUTO-CONFIRMED": return ("Auto-confirmed",         "checkmark.circle.fill",        .green)
        case "AUTO-REJECTED":  return ("Auto-rejected",          "xmark.circle.fill",            .red)
        case "BLOCKED":          return ("Injection blocked",       "shield.slash.fill",              .gray)
        case "POLICY_VIOLATION": return ("Policy violation",         "exclamationmark.shield.fill",    .red)
        default:
            guard !action.isEmpty else { return ("", "", .clear) }
            if action.hasPrefix("AUTO-") {
                return ("Auto: \(action.dropFirst(5))", "bolt.circle.fill", .purple)
            }
            return (action.capitalized, "exclamationmark.circle", .secondary)
        }
    }

    var body: some View {
        if !info.label.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: info.icon)
                    .font(large ? .caption : .caption2)
                Text(info.label)
                    .font(large ? .caption : .caption2)
                    .fontWeight(large ? .semibold : .medium)
            }
            .padding(.horizontal, large ? 8 : 6)
            .padding(.vertical,   large ? 4 : 2)
            .background(info.color.opacity(0.13))
            .foregroundStyle(info.color)
            .cornerRadius(5)
        }
    }
}

// ── View-model ────────────────────────────────────────────────────────────────

@MainActor
class PanelModel: ObservableObject {
    @Published var pending:        [Event] = []
    @Published var recent:         [Event] = []
    @Published var autonomousMode  = false
    @Published var backendName     = "ollama"
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
    @Published var blockedIPs:     [BlockedIPEntry] = []
    @Published var isRechecking      = false
    @Published var pfEnforcement     = false
    @Published var pfSudoersReady    = false
    @Published var pfAnchorReady     = false
    @Published var baselineEntries:  [BaselineEntry] = []
    @Published var baselineFilter    = ""

    var usingClaude: Bool { backendName == "claude" }
    var pfSetupNeeded: Bool { !pfSudoersReady || !pfAnchorReady }

    func refresh() {
        fetchPFStatus()
        fetchBlockedIPs()
        fetchBaseline()
        fetchEvents { [weak self] r in
            guard let self, let r else { return }
            self.pending        = r.pending
            self.recent         = r.recent
            self.autonomousMode = r.config?.autonomous_mode ?? self.autonomousMode
            self.backendName    = r.config?.backend ?? "ollama"
            if let m = r.config?.llm_model,   !m.isEmpty { self.selectedLLM   = m }
            if let m = r.config?.embed_model, !m.isEmpty { self.selectedEmbed = m }
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
                if let b = m.config?.backend { self.backendName = b }
                if self.selectedLLM.isEmpty,   let first = m.llm.first   { self.selectedLLM   = first.name }
                if self.selectedEmbed.isEmpty, let first = m.embed.first  { self.selectedEmbed = first.name }
            }
        }.resume()
        refreshLastAnalyzed()
    }

    func fetchBlockedIPs() {
        guard let url = URL(string: "http://localhost:6543/api/blocked-ips") else { return }
        var req = URLRequest(url: url)
        req.setValue("localhost:6543", forHTTPHeaderField: "Host")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["ips"] as? [[String: Any]] else { return }
            let entries = list.compactMap { d -> BlockedIPEntry? in
                guard let ip = d["ip"] as? String else { return nil }
                return BlockedIPEntry(
                    ip:      ip,
                    ts:      d["ts"]      as? String,
                    process: d["process"] as? String,
                    remote:  d["remote"]  as? String,
                    reason:  d["reason"]  as? String
                )
            }
            DispatchQueue.main.async { self.blockedIPs = entries }
        }.resume()
    }

    func fetchBaseline() {
        guard let url = URL(string: "http://localhost:6543/api/baseline") else { return }
        var req = URLRequest(url: url)
        req.setValue("localhost:6543", forHTTPHeaderField: "Host")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["entries"] as? [[String: Any]] else { return }
            let entries = list.compactMap { d -> BaselineEntry? in
                guard let entry = d["entry"] as? String else { return nil }
                return BaselineEntry(
                    entry:   entry,
                    process: d["process"] as? String ?? entry,
                    remote:  d["remote"]  as? String ?? ""
                )
            }
            DispatchQueue.main.async { self.baselineEntries = entries }
        }.resume()
    }

    func removeBaselineEntry(_ entry: String) {
        guard let url  = URL(string: "http://localhost:6543/baseline/remove"),
              let data = try? JSONSerialization.data(withJSONObject: ["entry": entry]) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("localhost:6543",   forHTTPHeaderField: "Host")
        req.httpBody = data
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.fetchBaseline() }
        }.resume()
    }

    func fetchPFStatus() {
        guard let url = URL(string: "http://localhost:6543/api/pf-status") else { return }
        var req = URLRequest(url: url)
        req.setValue("localhost:6543", forHTTPHeaderField: "Host")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            DispatchQueue.main.async {
                self.pfEnforcement  = obj["pf_enforcement"]     as? Bool ?? false
                self.pfSudoersReady = obj["sudoers_configured"] as? Bool ?? false
                self.pfAnchorReady  = obj["anchor_configured"]  as? Bool ?? false
            }
        }.resume()
    }

    func togglePFEnforcement() {
        guard let url  = URL(string: "http://localhost:6543/config"),
              let data = try? JSONSerialization.data(withJSONObject: ["toggle": "pf_enforcement"]) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("localhost:6543",   forHTTPHeaderField: "Host")
        req.httpBody = data
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            if let http = resp as? HTTPURLResponse, http.statusCode == 409,
               let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = obj["error"] as? String {
                DispatchQueue.main.async { self.resolveLog = ["⚠️ \(msg)"] }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.fetchPFStatus() }
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
            let ts = String(last.dropFirst().prefix(19))
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
    func rejectAndBlock(_ id: Int) {
        postAction(id: id, action: "rejected", blockIPAlso: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }
    func revert(_ id: Int) {
        postAction(id: id, action: "revert")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }
    func toggleMode() {
        if !autonomousMode && !usingClaude && !ollamaAvailable { return }
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
    var ipRep:            IPRepInfo? = nil
    var onConfirm:        (() -> Void)? = nil
    var onReject:         (() -> Void)? = nil
    var onRejectAndBlock: (() -> Void)? = nil
    var onRevert:         (() -> Void)? = nil

    @State private var expanded      = false
    @State private var blockOnReject = false

    var body: some View {
        let parsed      = parseSummary(event.summary)
        let displayName = decodeEscapes(event.process)

        VStack(alignment: .leading, spacing: 6) {

            // ── Header: always visible ────────────────────────────────────────
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
                HStack(spacing: 6) {
                    Text(icon(event.severity))
                    Text(displayName).fontWeight(.semibold)
                    Text("→").foregroundStyle(.secondary)
                    Text(event.remote).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(String(event.ts.prefix(16))).font(.caption).foregroundStyle(.tertiary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            // ── Expanded detail ───────────────────────────────────────────────
            if expanded {
                VStack(alignment: .leading, spacing: 8) {

                    // AI recommendation / Security Guard block — prominent at top
                    if parsed.action == "BLOCKED" {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Security Guard", systemImage: "shield.slash.fill")
                                .font(.caption2).foregroundStyle(.tertiary)
                            // Policy name — most important piece of info
                            if !parsed.policy.isEmpty {
                                HStack(spacing: 4) {
                                    Text("Rule triggered:")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Text(parsed.policy)
                                        .font(.caption).fontWeight(.semibold)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.gray.opacity(0.18))
                                        .cornerRadius(4)
                                }
                            }
                            Text("This event was blocked before reaching the AI because its content matched an injection guard rule. Review the raw summary below and manually confirm or reject.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !parsed.text.isEmpty {
                                Text(parsed.text)
                                    .font(.caption2).foregroundStyle(.tertiary).italic()
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(8)
                        .background(Color.gray.opacity(0.08))
                        .cornerRadius(6)
                    } else if parsed.action == "POLICY_VIOLATION" {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Process Policy Violation", systemImage: "exclamationmark.shield.fill")
                                .font(.caption2).foregroundStyle(.red)
                            Text("This process connected to an IP outside its expected range.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !parsed.text.isEmpty {
                                Text(parsed.text)
                                    .font(.caption).foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(8)
                        .background(Color.red.opacity(0.08))
                        .cornerRadius(6)
                    } else if !parsed.action.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("AI Recommendation", systemImage: "brain")
                                .font(.caption2).foregroundStyle(.tertiary)
                            ActionBadge(action: parsed.action, large: true)
                            if !parsed.text.isEmpty {
                                Text(parsed.text)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(8)
                        .background(actionTint(parsed.action))
                        .cornerRadius(6)
                    } else if !event.summary.isEmpty {
                        // No action prefix — show raw summary
                        VStack(alignment: .leading, spacing: 3) {
                            Label("Analysis", systemImage: "text.magnifyingglass")
                                .font(.caption2).foregroundStyle(.tertiary)
                            Text(event.summary)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.06))
                        .cornerRadius(6)
                    }

                    // Full IP reputation
                    if let rep = ipRep {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("IP Reputation", systemImage: rep.isHosting ? "server.rack" : "globe")
                                .font(.caption2).foregroundStyle(.tertiary)
                            Group {
                                if !rep.country.isEmpty { detailRow("Country", rep.country) }
                                if !rep.isp.isEmpty     { detailRow("ISP",     rep.isp)     }
                                if !rep.org.isEmpty && rep.org != rep.isp {
                                    detailRow("Org", rep.org)
                                }
                                if !rep.asn.isEmpty     { detailRow("ASN",     rep.asn)     }
                                detailRow("Datacenter", rep.isHosting ? "Yes" : "No",
                                          color: rep.isHosting ? .orange : .secondary)
                            }
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.06))
                        .cornerRadius(6)
                    }

                    // Event metadata
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Details", systemImage: "info.circle")
                            .font(.caption2).foregroundStyle(.tertiary)
                        detailRow("Event ID", "#\(event.id)")
                        detailRow("Severity", event.severity.capitalized,
                                  color: severityColor(event.severity))
                        detailRow("Time", event.ts)
                        detailRow("Status", event.status.capitalized,
                                  color: statusColor(event.status))
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(6)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))

            } else {
                // ── Collapsed: badge row + summary snippet ────────────────────
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if !parsed.action.isEmpty {
                            ActionBadge(action: parsed.action)
                        }
                        // For blocked events show the policy name inline
                        if parsed.action == "BLOCKED", !parsed.policy.isEmpty {
                            Text(parsed.policy)
                                .font(.caption2).fontWeight(.medium)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.gray.opacity(0.15))
                                .cornerRadius(4)
                        }
                        if let rep = ipRep, !rep.badge.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: rep.isHosting ? "server.rack" : "globe")
                                    .font(.caption2)
                                Text(rep.badge).font(.caption2)
                            }
                            .foregroundStyle(rep.isHosting ? Color.orange : Color.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(rep.isHosting ? Color.orange.opacity(0.1) : Color.secondary.opacity(0.08))
                            .cornerRadius(4)
                        }
                    }
                    // For blocked events, just show the guard reason — not the full prose
                    let display: String = {
                        if parsed.action == "BLOCKED" {
                            return parsed.policy.isEmpty
                                ? "Blocked by injection guard — expand for details"
                                : "Blocked by injection guard (\(parsed.policy)) — expand for details"
                        }
                        return parsed.text.isEmpty ? event.summary : parsed.text
                    }()
                    if !display.isEmpty {
                        Text(display)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }

            // ── Actions ───────────────────────────────────────────────────────
            if let confirm = onConfirm, let reject = onReject {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Button("✓ Confirm", action: confirm)
                            .buttonStyle(.borderedProminent).tint(.green)
                            .help("Adds this connection to your safe baseline — it won't alert again")
                        Button("✗ Reject") {
                            if blockOnReject, let rejectAndBlock = onRejectAndBlock {
                                rejectAndBlock()
                            } else {
                                reject()
                            }
                        }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .help(blockOnReject
                              ? "Flags as suspicious AND adds IP to the block list"
                              : "Flags as suspicious — similar connections will trigger alerts")
                        Spacer()
                        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
                            Text(expanded ? "Less" : "Full review").font(.caption)
                        }
                        .buttonStyle(.bordered).controlSize(.mini)
                    }
                    HStack(spacing: 6) {
                        if onRejectAndBlock != nil {
                            Toggle("Also block IP", isOn: $blockOnReject)
                                .toggleStyle(.checkbox)
                                .font(.caption2)
                        }
                        Text(blockOnReject
                             ? "Reject → flags suspicious + adds to block list"
                             : "Confirm → safe baseline · Reject → flags suspicious")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            } else {
                // History row: show who/what decided
                HStack(spacing: 8) {
                    if parsed.isAuto {
                        ActionBadge(action: parsed.action)
                    } else {
                        HStack(spacing: 3) {
                            Image(systemName: event.status == "confirmed"
                                  ? "person.fill.checkmark" : "person.fill.xmark")
                                .font(.caption2)
                            Text(event.status == "confirmed" ? "You confirmed" : "You rejected")
                                .font(.caption2).fontWeight(.medium)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(statusColor(event.status).opacity(0.1))
                        .foregroundStyle(statusColor(event.status))
                        .cornerRadius(4)
                    }
                    Spacer()
                    if let revert = onRevert {
                        Button(action: revert) {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Resets to pending — removes from baseline or blocklist")
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(severityTint(event.severity))
        .cornerRadius(6)
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label + ":").font(.caption2).foregroundStyle(.tertiary)
                .frame(width: 72, alignment: .trailing)
            Text(value).font(.caption2).foregroundStyle(color)
                .textSelection(.enabled)
            Spacer()
        }
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

    private func severityColor(_ s: String) -> Color {
        switch s {
        case "critical": return .red
        case "warning":  return .orange
        default:         return .secondary
        }
    }

    private func severityTint(_ s: String) -> Color {
        switch s {
        case "critical": return Color.red.opacity(0.07)
        case "warning":  return Color.orange.opacity(0.05)
        default:         return Color.clear
        }
    }

    private func actionTint(_ action: String) -> Color {
        switch action {
        case "BLOCK_IP", "KILL_PROCESS", "REJECT", "AUTO-REJECTED":
            return Color.red.opacity(0.06)
        case "CONFIRM", "AUTO-CONFIRMED":
            return Color.green.opacity(0.05)
        case "INVESTIGATE":
            return Color.blue.opacity(0.05)
        default:
            return Color.secondary.opacity(0.06)
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
            // Backend chip
            if model.usingClaude {
                HStack(spacing: 3) {
                    Image(systemName: "sparkles").font(.caption2)
                    Text("Claude").font(.caption).fontWeight(.medium)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.purple.opacity(0.12))
                .foregroundStyle(Color.purple)
                .cornerRadius(5)
            }
            // Mode chip
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
            .disabled(!model.usingClaude && !model.ollamaAvailable)
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
            Text("Baseline").tag(2)
            Text("Settings").tag(3)
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
        case 2:  baselineTab
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
                    if model.autonomousMode {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .foregroundStyle(.orange)
                            Text("\(model.pending.count) event(s) pending in autonomous mode")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(action: { model.recheck() }) {
                                HStack(spacing: 4) {
                                    if model.isRechecking { ProgressView().scaleEffect(0.6) }
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
                        let hasRealIP = !e.remote.hasPrefix("unknown") && e.remote != "unknown"
                        EventRow(
                            event:            e,
                            ipRep:            model.ipRepCache[String(e.remote.split(separator: ":").first ?? Substring(e.remote))],
                            onConfirm:        { model.confirm(e.id) },
                            onReject:         { model.reject(e.id) },
                            onRejectAndBlock: hasRealIP ? { model.rejectAndBlock(e.id) } : nil
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

    private var baselineTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Filter by process or IP…", text: $model.baselineFilter)
                    .textFieldStyle(.plain).font(.caption)
                if !model.baselineFilter.isEmpty {
                    Button(action: { model.baselineFilter = "" }) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.secondary.opacity(0.06))

            Divider()

            let filtered: [BaselineEntry] = model.baselineFilter.isEmpty
                ? model.baselineEntries
                : model.baselineEntries.filter {
                    $0.process.localizedCaseInsensitiveContains(model.baselineFilter) ||
                    $0.remote.localizedCaseInsensitiveContains(model.baselineFilter)
                  }

            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.shield").font(.title2).foregroundStyle(.secondary)
                    Text(model.baselineEntries.isEmpty ? "Baseline is empty" : "No matching entries")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { entry in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.process)
                                .font(.system(size: 12, design: .monospaced))
                                .fontWeight(.medium)
                            if !entry.remote.isEmpty {
                                Text(entry.remote)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Remove") { model.removeBaselineEntry(entry.entry) }
                            .buttonStyle(.bordered).controlSize(.mini).tint(.orange)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                }
            }

            Divider()
            HStack {
                Text("\(model.baselineEntries.count) entries — safe connections netmon won't alert on")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    private var settingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // ── Backend banner ────────────────────────────────────────────
                if model.usingClaude {
                    statusBanner(
                        icon: "sparkles", color: .purple,
                        title: "Claude API backend active",
                        message: "LLM analysis and autonomous mode use the Anthropic Claude API."
                    ) { EmptyView() }
                } else if !model.ollamaAvailable {
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

                // ── Analysis ──────────────────────────────────────────────────
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { model.autonomousMode },
                                set: { _ in model.toggleMode() }
                            ))
                            .labelsHidden()
                            .disabled(!model.usingClaude && !model.ollamaAvailable)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Autonomous mode").fontWeight(.medium)
                                Text(
                                    (!model.usingClaude && !model.ollamaAvailable)
                                    ? "Ollama or Claude API required."
                                    : model.autonomousMode
                                        ? "AI resolves all events automatically without your review."
                                        : "AI flags events and waits for your confirm/reject."
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        // LLM model picker (only for Ollama backend)
                        if !model.usingClaude {
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
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles").foregroundStyle(.purple).font(.caption)
                                Text("Model: \(model.selectedLLM.isEmpty ? "claude-opus-4-7" : model.selectedLLM)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("(set via config.json llm_model)")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            Divider()
                        }
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
                            .disabled(model.isResolving || (!model.usingClaude && !model.ollamaAvailable))
                            Spacer()
                        }
                        if !model.resolveLog.isEmpty { logView(model.resolveLog, height: 100) }
                    }
                    .padding(8)
                } label: {
                    Label("Analysis", systemImage: "brain").font(.caption).foregroundStyle(.secondary)
                }

                // ── Memory ────────────────────────────────────────────────────
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
                        Text("Embeddings always use Ollama for RAG memory — independent of the LLM backend.")
                            .font(.caption2).foregroundStyle(.tertiary).padding(.leading, 52)
                        Text("Changing the embedding model clears all stored RAG memory.")
                            .font(.caption2).foregroundStyle(.tertiary).padding(.leading, 52)
                    }
                    .padding(8)
                } label: {
                    Label("Memory  (RAG embeddings)", systemImage: "memorychip").font(.caption).foregroundStyle(.secondary)
                }

                // ── Network enforcement ───────────────────────────────────────
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.pfSetupNeeded {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange).font(.caption)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Setup required")
                                        .font(.caption).fontWeight(.semibold)
                                    Text("To enforce blocks at the firewall level, run the setup script once. It will ask for sudo to add a scoped sudoers entry and pf anchor.")
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("~/.netmon/setup-pf.sh")
                                        .font(.system(size: 11, design: .monospaced))
                                        .textSelection(.enabled)
                                        .padding(.top, 2)
                                }
                            }
                        } else {
                            HStack(spacing: 8) {
                                Toggle("Enable network enforcement (pf firewall)", isOn: Binding(
                                    get:  { model.pfEnforcement },
                                    set:  { _ in model.togglePFEnforcement() }
                                ))
                                .toggleStyle(.switch)
                                .font(.caption)
                            }
                            Text(model.pfEnforcement
                                 ? "Blocked IPs are dropped at the firewall — connections cannot be made even if the block list file is bypassed."
                                 : "Blocks are recorded in the block list file only. Enable to also drop packets via pf.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(8)
                } label: {
                    Label("Network Enforcement", systemImage: "network.badge.shield.half.filled")
                        .font(.caption).foregroundStyle(.secondary)
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
                            ForEach(model.blockedIPs) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "nosign").foregroundStyle(.red).font(.caption)
                                        Text(entry.ip)
                                            .font(.system(size: 12, design: .monospaced))
                                            .fontWeight(.semibold)
                                        Spacer()
                                        Button("Unblock") { model.unblockIP(entry.ip) }
                                            .buttonStyle(.bordered).controlSize(.mini).tint(.orange)
                                    }
                                    if let process = entry.process, !process.isEmpty {
                                        HStack(spacing: 4) {
                                            Text("Process:").foregroundStyle(.tertiary)
                                            Text(process).fontWeight(.medium)
                                        }
                                        .font(.caption2)
                                    }
                                    if let reason = entry.reason, !reason.isEmpty {
                                        Text(reason)
                                            .font(.caption2).foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    if let ts = entry.ts, !ts.isEmpty {
                                        Text(ts)
                                            .font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.vertical, 4)
                                if entry.id != model.blockedIPs.last?.id {
                                    Divider()
                                }
                            }
                        }
                        Text("IPs blocked by the AI's block_ip tool. Unblock to allow connections again.")
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
