//! The agent: a tool-calling loop over the tool registry, with Anthropic and OpenAI-compatible
//! providers. The harness makes the model verify its work: compile after edits, DRC after placement
//! or routing changes, at most 40 tool calls per turn.
//!
//! The thread is kept in Anthropic Messages form (content blocks, including thinking blocks, passed
//! back unchanged) and converted for OpenAI-compatible servers. Threads are saved per project in
//! `.traceworks/threads/` and committed with the board.

use crate::project::Project;
use crate::tools::{self, ToolOutput};
use crate::{CoreError, EngineHost, Result};
use base64::Engine as _;
use serde_json::{Value, json};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const MAX_TOOL_CALLS: usize = 40;
const SYSTEM: &str = include_str!("../prompt/system.md");
const REFERENCE: &str = include_str!("../prompt/tscircuit-reference.md");

#[derive(Debug, Clone, uniffi::Record)]
pub struct ModelConfig {
    /// "anthropic" | "openai" (any OpenAI-compatible server: LM Studio, Ollama, vLLM...)
    pub provider: String,
    /// e.g. https://api.anthropic.com or http://my-mac.tailnet:1234
    pub base_url: String,
    pub model: String,
    pub api_key: String,
    /// Send rendered snapshots to the model (vision-capable models only).
    pub vision: bool,
    /// Anthropic effort: "low" | "medium" | "high" | "xhigh" | "max"
    pub effort: String,
}

/// Receives turn progress as JSON events:
/// `{"type":"text","text"}`, `{"type":"tool_start","id","name","args"}`,
/// `{"type":"tool_end","id","name","chip","ok"}`, `{"type":"error","message"}`,
/// `{"type":"done","summary","stopped"}`.
#[uniffi::export(with_foreign)]
pub trait AgentListener: Send + Sync {
    fn on_event(&self, event_json: String);
}

struct Thread {
    id: String,
    messages: Vec<Value>,
    /// What the panel shows: user messages, text, tool chips. Replayed when the panel opens.
    ui: Vec<Value>,
}

#[derive(uniffi::Object)]
pub struct Agent {
    project: Arc<Project>,
    config: Mutex<ModelConfig>,
    thread: Mutex<Thread>,
    cancel: AtomicBool,
}

fn now_secs() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn threads_dir(project: &Project) -> std::path::PathBuf {
    std::path::Path::new(&project.root_path()).join(".traceworks/threads")
}

fn load_latest_thread(project: &Project) -> Option<Thread> {
    let dir = threads_dir(project);
    let mut files: Vec<_> = std::fs::read_dir(&dir).ok()?.flatten().filter(|e| e.path().extension().is_some_and(|x| x == "json")).collect();
    files.sort_by_key(|e| e.file_name());
    let last = files.pop()?;
    let v: Value = serde_json::from_str(&std::fs::read_to_string(last.path()).ok()?).ok()?;
    Some(Thread {
        id: v["id"].as_str()?.to_string(),
        messages: v["messages"].as_array().cloned().unwrap_or_default(),
        ui: v["ui"].as_array().cloned().unwrap_or_default(),
    })
}

fn new_thread() -> Thread {
    Thread { id: format!("{}", now_secs()), messages: vec![], ui: vec![] }
}

fn system_prompt() -> String {
    format!("{SYSTEM}\n\n# tscircuit reference\n\n{REFERENCE}")
}

#[uniffi::export]
impl Agent {
    #[uniffi::constructor]
    pub fn new(project: Arc<Project>, config: ModelConfig) -> Arc<Self> {
        let thread = load_latest_thread(&project).unwrap_or_else(new_thread);
        Arc::new(Agent { project, config: Mutex::new(config), thread: Mutex::new(thread), cancel: AtomicBool::new(false) })
    }

    pub fn set_config(&self, config: ModelConfig) {
        *self.config.lock().unwrap() = config;
    }

    /// The panel's history for this thread, as a JSON array of events.
    pub fn ui_events_json(&self) -> String {
        serde_json::to_string(&self.thread.lock().unwrap().ui).unwrap_or_else(|_| "[]".into())
    }

