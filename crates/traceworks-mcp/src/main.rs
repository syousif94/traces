//! `traceworks-mcp`: the stdio side of the Traceworks MCP server.
//!
//! An MCP client (Claude Code, another agent) launches this binary; it relays newline-delimited
//! JSON-RPC between stdio and the running Traceworks app's local socket, where the app answers with
//! its tool registry scoped to the open project. Register it with, for example:
//!
//!     claude mcp add traceworks -- /path/to/traceworks-mcp
//!
//! Socket: $TRACEWORKS_MCP_SOCKET, else ~/Library/Application Support/Traceworks/mcp.sock
//! (or the sandboxed app's container equivalent, which is tried second).

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

fn candidates() -> Vec<PathBuf> {
    if let Ok(p) = std::env::var("TRACEWORKS_MCP_SOCKET") {
        return vec![PathBuf::from(p)];
    }
    let home = std::env::var("HOME").unwrap_or_default();
    vec![
        PathBuf::from(&home).join("Library/Application Support/Traceworks/mcp.sock"),
        PathBuf::from(&home).join("Library/Containers/com.sammy.traceworks/Data/Library/Application Support/Traceworks/mcp.sock"),
    ]
}

fn main() {
    let stream = candidates().into_iter().find_map(|p| UnixStream::connect(&p).ok());
    let Some(stream) = stream else {
        // Answer the client's first request with a clear error rather than hanging.
        let stdin = std::io::stdin();
        let mut line = String::new();
        let _ = stdin.lock().read_line(&mut line);
        let id = line.split("\"id\":").nth(1).and_then(|s| s.split([',', '}']).next()).unwrap_or("null").trim().to_string();
        println!(
            "{{\"jsonrpc\":\"2.0\",\"id\":{id},\"error\":{{\"code\":-32000,\"message\":\"Traceworks is not running or has no project open\"}}}}"
        );
        std::process::exit(1);
    };
    let mut to_app = stream.try_clone().expect("socket clone");
    let from_app = BufReader::new(stream);
    // App → stdout
    let reader = std::thread::spawn(move || {
        let mut out = std::io::stdout();
        for line in from_app.lines() {
            let Ok(line) = line else { break };
            if writeln!(out, "{line}").and_then(|_| out.flush()).is_err() {
                break;
            }
        }
    });
    // stdin → app
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        if writeln!(to_app, "{line}").and_then(|_| to_app.flush()).is_err() {
            break;
        }
    }
    let _ = to_app.shutdown(std::net::Shutdown::Write);
    let _ = reader.join();
}
