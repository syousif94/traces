import Foundation
import Observation

/// The agent panel's state. The loop itself runs in the Rust core on a background thread; events
/// stream back here as chips and text.
@Observable @MainActor
final class AgentSession {
    struct Item: Identifiable, Equatable {
        enum Kind: Equatable { case user, text, tool, error }
        let id: String
        var kind: Kind
        var text: String
        var name: String = ""
        var args: String = ""
        var chip: String = ""
        var running = false
        var ok = true
    }

    private weak var document: DocumentModel?
    private var agent: Agent?
    var items: [Item] = []
    var running = false
    var draft = ""
    var lastSummary = ""
    var lastRequest = ""
    var provider: String

    init(document: DocumentModel) {
        self.document = document
        provider = document.project.settings().provider
        let a = Agent(project: document.project, config: AppSettings.shared.modelConfig(provider: provider))
        agent = a
        restore(from: a.uiEventsJson())
    }

    var modelLabel: String { AppSettings.shared.label(provider: provider) }

    func setProvider(_ p: String) {
        provider = p
        guard let doc = document else { return }
        var s = doc.project.settings()
        s.provider = p
        s.model = p == "openai" ? AppSettings.shared.openAIModel : AppSettings.shared.anthropicModel
        try? doc.project.saveSettings(settings: s)
    }

    private func restore(from json: String) {
        guard let arr = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return }
        for ev in arr { handle(ev, live: false) }
        if let lastUser = items.last(where: { $0.kind == .user }) { lastRequest = lastUser.text }
        lastSummary = items.last(where: { $0.kind == .text })?.text ?? ""
    }

    func newThread() {
        agent?.startNewThread()
        items = []
    }

    func cancel() { agent?.cancel() }

    func send(_ message: String? = nil) {
        let text = (message ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running, let doc = document, let agent else { return }
        draft = ""
        running = true
        lastRequest = text
        doc.flushTouchCommit()
        agent.setConfig(config: AppSettings.shared.modelConfig(provider: provider))
        let context = buildContext(doc)
        let host = doc.host!
        let listener = Listener { [weak self] json in
            Task { @MainActor in
                guard let ev = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
                self?.handle(ev, live: true)
            }
        }
        Task.detached(priority: .userInitiated) {
            _ = try? agent.runTurn(message: text, context: context, host: host, listener: listener)
            await MainActor.run { [weak self] in
                self?.running = false
                self?.document?.refreshGit()
                self?.document?.refreshFiles()
            }
        }
    }

    private func handle(_ ev: [String: Any], live: Bool) {
        let type = ev["type"] as? String ?? ""
        switch type {
        case "user":
            items.append(Item(id: UUID().uuidString, kind: .user, text: ev["text"] as? String ?? ""))
        case "text":
            let t = ev["text"] as? String ?? ""
            items.append(Item(id: UUID().uuidString, kind: .text, text: t))
            lastSummary = t
        case "tool_start":
            let id = ev["id"] as? String ?? UUID().uuidString
            items.append(Item(id: id, kind: .tool, text: "", name: ev["name"] as? String ?? "", args: ev["args"] as? String ?? "", running: live))
        case "tool_end":
            let id = ev["id"] as? String ?? ""
            if let i = items.lastIndex(where: { $0.id == id }) {
                items[i].running = false
                items[i].chip = ev["chip"] as? String ?? ""
                items[i].ok = ev["ok"] as? Bool ?? true
            }
            if live, let doc = document {
                doc.refreshPending()
                doc.refreshFiles()
            }
        case "error":
            items.append(Item(id: UUID().uuidString, kind: .error, text: ev["message"] as? String ?? "error"))
        case "done":
            running = false
            if let s = ev["summary"] as? String, !s.isEmpty { lastSummary = s }
        default:
            break
        }
    }

    private func buildContext(_ doc: DocumentModel) -> String {
        var lines: [String] = []
        lines.append("project: \(doc.name) (branch \(doc.branch))")
        lines.append("open file: \(doc.openFile)")
        if let s = doc.selection, let c = doc.circuit.component(named: s) {
            lines.append("selected: \(s) \(c.displayPart) at (\(fmt(Double(c.center.x))), \(fmt(Double(c.center.y)))) mm, rotation \(fmt(c.rotation))°, \(c.layer.rawValue)")
        }
        lines.append("board: \(fmt(Double(doc.circuit.boardSize.width))) × \(fmt(Double(doc.circuit.boardSize.height))) mm, \(doc.circuit.components.count) components")
        let rc = doc.routedCounts
        lines.append("routing: \(rc.routed) routed, \(rc.unrouted) unrouted")
        lines.append("DRC: \(doc.drcErrors) errors, \(doc.drcWarnings) warnings")
        for v in doc.violations.filter(\.isError).prefix(5) { lines.append("  - \(v.message)") }
        let errs = doc.compileErrors.filter { $0.type == "compile_error" }
        if errs.isEmpty { lines.append("last compile: ok") }
        for e in errs.prefix(5) { lines.append("compile error: \(e.message)") }
        if doc.pendingChange != nil { lines.append("an earlier agent change is still pending review on this branch; continue on it") }
        return lines.joined(separator: "\n")
    }

    private final class Listener: AgentListener, @unchecked Sendable {
        let f: @Sendable (String) -> Void
        init(_ f: @escaping @Sendable (String) -> Void) { self.f = f }
        func onEvent(eventJson: String) { f(eventJson) }
    }
}