    pub fn start_new_thread(&self) {
        *self.thread.lock().unwrap() = new_thread();
    }

    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::SeqCst);
    }

    /// Run one user turn to completion (blocking; call from a background thread). `context` is the
    /// app state the model should see: open file, selection, DRC summary, last compile errors.
    pub fn run_turn(&self, message: String, context: String, host: Arc<dyn EngineHost>, listener: Arc<dyn AgentListener>) -> Result<String> {
        self.cancel.store(false, Ordering::SeqCst);
        let config = self.config.lock().unwrap().clone();
        let emit = |ev: Value, ui: &mut Vec<Value>| {
            listener.on_event(ev.to_string());
            if ev["type"] != "done" {
                ui.push(ev);
            }
        };
        let mut th = self.thread.lock().unwrap();
        let th = &mut *th;
        let user_ev = json!({"type": "user", "text": message});
        th.ui.push(user_ev);
        let text = if context.trim().is_empty() { message.clone() } else { format!("<app_context>\n{context}\n</app_context>\n\n{message}") };
        th.messages.push(json!({"role": "user", "content": [{"type": "text", "text": text}]}));

        let tool_defs: Vec<Value> = tools::registry()
            .into_iter()
            .map(|t| json!({"name": t.name, "description": t.description, "input_schema": t.schema}))
            .collect();
        let system = system_prompt();
        let (mut calls, mut need_compile, mut need_drc, mut reminders) = (0usize, false, false, 0);
        let mut summary = String::new();
        let mut stopped = false;

        loop {
            if self.cancel.load(Ordering::SeqCst) {
                stopped = true;
                break;
            }
            let reply = match config.provider.as_str() {
                "openai" => openai_send(&config, &system, &tool_defs, &th.messages),
                _ => anthropic_send(&config, &system, &tool_defs, &th.messages),
            };
            let (content, stop_reason) = match reply {
                Ok(r) => r,
                Err(e) => {
                    emit(json!({"type": "error", "message": e.to_string()}), &mut th.ui);
                    self.save(th);
                    return Err(e);
                }
            };
            th.messages.push(json!({"role": "assistant", "content": content.clone()}));
            let mut turn_text = String::new();
            for b in &content {
                if b["type"] == "text" {
                    let t = b["text"].as_str().unwrap_or("").trim();
                    if !t.is_empty() {
                        turn_text.push_str(t);
                        emit(json!({"type": "text", "text": t}), &mut th.ui);
                    }
                }
            }
            let uses: Vec<&Value> = content.iter().filter(|b| b["type"] == "tool_use").collect();
            if uses.is_empty() {
                if stop_reason == "refusal" {
                    emit(json!({"type": "error", "message": "The model declined this request."}), &mut th.ui);
                }
                if (need_compile || need_drc) && reminders < 2 && stop_reason != "refusal" {
                    reminders += 1;
                    let what = if need_compile { "compile (then run_drc if placement or routing changed)" } else { "run_drc" };
                    th.messages.push(json!({"role": "user", "content": [{"type": "text", "text": format!("[harness] You changed the design but have not verified it. Call {what} before finishing, then give your summary.")}]}));
                    continue;
                }
                summary = turn_text;
                break;
            }
            let mut results = Vec::new();
            let slug_hint = message.clone();
            for u in uses {
                let id = u["id"].as_str().unwrap_or("").to_string();
                let name = u["name"].as_str().unwrap_or("").to_string();
                let args = u["input"].clone();
                if calls >= MAX_TOOL_CALLS || self.cancel.load(Ordering::SeqCst) {
                    results.push(json!({"type": "tool_result", "tool_use_id": id, "is_error": true, "content": "not run: tool-call limit for this turn reached"}));
                    continue;
                }
                calls += 1;
                emit(json!({"type": "tool_start", "id": id, "name": name, "args": brief_args(&name, &args)}), &mut th.ui);
                let out: ToolOutput = tools::call(&self.project, host.as_ref(), &name, &args, &slug_hint);
                if !out.is_error {
                    if out.wrote {
                        need_compile = true;
                    }
                    if out.placement || name == "autoroute" {
                        need_drc = true;
                    }
                    if name == "compile" || name == "autoroute" {
                        need_compile = false;
                    }
                    if name == "run_drc" {
                        need_drc = false;
                    }
                }
                emit(json!({"type": "tool_end", "id": id, "name": name, "chip": out.chip, "ok": !out.is_error}), &mut th.ui);
                let mut blocks = vec![json!({"type": "text", "text": out.text})];
                if let Some(png) = &out.image_png {
                    if config.vision {
                        blocks.push(json!({"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": base64::engine::general_purpose::STANDARD.encode(png)}}));
                    } else {
                        blocks[0] = json!({"type": "text", "text": "snapshot rendered, but this model has no vision; rely on run_drc and query_circuit"});
                    }
                }
                results.push(json!({"type": "tool_result", "tool_use_id": id, "is_error": out.is_error, "content": blocks}));
            }
            th.messages.push(json!({"role": "user", "content": results}));
            if calls >= MAX_TOOL_CALLS {
                let msg = format!("I've used the {MAX_TOOL_CALLS} tool calls allowed in one turn. Reply \"continue\" to let me keep going, or review the diff so far.");
                emit(json!({"type": "text", "text": msg}), &mut th.ui);
                summary = msg;
                break;
            }
        }
        if stopped {
            emit(json!({"type": "text", "text": "Stopped."}), &mut th.ui);
        }
        listener.on_event(json!({"type": "done", "summary": summary, "stopped": stopped}).to_string());
        self.save(th);
        Ok(summary)
    }
}

