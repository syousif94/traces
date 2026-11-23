//! MCP (JSON-RPC 2.0) handler for the Mac app's local server: the same tool registry, scoped to the
//! open project, with the same branch-and-review rules (writes land on the agent branch).

use crate::project::Project;
use crate::{EngineHost, tools};
use base64::Engine as _;
use serde_json::{Value, json};
use std::sync::Arc;

/// Handle one JSON-RPC message. Returns the response line, or None for notifications.
#[uniffi::export]
pub fn mcp_handle(project: Arc<Project>, host: Arc<dyn EngineHost>, request: String) -> Option<String> {
    let req: Value = match serde_json::from_str(&request) {
        Ok(v) => v,
        Err(e) => return Some(json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": e.to_string()}}).to_string()),
    };
    let id = req.get("id").cloned();
    let method = req["method"].as_str().unwrap_or("");
    let id = id?; // notifications get no reply
    let result = match method {
        "initialize" => json!({
            "protocolVersion": req["params"]["protocolVersion"].as_str().unwrap_or("2025-06-18"),
            "capabilities": {"tools": {"listChanged": false}},
            "serverInfo": {"name": "traceworks", "version": env!("CARGO_PKG_VERSION")},
            "instructions": format!(
                "Tools for the tscircuit project \"{}\" open in Traces. Writes go to an agent branch the user reviews in the app; compile after edits and run_drc after placement or routing changes.",
                project.name()
            ),
        }),
        "ping" => json!({}),
        "tools/list" => {
            let list: Vec<Value> = tools::registry()
                .into_iter()
                .map(|t| json!({"name": t.name, "description": t.description, "inputSchema": t.schema}))
                .collect();
            json!({"tools": list})
        }
        "tools/call" => {
            let name = req["params"]["name"].as_str().unwrap_or("");
            let args = req["params"]["arguments"].clone();
            let args = if args.is_null() { json!({}) } else { args };
            let out = tools::call(&project, host.as_ref(), name, &args, &format!("mcp {name}"));
            let mut content = vec![json!({"type": "text", "text": out.text})];
            if let Some(png) = out.image_png {
                content.push(json!({"type": "image", "mimeType": "image/png", "data": base64::engine::general_purpose::STANDARD.encode(png)}));
            }
            json!({"content": content, "isError": out.is_error})
        }
        _ => return Some(json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": format!("method not found: {method}")}}).to_string()),
    };
    Some(json!({"jsonrpc": "2.0", "id": id, "result": result}).to_string())
}
