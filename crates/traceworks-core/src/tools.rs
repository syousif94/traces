//! The tool registry. Each tool is declared once with a JSON Schema and a permission class; the
//! in-app agent and the Mac MCP server both call [`call`]. Write tools only ever touch the agent
//! branch (the project's overlay); main changes only when the user accepts.

use crate::circuit;
use crate::diff::{self, SearchReplace};
use crate::project::Project;
use crate::{EngineHost, git};
use serde_json::{Value, json};
use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolClass {
    Read,
    Write,
    Network,
}

impl ToolClass {
    pub fn as_str(&self) -> &'static str {
        match self {
            ToolClass::Read => "read",
            ToolClass::Write => "write",
            ToolClass::Network => "network",
        }
    }
}

pub struct ToolDef {
    pub name: &'static str,
    pub description: &'static str,
    pub schema: Value,
    pub class: ToolClass,
}

pub struct ToolOutput {
    pub text: String,
    pub image_png: Option<Vec<u8>>,
    pub is_error: bool,
    /// Short result for the UI chip ("0 errors", "+6 −1", "3 hits").
    pub chip: String,
    /// The tool changed design files (so the harness requires a compile).
    pub wrote: bool,
    /// The tool changed placement or routing (so the harness requires run_drc).
    pub placement: bool,
}

impl ToolOutput {
    fn ok(text: impl Into<String>, chip: impl Into<String>) -> Self {
        ToolOutput { text: text.into(), image_png: None, is_error: false, chip: chip.into(), wrote: false, placement: false }
    }
    fn err(text: impl Into<String>) -> Self {
        ToolOutput { text: text.into(), image_png: None, is_error: true, chip: "error".into(), wrote: false, placement: false }
    }
}

fn obj(props: Value, required: &[&str]) -> Value {
    json!({"type": "object", "properties": props, "required": required, "additionalProperties": false})
}

pub fn registry() -> Vec<ToolDef> {
    use ToolClass::*;
    vec![
        ToolDef {
            name: "list_files",
            description: "List the project's source files (tsx, ts, json) with sizes. Files changed on the agent branch are marked.",
            schema: obj(json!({}), &[]),
            class: Read,
        },
        ToolDef {
            name: "read_file",
            description: "Read a project file as it is on the agent branch. Optional 1-based inclusive line range. Lines are returned with numbers.",
            schema: obj(
                json!({"path": {"type": "string"}, "start_line": {"type": "integer"}, "end_line": {"type": "integer"}}),
                &["path"],
            ),
            class: Read,
        },
        ToolDef {
            name: "edit_file",
            description: "Edit a file on the agent branch. Give `edits` (search/replace pairs; each search must match the current text exactly once, so copy it from read_file without line numbers) or `diff` (a unified diff for this file). Edits apply in order.",
            schema: obj(
                json!({
                    "path": {"type": "string"},
                    "edits": {"type": "array", "items": obj(json!({"search": {"type": "string"}, "replace": {"type": "string"}}), &["search", "replace"])},
                    "diff": {"type": "string"}
                }),
                &["path"],
            ),
            class: Write,
        },
        ToolDef {
            name: "create_file",
            description: "Create or overwrite a file on the agent branch with `content`.",
            schema: obj(json!({"path": {"type": "string"}, "content": {"type": "string"}}), &["path", "content"]),
            class: Write,
        },
        ToolDef {
            name: "delete_file",
            description: "Delete a file on the agent branch.",
            schema: obj(json!({"path": {"type": "string"}}), &["path"]),
            class: Write,
        },
        ToolDef {
            name: "compile",
            description: "Compile the agent branch with the tscircuit engine (including autorouting). Returns errors (with file/line when known), element counts, routed/unrouted and time. Required after any edit.",
            schema: obj(json!({}), &[]),
            class: Read,
        },
        ToolDef {
            name: "query_circuit",
            description: "Query the latest compiled Circuit JSON. Selector: `*` (board, summary, every component with position), `.U3` (a component, its ports and traces), `net.USB_DP` (a net and its connections), or an element type such as `pcb_trace`.",
            schema: obj(json!({"selector": {"type": "string"}}), &["selector"]),
            class: Read,
        },
        ToolDef {
            name: "search_parts",
            description: "Search JLCPCB/LCSC parts. Returns MPN, LCSC id, package, stock and price.",
            schema: obj(
                json!({"query": {"type": "string"}, "package": {"type": "string"}, "in_stock": {"type": "boolean"}}),
                &["query"],
            ),
            class: Network,
        },
        ToolDef {
            name: "search_registry",
            description: "Search the tscircuit registry for @tsci packages (reusable modules and footprints).",
            schema: obj(json!({"query": {"type": "string"}}), &["query"]),
            class: Network,
        },
        ToolDef {
            name: "set_placement",
            description: "Move a component on the PCB to absolute board coordinates in mm (board centre is 0,0; +y is up) and optionally rotate it (degrees). Writes manual-edits.json, or the component's pcbX/pcbY literals when it has them. Requires run_drc afterwards.",
            schema: obj(
                json!({"component": {"type": "string", "description": "e.g. U3"}, "x": {"type": "number"}, "y": {"type": "number"}, "rotation": {"type": "number"}}),
                &["component", "x", "y"],
            ),
            class: Write,
        },
        ToolDef {
            name: "autoroute",
            description: "Run the autorouter on the agent branch's board and report routed/unrouted connections. (v1 routes every net; `nets` is advisory.)",
            schema: obj(json!({"nets": {"type": "array", "items": {"type": "string"}}, "effort": {"type": "string"}}), &[]),
            class: Write,
        },
        ToolDef {
            name: "run_drc",
            description: "Run design-rule checks on the latest compile. Returns violations with element ids and coordinates. Required after placement or routing changes.",
            schema: obj(json!({"rule_set": {"type": "string"}}), &[]),
            class: Read,
        },
        ToolDef {
            name: "render_snapshot",
            description: "Render a view of the latest compile to an image so you can check the board visually. `highlight` lists component names to outline.",
            schema: obj(
                json!({"view": {"type": "string", "enum": ["pcb", "schematic"]}, "highlight": {"type": "array", "items": {"type": "string"}}}),
                &["view"],
            ),
            class: Read,
        },
        ToolDef {
            name: "export_fab",
            description: "Export fabrication files (gerber, drill, bom, pnp) for the latest compile as a ZIP. Blocked while DRC has errors.",
            schema: obj(json!({"formats": {"type": "array", "items": {"type": "string", "enum": ["gerber", "drill", "bom", "pnp"]}}}), &[]),
            class: Write,
        },
        ToolDef {
            name: "git_log",
            description: "Recent commits on main.",
            schema: obj(json!({"limit": {"type": "integer"}}), &[]),
            class: Read,
        },
        ToolDef {
            name: "git_diff",
            description: "Diff of a commit (`ref`), or of the pending agent branch against main when `ref` is omitted.",
            schema: obj(json!({"ref": {"type": "string"}}), &[]),
            class: Read,
        },
    ]
}