impl Agent {
    fn save(&self, th: &Thread) {
        let dir = threads_dir(&self.project);
        let _ = std::fs::create_dir_all(&dir);
        let v = json!({"id": th.id, "messages": th.messages, "ui": th.ui});
        let _ = std::fs::write(dir.join(format!("{}.json", th.id)), serde_json::to_string(&v).unwrap_or_default());
    }
}

/// Short argument text for the chip ("usb.tsx", "U3", "\"usb esd sot23-6\"").
fn brief_args(name: &str, args: &Value) -> String {
    let pick = |k: &str| args[k].as_str().map(str::to_string);
    match name {
        "read_file" | "edit_file" | "create_file" | "delete_file" => pick("path").unwrap_or_default(),
        "search_parts" | "search_registry" => pick("query").map(|q| format!("\"{q}\"")).unwrap_or_default(),
        "query_circuit" => pick("selector").unwrap_or_default(),
        "set_placement" => pick("component").unwrap_or_default(),
        "render_snapshot" => pick("view").unwrap_or_default(),
        "autoroute" => args["nets"].as_array().map(|a| a.iter().filter_map(|v| v.as_str()).collect::<Vec<_>>().join(" ")).unwrap_or_default(),
        _ => String::new(),
    }
}

fn http() -> ureq::Agent {
    ureq::AgentBuilder::new().timeout_connect(Duration::from_secs(15)).timeout(Duration::from_secs(600)).user_agent("traceworks/0.1").build()
}

/// POST JSON with retries on 429 / 5xx / 529 / transport errors.
fn post_json(url: &str, headers: &[(&str, String)], body: &Value) -> Result<Value> {
    let mut delay = Duration::from_secs(2);
    for attempt in 0..4 {
        let mut req = http().post(url).set("content-type", "application/json");
        for (k, v) in headers {
            req = req.set(k, v);
        }
        match req.send_json(body.clone()) {
            Ok(r) => return r.into_json().map_err(|e| CoreError::Model(format!("bad response: {e}"))),
            Err(ureq::Error::Status(code, r)) => {
                let text = r.into_string().unwrap_or_default();
                let retry = code == 429 || code >= 500;
                if !retry || attempt == 3 {
                    let msg = serde_json::from_str::<Value>(&text)
                        .ok()
                        .and_then(|v| v["error"]["message"].as_str().map(str::to_string))
                        .unwrap_or(text);
                    return Err(CoreError::Model(format!("HTTP {code}: {msg}")));
                }
            }
            Err(e) => {
                if attempt == 3 {
                    return Err(CoreError::Network(e.to_string()));
                }
            }
        }
        std::thread::sleep(delay);
        delay *= 2;
    }
    unreachable!()
}

/// Models that accept server-side refusal fallbacks (`fallbacks: "default"`).
fn supports_fallbacks(model: &str) -> bool {
    ["claude-fable-5-2", "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"].contains(&model)
}

