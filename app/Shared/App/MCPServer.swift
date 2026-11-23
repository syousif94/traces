#if os(macOS)
import Foundation
import Darwin

/// Local MCP server: a unix socket speaking newline-delimited JSON-RPC. The bundled
/// `traceworks-mcp` helper relays stdio to it, so Claude Code / Claude Desktop can drive the open
/// project with the same tool registry as the built-in agent.
final class MCPServer: @unchecked Sendable {
    static let shared = MCPServer()

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var _project: Project?
    private var _host: EngineHost?

    @MainActor var document: DocumentModel? {
        didSet {
            let p = document?.project, h = document?.host
            lock.withLock { _project = p; _host = h }
        }
    }

    static var socketPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Traces", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mcp.sock").path
    }

    /// The app binary doubles as the stdio relay (`Traces --mcp`), so the bundle has one signed executable.
    var helperCommand: String {
        "claude mcp add traces -- \"\(Bundle.main.executablePath ?? "Traces")\" --mcp"
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard fd < 0 else { return }
        let path = Self.socketPath
        unlink(path)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(s); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) }
        }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0, listen(s, 4) == 0 else { close(s); return }
        chmod(path, 0o600)
        fd = s
        Thread.detachNewThread { [weak self] in self?.acceptLoop(s) }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { close(fd); fd = -1; unlink(Self.socketPath) }
    }

    private func acceptLoop(_ s: Int32) {
        while true {
            let c = accept(s, nil, nil)
            if c < 0 { return }
            Thread.detachNewThread { [weak self] in self?.serve(c) }
        }
    }

    private func serve(_ c: Int32) {
        defer { close(c) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(c, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let reply = handle(line)
                if let reply { writeAll(c, reply + "\n") }
            }
        }
    }

    private func handle(_ line: String) -> String? {
        let (p, h) = lock.withLock { (_project, _host) }
        guard let p, let h else {
            let id = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["id"]
            guard let id else { return nil }
            let obj: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": "No project is open in Traces."]]
            return String(decoding: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data(), as: UTF8.self)
        }
        return mcpHandle(project: p, host: h, request: line)
    }

    private func writeAll(_ c: Int32, _ s: String) {
        let data = Array(s.utf8)
        let count = data.count
        var off = 0
        while off < count {
            let start = off
            let n = data.withUnsafeBytes { write(c, $0.baseAddress! + start, count - start) }
            if n <= 0 { return }
            off += n
        }
    }
}
#endif
