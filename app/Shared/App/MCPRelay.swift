#if os(macOS)
import Foundation
import Darwin

/// `Traces --mcp`: the stdio side of the MCP server. An MCP client launches the app binary with
/// this flag; it relays newline-delimited JSON-RPC between stdio and the running app's socket.
enum MCPRelay {
    static func run() -> Never {
        let path = ProcessInfo.processInfo.environment["TRACEWORKS_MCP_SOCKET"] ?? MCPServer.socketPath
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in bytes.prefix(raw.count).enumerated() { raw[i] = UInt8(bitPattern: b) } }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard fd >= 0, ok == 0 else {
            // Answer the client's first request rather than hanging.
            let line = readLine() ?? ""
            let id = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["id"] ?? NSNull()
            let obj: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": "Traces is not running, or its MCP server is off (Settings ▸ MCP)."]]
            if let d = try? JSONSerialization.data(withJSONObject: obj) { FileHandle.standardOutput.write(d + Data([0x0A])) }
            exit(1)
        }
        // App → stdout
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { exit(0) }
                FileHandle.standardOutput.write(Data(buf[0..<n]))
            }
        }
        // stdin → app
        while let line = readLine(strippingNewline: true) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let data = Array((line + "\n").utf8)
            var off = 0
            while off < data.count {
                let start = off
                let n = data.withUnsafeBytes { write(fd, $0.baseAddress! + start, data.count - start) }
                if n <= 0 { exit(0) }
                off += n
            }
        }
        shutdown(fd, SHUT_WR)
        Thread.sleep(forTimeInterval: 2)
        exit(0)
    }
}
#endif