fn anthropic_send(cfg: &ModelConfig, system: &str, tools: &[Value], messages: &[Value]) -> Result<(Vec<Value>, String)> {
    if cfg.api_key.trim().is_empty() {
        return Err(CoreError::Model("add your Anthropic API key in Settings".into()));
    }
    let base = if cfg.base_url.trim().is_empty() { "https://api.anthropic.com" } else { cfg.base_url.trim_end_matches('/') };
    let mut body = json!({
        "model": cfg.model,
        "max_tokens": 16000,
        // Stable prefix (tools + system) first; automatic caching covers the growing history.
        "cache_control": {"type": "ephemeral"},
        "system": [{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
        "tools": tools,
        "messages": messages,
    });
    if !cfg.effort.is_empty() {
        body["output_config"] = json!({"effort": cfg.effort});
    }
    let mut headers = vec![("x-api-key", cfg.api_key.trim().to_string()), ("anthropic-version", "2023-06-01".to_string())];
    if supports_fallbacks(&cfg.model) {
        body["fallbacks"] = json!("default");
        headers.push(("anthropic-beta", "server-side-fallback-2026-07-01".into()));
    }
    let v = post_json(&format!("{base}/v1/messages"), &headers, &body)?;
    let content = v["content"].as_array().cloned().unwrap_or_default();
    let stop = v["stop_reason"].as_str().unwrap_or("end_turn").to_string();
    Ok((content, stop))
}

/// Convert the Anthropic-form thread to Chat Completions messages.
fn to_openai(system: &str, messages: &[Value]) -> Vec<Value> {
    let mut out = vec![json!({"role": "system", "content": system})];
    for m in messages {
        let role = m["role"].as_str().unwrap_or("user");
        let blocks = m["content"].as_array().cloned().unwrap_or_default();
        if role == "assistant" {
            let text: Vec<&str> = blocks.iter().filter(|b| b["type"] == "text").filter_map(|b| b["text"].as_str()).collect();
            let calls: Vec<Value> = blocks
                .iter()
                .filter(|b| b["type"] == "tool_use")
                .map(|b| json!({"id": b["id"], "type": "function", "function": {"name": b["name"], "arguments": b["input"].to_string()}}))
                .collect();
            let mut msg = json!({"role": "assistant", "content": text.join("\n")});
            if !calls.is_empty() {
                msg["tool_calls"] = json!(calls);
            }
            out.push(msg);
        } else {
            for b in &blocks {
                match b["type"].as_str() {
                    Some("tool_result") => {
                        let text: Vec<String> = match &b["content"] {
                            Value::String(s) => vec![s.clone()],
                            Value::Array(a) => a.iter().filter_map(|c| c["text"].as_str().map(str::to_string)).collect(),
                            _ => vec![],
                        };
                        out.push(json!({"role": "tool", "tool_call_id": b["tool_use_id"], "content": text.join("\n")}));
                    }
                    Some("text") => out.push(json!({"role": "user", "content": b["text"]})),
                    _ => {}
                }
            }
        }
    }
    out
}

fn openai_send(cfg: &ModelConfig, system: &str, tools: &[Value], messages: &[Value]) -> Result<(Vec<Value>, String)> {
    let base = cfg.base_url.trim_end_matches('/');
    if base.is_empty() {
        return Err(CoreError::Model("set the server URL (for LM Studio: http://<mac>:1234) in Settings".into()));
    }
    let url = if base.ends_with("/v1") { format!("{base}/chat/completions") } else { format!("{base}/v1/chat/completions") };
    let tools: Vec<Value> = tools
        .iter()
        .map(|t| json!({"type": "function", "function": {"name": t["name"], "description": t["description"], "parameters": t["input_schema"]}}))
        .collect();
    let body = json!({"model": cfg.model, "messages": to_openai(system, messages), "tools": tools, "max_tokens": 8000});
    let mut headers = vec![];
    if !cfg.api_key.trim().is_empty() {
        headers.push(("authorization", format!("Bearer {}", cfg.api_key.trim())));
    }
    let v = post_json(&url, &headers, &body)?;
    let msg = &v["choices"][0]["message"];
    let mut content = Vec::new();
    if let Some(t) = msg["content"].as_str() {
        if !t.trim().is_empty() {
            content.push(json!({"type": "text", "text": t}));
        }
    }
    if let Some(calls) = msg["tool_calls"].as_array() {
        for (i, c) in calls.iter().enumerate() {
            let args: Value = c["function"]["arguments"].as_str().and_then(|s| serde_json::from_str(s).ok()).unwrap_or(json!({}));
            let id = c["id"].as_str().map(str::to_string).unwrap_or_else(|| format!("call_{}_{i}", now_secs()));
            content.push(json!({"type": "tool_use", "id": id, "name": c["function"]["name"], "input": args}));
        }
    }
    let stop = if content.iter().any(|b| b["type"] == "tool_use") { "tool_use" } else { "end_turn" };
    Ok((content, stop.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn openai_conversion() {
        let msgs = vec![
            json!({"role": "user", "content": [{"type": "text", "text": "hi"}]}),
            json!({"role": "assistant", "content": [{"type": "thinking", "thinking": ""}, {"type": "text", "text": "ok"}, {"type": "tool_use", "id": "t1", "name": "compile", "input": {}}]}),
            json!({"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": [{"type": "text", "text": "0 errors"}]}]}),
        ];
        let o = to_openai("sys", &msgs);
        assert_eq!(o.len(), 4);
        assert_eq!(o[2]["tool_calls"][0]["function"]["name"], "compile");
        assert_eq!(o[3]["role"], "tool");
    }
}
