//! Circuit JSON helpers for the tools: component lookup, selectors, summaries.

use serde_json::{Value, json};

pub fn elements(cj: &Value) -> &[Value] {
    cj.as_array().map(|a| a.as_slice()).unwrap_or(&[])
}

fn ty(e: &Value) -> &str {
    e["type"].as_str().unwrap_or("")
}

pub fn find_by<'a>(cj: &'a Value, t: &str, key: &str, val: &str) -> Option<&'a Value> {
    elements(cj).iter().find(|e| ty(e) == t && e[key].as_str() == Some(val))
}

pub struct ComponentPos {
    pub x: f64,
    pub y: f64,
    pub rotation: f64,
    pub layer: String,
    /// Centre of the component's pcb_group (what manual edits are relative to), or the origin.
    pub group_x: f64,
    pub group_y: f64,
}

pub fn component_position(cj: &Value, name: &str) -> Option<ComponentPos> {
    let src = find_by(cj, "source_component", "name", name)?;
    let sid = src["source_component_id"].as_str()?;
    let pcb = find_by(cj, "pcb_component", "source_component_id", sid)?;
    let (mut gx, mut gy) = (0.0, 0.0);
    if let Some(gid) = pcb["pcb_group_id"].as_str() {
        if let Some(g) = find_by(cj, "pcb_group", "pcb_group_id", gid) {
            let c = if g["anchor_position"].is_object() { &g["anchor_position"] } else { &g["center"] };
            gx = c["x"].as_f64().unwrap_or(0.0);
            gy = c["y"].as_f64().unwrap_or(0.0);
        }
    }
    Some(ComponentPos {
        x: pcb["center"]["x"].as_f64()?,
        y: pcb["center"]["y"].as_f64()?,
        rotation: pcb["rotation"].as_f64().unwrap_or(0.0),
        layer: pcb["layer"].as_str().unwrap_or("top").to_string(),
        group_x: gx,
        group_y: gy,
    })
}

/// Counts the agent sees after a compile.
pub fn summary(cj: &Value) -> Value {
    let els = elements(cj);
    let count = |t: &str| els.iter().filter(|e| ty(e) == t).count();
    let source_traces = count("source_trace");
    let missing = count("pcb_trace_missing_error");
    json!({
        "components": count("source_component"),
        "nets": count("source_net"),
        "source_traces": source_traces,
        "pcb_traces": count("pcb_trace"),
        "vias": count("pcb_via"),
        "routed": source_traces.saturating_sub(missing),
        "unrouted": missing,
    })
}

/// Errors and warnings embedded in the Circuit JSON (`*_error`, `*_warning`).
pub fn issues(cj: &Value) -> Vec<Value> {
    elements(cj)
        .iter()
        .filter(|e| ty(e).ends_with("_error") || ty(e).ends_with("_warning"))
        .map(|e| json!({"type": e["type"], "message": e["message"]}))
        .collect()
}

/// `.U3` → the component (source + pcb + ports); `net.USB_DP` → the net and what it connects;
/// `pcb_trace` (a bare type) → every element of that type; `*` → summary + component table.
pub fn query(cj: &Value, selector: &str) -> Value {
    let els = elements(cj);
    let sel = selector.trim();
    if sel == "*" || sel.is_empty() {
        let comps: Vec<Value> = els
            .iter()
            .filter(|e| ty(e) == "source_component")
            .map(|s| {
                let name = s["name"].as_str().unwrap_or("");
                let pos = component_position(cj, name);
                json!({
                    "name": name,
                    "ftype": s["ftype"],
                    "mpn": s["manufacturer_part_number"],
                    "value": s["display_value"].as_str().or(s["resistance"].as_str()),
                    "x": pos.as_ref().map(|p| round(p.x)),
                    "y": pos.as_ref().map(|p| round(p.y)),
                    "rotation": pos.as_ref().map(|p| p.rotation),
                    "layer": pos.as_ref().map(|p| p.layer.clone()),
                })
            })
            .collect();
        let board = els.iter().find(|e| ty(e) == "pcb_board").cloned().unwrap_or(Value::Null);
        return json!({"summary": summary(cj), "board": {"width": board["width"], "height": board["height"], "center": board["center"]}, "components": comps});
    }
    if let Some(name) = sel.strip_prefix('.') {
        let name = name.split_whitespace().next().unwrap_or(name);
        let Some(src) = find_by(cj, "source_component", "name", name) else {
            return json!({"error": format!("no component named {name}")});
        };
        let sid = src["source_component_id"].as_str().unwrap_or("");
        let pcb = find_by(cj, "pcb_component", "source_component_id", sid).cloned();
        let ports: Vec<Value> = els
            .iter()
            .filter(|e| ty(e) == "source_port" && e["source_component_id"].as_str() == Some(sid))
            .map(|p| {
                let spid = p["source_port_id"].as_str().unwrap_or("");
                let pp = find_by(cj, "pcb_port", "source_port_id", spid);
                let nets: Vec<Value> = els
                    .iter()
                    .filter(|t| {
                        ty(t) == "source_trace"
                            && t["connected_source_port_ids"].as_array().is_some_and(|a| a.iter().any(|v| v == spid))
                    })
                    .map(|t| t["display_name"].clone())
                    .collect();
                json!({"name": p["name"], "pin_number": p["pin_number"], "x": pp.map(|p| p["x"].clone()), "y": pp.map(|p| p["y"].clone()), "traces": nets})
            })
            .collect();
        return json!({"source": src, "pcb": pcb, "ports": ports});
    }
    if let Some(net) = sel.strip_prefix("net.") {
        let Some(n) = find_by(cj, "source_net", "name", net) else {
            return json!({"error": format!("no net named {net}")});
        };
        let nid = n["source_net_id"].as_str().unwrap_or("");
        let traces: Vec<Value> = els
            .iter()
            .filter(|t| {
                ty(t) == "source_trace" && t["connected_source_net_ids"].as_array().is_some_and(|a| a.iter().any(|v| v == nid))
            })
            .map(|t| t["display_name"].clone())
            .collect();
        let pcb_traces = els
            .iter()
            .filter(|t| ty(t) == "pcb_trace" && t["connection_name"].as_str() == Some(nid))
            .count();
        return json!({"net": n, "traces": traces, "pcb_trace_segments": pcb_traces});
    }
    let matches: Vec<&Value> = els.iter().filter(|e| ty(e) == sel).take(60).collect();
    json!({"type": sel, "count": els.iter().filter(|e| ty(e) == sel).count(), "elements": matches})
}

fn round(v: f64) -> f64 {
    (v * 1000.0).round() / 1000.0
}