pub fn find(name: &str) -> Option<ToolDef> {
    registry().into_iter().find(|t| t.name == name)
}

fn s<'a>(args: &'a Value, k: &str) -> Option<&'a str> {
    args[k].as_str()
}

fn http_agent() -> ureq::Agent {
    ureq::AgentBuilder::new().timeout(Duration::from_secs(20)).user_agent("traceworks/0.1").build()
}

/// Run one tool. `slug_hint` names the agent branch if this is the first write of the run.
pub fn call(project: &Project, host: &dyn EngineHost, name: &str, args: &Value, slug_hint: &str) -> ToolOutput {
    let Some(def) = find(name) else { return ToolOutput::err(format!("unknown tool {name}")) };
    if def.class == ToolClass::Network && !project.settings().network_tools {
        return ToolOutput::err("network tools are switched off for this project");
    }
    match run(project, host, name, args, slug_hint) {
        Ok(o) => o,
        Err(e) => ToolOutput::err(e.to_string()),
    }
}

fn run(project: &Project, host: &dyn EngineHost, name: &str, args: &Value, slug_hint: &str) -> crate::Result<ToolOutput> {
    use crate::CoreError::Invalid;
    Ok(match name {
        "list_files" => {
            let files = project.list_files();
            let lines: Vec<String> = files
                .iter()
                .map(|f| format!("{}\t{} bytes{}", f.path, f.size, if f.agent_modified { "\t(modified on agent branch)" } else { "" }))
                .collect();
            ToolOutput::ok(lines.join("\n"), format!("{} files", files.len()))
        }
        "read_file" => {
            let path = s(args, "path").ok_or(Invalid("path required".into()))?;
            let text = project.read_file(path.into(), true)?;
            let lines: Vec<&str> = text.lines().collect();
            let start = args["start_line"].as_u64().unwrap_or(1).max(1) as usize;
            let end = args["end_line"].as_u64().map(|e| e as usize).unwrap_or(lines.len()).min(lines.len());
            let body: Vec<String> = (start..=end).filter_map(|i| lines.get(i - 1).map(|l| format!("{i:>4}  {l}"))).collect();
            ToolOutput::ok(body.join("\n"), format!("{} lines", end.saturating_sub(start) + 1))
        }
        "edit_file" | "create_file" | "delete_file" => {
            let path = s(args, "path").ok_or(Invalid("path required".into()))?.trim_start_matches("./").to_string();
            let mut inner = project.lock();
            let old = project.read_as(&inner, &path, true);
            let new = match name {
                "create_file" => Some(s(args, "content").ok_or(Invalid("content required".into()))?.to_string()),
                "delete_file" => None,
                _ => {
                    let cur = old.clone().ok_or_else(|| Invalid(format!("no such file: {path}; use create_file")))?;
                    if let Some(d) = s(args, "diff") {
                        Some(diff::apply_unified(&cur, d)?)
                    } else {
                        let edits: Vec<SearchReplace> = args["edits"]
                            .as_array()
                            .ok_or(Invalid("give `edits` or `diff`".into()))?
                            .iter()
                            .map(|e| SearchReplace {
                                search: e["search"].as_str().unwrap_or("").to_string(),
                                replace: e["replace"].as_str().unwrap_or("").to_string(),
                            })
                            .collect();
                        Some(diff::apply_search_replace(&cur, &edits)?)
                    }
                }
            };
            let fd = diff::file_diff(&path, old.as_deref(), new.as_deref());
            project.agent_write(&mut inner, &path, new, slug_hint)?;
            let mut o = ToolOutput::ok(
                format!("applied to {path} on the agent branch: +{} -{}\n{}", fd.added, fd.removed, fd.unified),
                format!("+{} −{}", fd.added, fd.removed),
            );
            o.wrote = true;
            o.placement = path.ends_with("manual-edits.json");
            o
        }
        "compile" | "autoroute" => {
            let files = {
                let inner = project.lock();
                project.source_files(&inner, true)
            };
            let res: Value = serde_json::from_str(&host.compile(serde_json::to_string(&files)?, true)).unwrap_or(json!({}));
            let cj = res["circuitJson"].clone();
            project.set_circuit_json(cj.to_string());
            let errors: Vec<Value> = res["errors"].as_array().cloned().unwrap_or_default();
            let sum = circuit::summary(&cj);
            let issues = circuit::issues(&cj);
            let n_err = errors.len();
            let routed = sum["routed"].as_u64().unwrap_or(0);
            let total = sum["source_traces"].as_u64().unwrap_or(0);
            let chip = if name == "autoroute" {
                format!("{routed} / {total}")
            } else {
                format!("{n_err} error{}", if n_err == 1 { "" } else { "s" })
            };
            let body = json!({"errors": errors, "summary": sum, "ms": res["ms"], "issues": issues.into_iter().take(40).collect::<Vec<_>>()});
            let mut o = ToolOutput::ok(serde_json::to_string_pretty(&body)?, chip);
            o.is_error = cj.as_array().is_none_or(|a| a.is_empty()) && n_err > 0;
            o
        }
        "query_circuit" => {
            let cj = project.lock().circuit_json.clone();
            if circuit::elements(&cj).is_empty() {
                return Ok(ToolOutput::err("nothing compiled yet; call compile first"));
            }
            let sel = s(args, "selector").unwrap_or("*");
            let mut text = serde_json::to_string(&circuit::query(&cj, sel))?;
            if text.len() > 30_000 {
                text.truncate(30_000);
                text.push_str("…(truncated)");
            }
            ToolOutput::ok(text, sel.to_string())
        }
        "set_placement" => {
            let comp = s(args, "component").ok_or(Invalid("component required".into()))?.trim_start_matches('.').to_string();
            let x = args["x"].as_f64().ok_or(Invalid("x required".into()))?;
            let y = args["y"].as_f64().ok_or(Invalid("y required".into()))?;
            let mut inner = project.lock();
            let r = project.place(&mut inner, &comp, x, y, args["rotation"].as_f64(), true)?;
            let mut o = ToolOutput::ok(
                format!("moved {comp} to ({x}, {y}) via {} ({}) on the agent branch; compile then run_drc", r.method, r.file),
                format!("{x}, {y}"),
            );
            o.wrote = true;
            o.placement = true;
            o
        }
        "run_drc" => {
            let cj = project.lock().circuit_json.clone();
            if circuit::elements(&cj).is_empty() {
                return Ok(ToolOutput::err("nothing compiled yet; call compile first"));
            }
            let res: Value = serde_json::from_str(&host.run_drc(cj.to_string())).unwrap_or(json!({}));
            let v = res["violations"].as_array().cloned().unwrap_or_default();
            let errors = v.iter().filter(|x| x["severity"] == "error").count();
            let warnings = v.len() - errors;
            let chip = match (errors, warnings) {
                (0, 0) => "0 issues".to_string(),
                (0, w) => format!("{w} warning{}", if w == 1 { "" } else { "s" }),
                (e, _) => format!("{e} error{}", if e == 1 { "" } else { "s" }),
            };
            let mut text = serde_json::to_string_pretty(&json!({"errors": errors, "warnings": warnings, "violations": v.into_iter().take(50).collect::<Vec<_>>()}))?;
            if text.len() > 30_000 {
                text.truncate(30_000);
            }
            ToolOutput::ok(text, chip)
        }
        "render_snapshot" => {
            let view = s(args, "view").unwrap_or("pcb").to_string();
            let hl: Vec<String> = args["highlight"].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect()).unwrap_or_default();
            let png = host.render_snapshot(view.clone(), hl);
            if png.is_empty() {
                return Ok(ToolOutput::err(format!("could not render {view}; compile first")));
            }
            let mut o = ToolOutput::ok(format!("{view} snapshot attached"), "viewed");
            o.image_png = Some(png);
            o
        }
        "export_fab" => {
            let formats: Vec<String> = args["formats"]
                .as_array()
                .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
                .filter(|v: &Vec<String>| !v.is_empty())
                .unwrap_or_else(|| vec!["gerber".into(), "drill".into(), "bom".into(), "pnp".into()]);
            let res: Value = serde_json::from_str(&host.export_fab(formats)).unwrap_or(json!({"error": "export failed"}));
            if let Some(e) = res["error"].as_str() {
                return Ok(ToolOutput::err(e.to_string()));
            }
            ToolOutput::ok(res.to_string(), "zip")
        }
        "git_log" => {
            let n = args["limit"].as_u64().unwrap_or(15) as u32;
            let log = project.history(n)?;
            let lines: Vec<String> = log.iter().map(|c| format!("{} {} ({} files)", c.short, c.summary, c.files_changed)).collect();
            ToolOutput::ok(lines.join("\n"), format!("{} commits", log.len()))
        }
        "git_diff" => {
            let diffs = match s(args, "ref") {
                Some(r) => {
                    let repo = git2::Repository::open(project.root_path())?;
                    let id = repo.revparse_single(r)?.peel_to_commit()?.id().to_string();
                    git::commit_diff(&repo, &id)?
                }
                None => project.pending_change().map(|c| c.files).unwrap_or_default(),
            };
            let text: String = diffs.iter().map(|d| d.unified.clone()).collect::<Vec<_>>().join("\n");
            let (a, r): (u32, u32) = diffs.iter().fold((0, 0), |acc, d| (acc.0 + d.added, acc.1 + d.removed));
            ToolOutput::ok(if text.is_empty() { "no changes".into() } else { text }, format!("+{a} −{r}"))
        }
        "search_parts" => {
            let q = s(args, "query").unwrap_or("");
            let mut req = http_agent().get("https://jlcsearch.tscircuit.com/components/list.json").query("search", q).query("limit", "12");
            if let Some(p) = s(args, "package") {
                req = req.query("package", p);
            }
            let v: Value = req.call().map_err(|e| crate::CoreError::Network(e.to_string()))?.into_json()?;
            let in_stock = args["in_stock"].as_bool().unwrap_or(false);
            let parts: Vec<Value> = v["components"]
                .as_array()
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .filter(|c| !in_stock || c["stock"].as_i64().unwrap_or(0) > 0)
                .map(|c| {
                    json!({"mpn": c["mfr"], "lcsc": c["lcsc"].as_i64().map(|n| format!("C{n}")).or(c["lcsc"].as_str().map(str::to_string)),
                           "package": c["package"], "description": c["description"], "stock": c["stock"], "price": c["price"]})
                })
                .collect();
            let n = parts.len();
            ToolOutput::ok(serde_json::to_string_pretty(&parts)?, format!("{n} hit{}", if n == 1 { "" } else { "s" }))
        }
        "search_registry" => {
            let q = s(args, "query").unwrap_or("");
            let v: Value = http_agent()
                .post("https://registry-api.tscircuit.com/packages/search")
                .send_json(json!({"query": q}))
                .map_err(|e| crate::CoreError::Network(e.to_string()))?
                .into_json()?;
            let pkgs: Vec<Value> = v["packages"]
                .as_array()
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .take(12)
                .map(|p| json!({"name": p["name"], "description": p["description"], "stars": p["star_count"]}))
                .collect();
            let n = pkgs.len();
            ToolOutput::ok(serde_json::to_string_pretty(&pkgs)?, format!("{n} package{}", if n == 1 { "" } else { "s" }))
        }
        _ => ToolOutput::err(format!("unknown tool {name}")),
    })
}

/// The registry as JSON for UIs and MCP: `[{name, description, input_schema, class}]`.
#[uniffi::export]
pub fn tools_json() -> String {
    let v: Vec<Value> = registry()
        .into_iter()
        .map(|t| json!({"name": t.name, "description": t.description, "input_schema": t.schema, "class": t.class.as_str()}))
        .collect();
    serde_json::to_string(&v).unwrap()
}
