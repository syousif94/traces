import Foundation
import SwiftUI
import WebKit

/// The embedded tscircuit engine: `engine.js` (the unmodified tscircuit compiler, autorouter,
/// checks and exporters) in an off-screen WKWebView, which gets JIT in its web content process.
/// Jobs are JSON and run one at a time; a newer compile makes older results stale.
@MainActor
final class EngineBridge {
    static let shared = EngineBridge()

    let webView: WKWebView
    private var ready = false
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var queue: Task<Void, Never>?
    private var jobCounter = 0
    private let loadDelegate = LoadDelegate()
    private(set) var version = "?"

    private init() {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        #if DEBUG
        if #available(macOS 13.3, iOS 16.4, *) { webView.isInspectable = true }
        #endif
        webView.navigationDelegate = loadDelegate
        loadDelegate.onLoad = { [weak self] in Task { @MainActor in await self?.markReady() } }
        guard let html = Bundle.main.url(forResource: "engine", withExtension: "html") else {
            assertionFailure("engine.html missing from bundle")
            return
        }
        webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }

    private func markReady() async {
        // engine.js is ~16 MB; the load event fires after it has run.
        if let v = try? await call(["id": "v", "kind": "version"], waitForReady: false),
           let t = (v["result"] as? [String: Any])?["tscircuit"] as? String {
            version = t
        }
        ready = true
        for w in readyWaiters { w.resume() }
        readyWaiters = []
    }

    func waitUntilReady() async {
        if ready { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    private func call(_ job: [String: Any], waitForReady: Bool = true) async throws -> [String: Any] {
        if waitForReady { await waitUntilReady() }
        let data = try JSONSerialization.data(withJSONObject: job)
        let text = String(decoding: data, as: UTF8.self)
        let out = try await webView.callAsyncJavaScript("return await TraceworksEngine.run(job)", arguments: ["job": text], contentWorld: .page)
        guard let s = out as? String, let d = s.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw EngineError.badReply
        }
        if (obj["ok"] as? Bool) != true { throw EngineError.failed((obj["error"] as? String) ?? "engine error") }
        return obj
    }

    /// Serialise jobs: each waits for the previous one.
    private func enqueue<T: Sendable>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = queue
        let task = Task { @MainActor () throws -> T in
            await previous?.value
            return try await work()
        }
        queue = Task { _ = try? await task.value }
        return try await task.value
    }

    func nextJobId() -> String { jobCounter += 1; return "job\(jobCounter)" }

    struct CompileResult: Sendable {
        var circuitJSON: Data
        var errors: [EngineMessage]
        var ms: Int
        var raw: String
    }

    func compile(filesJSON: String, entry: String, autoroute: Bool = true) async throws -> CompileResult {
        try await enqueue {
            let files = (try? JSONSerialization.jsonObject(with: Data(filesJSON.utf8))) ?? [:]
            let id = self.nextJobId()
            let reply = try await self.call(["id": id, "kind": "compile", "files": files, "entry": entry, "autoroute": autoroute])
            let r = (reply["result"] as? [String: Any]) ?? [:]
            let cj = r["circuitJson"] ?? []
            let cjData = try JSONSerialization.data(withJSONObject: cj)
            let errors = ((r["errors"] as? [[String: Any]]) ?? []).map(EngineMessage.init)
            let raw = String(decoding: try JSONSerialization.data(withJSONObject: ["circuitJson": cj, "errors": r["errors"] ?? [], "ms": r["ms"] ?? 0]), as: UTF8.self)
            return CompileResult(circuitJSON: cjData, errors: errors, ms: (r["ms"] as? Int) ?? 0, raw: raw)
        }
    }

    func drc(circuitJSON: Data) async throws -> [Violation] {
        try await enqueue {
            let cj = try JSONSerialization.jsonObject(with: circuitJSON)
            let reply = try await self.call(["id": self.nextJobId(), "kind": "drc", "circuitJson": cj])
            let r = (reply["result"] as? [String: Any]) ?? [:]
            return ((r["violations"] as? [[String: Any]]) ?? []).map(Violation.init)
        }
    }

    /// Returns relative path → bytes.
    func export(circuitJSON: Data, formats: [String]) async throws -> [String: Data] {
        try await enqueue {
            let cj = try JSONSerialization.jsonObject(with: circuitJSON)
            let reply = try await self.call(["id": self.nextJobId(), "kind": "export", "circuitJson": cj, "formats": formats])
            let files = ((reply["result"] as? [String: Any])?["files"] as? [String: String]) ?? [:]
            return files.compactMapValues { Data(base64Encoded: $0) }
        }
    }

    /// A raw EasyEDA part (`result` of easyeda.com/api/components/<uuid>) → a tscircuit component
    /// module (TSX) with its footprint, pin labels and supplier part number.
    func easyEDAToTSX(raw: Data) async throws -> String {
        try await enqueue {
            let obj = try JSONSerialization.jsonObject(with: raw)
            let reply = try await self.call(["id": self.nextJobId(), "kind": "easyeda", "raw": obj])
            guard let tsx = (reply["result"] as? [String: Any])?["tsx"] as? String, !tsx.isEmpty else { throw EngineError.badReply }
            return tsx
        }
    }

    enum EngineError: LocalizedError {
        case badReply, failed(String)
        var errorDescription: String? {
            switch self {
            case .badReply: "The engine returned an unreadable reply."
            case .failed(let m): m
            }
        }
    }

    private final class LoadDelegate: NSObject, WKNavigationDelegate {
        var onLoad: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onLoad?() }
    }
}

struct EngineMessage: Sendable, Identifiable, Hashable {
    var id: String { "\(type):\(file ?? ""):\(line ?? 0):\(message)" }
    var type: String
    var message: String
    var file: String?
    var line: Int?
    var col: Int?
    init(_ d: [String: Any]) {
        type = d["type"] as? String ?? "error"
        message = d["message"] as? String ?? type
        file = d["file"] as? String
        line = d["line"] as? Int
        col = d["col"] as? Int
    }
}

struct Violation: Sendable, Identifiable, Hashable {
    let id = UUID()
    var type: String
    var severity: String
    var message: String
    var elementIds: [String]
    var x: Double?
    var y: Double?
    var isError: Bool { severity == "error" }
    init(_ d: [String: Any]) {
        type = d["type"] as? String ?? ""
        severity = d["severity"] as? String ?? "error"
        message = d["message"] as? String ?? type
        elementIds = d["elementIds"] as? [String] ?? []
        x = (d["x"] as? NSNumber)?.doubleValue
        y = (d["y"] as? NSNumber)?.doubleValue
    }
}

/// Keeps the engine's web view in the window hierarchy (so iOS never suspends its JS), invisibly.
struct EngineHostView: View {
    var body: some View {
        EngineWebViewRepresentable().frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false).accessibilityHidden(true)
    }
}

#if os(macOS)
struct EngineWebViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let wv = EngineBridge.shared.webView
        wv.removeFromSuperview()
        container.addSubview(wv)
        return container
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#else
struct EngineWebViewRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let wv = EngineBridge.shared.webView
        wv.removeFromSuperview()
        container.addSubview(wv)
        return container
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
