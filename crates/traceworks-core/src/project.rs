//! A project: a plain folder the tsci CLI can open unchanged.
//!
//! The working tree is always `main`. The agent never writes it: its edits go to an overlay that is
//! committed to `agent/<slug>` after every write, and only land on main when the user accepts.

use crate::circuit;
use crate::diff::{self, FileDiff, LineMark};
use crate::git;
use crate::{CoreError, Result};
use regex::Regex;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

const SOURCE_EXTS: &[&str] = &["tsx", "ts", "jsx", "js", "json", "md", "kicad_mod"];
const SKIP_DIRS: &[&str] = &[".git", "node_modules", "dist", ".traceworks", ".tscircuit", "build"];

#[derive(Debug, Clone, uniffi::Record)]
pub struct FileEntry {
    pub path: String,
    pub size: u64,
    /// Changed on the pending agent branch.
    pub agent_modified: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AgentChange {
    pub branch: String,
    pub files: Vec<FileDiff>,
    pub added: u32,
    pub removed: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct PlacementResult {
    /// "manual_edits" | "source_literal" | "source_inserted"
    pub method: String,
    pub file: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ProjectSettings {
    pub network_tools: bool,
    pub provider: String,
    pub model: String,
}

pub(crate) struct OverlayFile {
    /// Content on main when the agent first touched the file (None = did not exist).
    base: Option<String>,
    /// Agent's content (None = deleted).
    content: Option<String>,
}

pub(crate) struct Overlay {
    pub(crate) branch: String,
    files: BTreeMap<String, OverlayFile>,
}

pub(crate) struct Inner {
    pub(crate) overlay: Option<Overlay>,
    pub(crate) circuit_json: Arc<Value>,
}

#[derive(uniffi::Object)]
pub struct Project {
    root: PathBuf,
    inner: Mutex<Inner>,
}

fn rel_ok(path: &str) -> Result<String> {
    let p = path.trim_start_matches("./").trim_start_matches('/');
    if p.is_empty() || p.split('/').any(|c| c == ".." || c == ".git") {
        return Err(CoreError::Invalid(format!("path not allowed: {path}")));
    }
    Ok(p.to_string())
}

pub fn slugify(text: &str) -> String {
    let words: Vec<String> = text
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|w| !w.is_empty())
        .filter(|w| !matches!(w.to_ascii_lowercase().as_str(), "the" | "a" | "an" | "on" | "to" | "and" | "please" | "of" | "for" | "in"))
        .take(4)
        .map(|w| w.to_ascii_lowercase())
        .collect();
    if words.is_empty() { "change".into() } else { words.join("-") }
}

impl Project {
    pub(crate) fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn repo(&self) -> Result<git2::Repository> {
        Ok(git2::Repository::open(&self.root)?)
    }

    fn disk_read(&self, path: &str) -> Option<String> {
        std::fs::read_to_string(self.root.join(path)).ok()
    }

    fn disk_write(&self, path: &str, content: &str) -> Result<()> {
        let full = self.root.join(path);
        if let Some(parent) = full.parent() {
            std::fs::create_dir_all(parent)?;
        }
        // Write-then-rename so iCloud and the CLI never see a half-written file.
        let tmp = full.with_extension("traceworks-tmp");
        std::fs::write(&tmp, content)?;
        std::fs::rename(&tmp, &full)?;
        Ok(())
    }

    /// Read a file as the agent (overlay first) or as main.
    pub(crate) fn read_as(&self, inner: &Inner, path: &str, agent: bool) -> Option<String> {
        if agent {
            if let Some(f) = inner.overlay.as_ref().and_then(|o| o.files.get(path)) {
                return f.content.clone();
            }
        }
        self.disk_read(path)
    }

    /// Agent write: lands in the overlay (created on first write) and is committed to the branch.
    pub(crate) fn agent_write(&self, inner: &mut Inner, path: &str, content: Option<String>, slug_hint: &str) -> Result<()> {
        let path = rel_ok(path)?;
        if inner.overlay.is_none() {
            inner.overlay = Some(Overlay { branch: format!("agent/{}", slugify(slug_hint)), files: BTreeMap::new() });
        }
        let base = self.disk_read(&path);
        let ov = inner.overlay.as_mut().unwrap();
        let entry = ov.files.entry(path.clone()).or_insert(OverlayFile { base, content: None });
        entry.content = content;
        if entry.content == entry.base {
            ov.files.remove(&path);
        }
        self.persist_overlay(inner)
    }

    fn persist_overlay(&self, inner: &mut Inner) -> Result<()> {
        let repo = self.repo()?;
        let Some(ov) = inner.overlay.as_ref() else { return Ok(()) };
        if ov.files.is_empty() {
            git::delete_branch(&repo, &ov.branch)?;
            inner.overlay = None;
            return Ok(());
        }
        let files: BTreeMap<String, Option<String>> = ov.files.iter().map(|(p, f)| (p.clone(), f.content.clone())).collect();
        git::write_branch(&repo, &ov.branch, &files, &format!("Agent: work in progress on {}", ov.branch))?;
        Ok(())
    }

    pub(crate) fn source_files(&self, inner: &Inner, agent: bool) -> BTreeMap<String, String> {
        let mut out = BTreeMap::new();
        walk(&self.root, &self.root, &mut |rel, _size| {
            if let Some(c) = self.disk_read(rel) {
                out.insert(rel.to_string(), c);
            }
        });
        if agent {
            if let Some(ov) = &inner.overlay {
                for (p, f) in &ov.files {
                    match &f.content {
                        Some(c) => {
                            out.insert(p.clone(), c.clone());
                        }
                        None => {
                            out.remove(p);
                        }
                    }
                }
            }
        }
        out
    }

    /// Move a component. `agent` decides whether the write goes to the overlay or to main.
    pub(crate) fn place(&self, inner: &mut Inner, name: &str, x: f64, y: f64, rotation: Option<f64>, agent: bool) -> Result<PlacementResult> {
        let cj = inner.circuit_json.clone();
        let pos = circuit::component_position(&cj, name)
            .ok_or_else(|| CoreError::Invalid(format!("no placed component named {name}; compile first")))?;
        let files = self.source_files(inner, agent);
        // 1. Find the JSX element that declares this component.
        let mut decl: Option<(String, usize, usize)> = None;
        for (path, src) in &files {
            if !(path.ends_with(".tsx") || path.ends_with(".jsx")) {
                continue;
            }
            if let Some((s, e)) = find_element(src, name) {
                decl = Some((path.clone(), s, e));
                break;
            }
        }
        let uses_manual_edits = files.iter().any(|(p, s)| p.ends_with(".tsx") && s.contains("manual-edits.json"));
        let write = |me: &Self, inner: &mut Inner, path: &str, content: String| -> Result<()> {
            if agent { me.agent_write(inner, path, Some(content), &format!("move {name}")) } else { me.disk_write(path, &content) }
        };

        if let Some((path, s, e)) = decl.clone() {
            let src = &files[&path];
            let el = &src[s..e];
            let has_x = attr_value(el, "pcbX").is_some();
            let has_y = attr_value(el, "pcbY").is_some();
            let needs_rot = rotation.is_some_and(|r| (r - pos.rotation).abs() > 1e-6);
            if has_x || has_y || !uses_manual_edits || needs_rot {
                // 2a. Edit (or insert) literals in the source.
                let mut new_el = el.to_string();
                let mut method = "source_inserted";
                for (attr, cur, target, rel) in [("pcbX", pos.x, x, pos.group_x), ("pcbY", pos.y, y, pos.group_y)] {
                    match attr_value(&new_el, attr) {
                        Some(v) => {
                            let old: f64 = parse_mm(&v).ok_or_else(|| {
                                CoreError::Invalid(format!("{name}'s {attr} is an expression ({v}); change it in the source or with edit_file"))
                            })?;
                            new_el = set_attr(&new_el, attr, &fmt_num(old + (target - cur)));
                            method = "source_literal";
                        }
                        None if has_x || has_y || !uses_manual_edits => {
                            new_el = set_attr(&new_el, attr, &fmt_num(target - rel));
                        }
                        None => {}
                    }
                }
                if let Some(r) = rotation {
                    new_el = set_attr(&new_el, "pcbRotation", &fmt_num(r));
                }
                let mut out = src.clone();
                out.replace_range(s..e, &new_el);
                if has_x || has_y || !uses_manual_edits {
                    write(self, inner, &path, out)?;
                    return Ok(PlacementResult { method: method.into(), file: path });
                }
                // Rotation only goes to source; position continues to manual edits below.
                write(self, inner, &path, out)?;
            }
        }
        // 2b. manual-edits.json, keyed by selector, relative to the component's group.
        let me_path = "manual-edits.json";
        let cur = self.read_as(inner, me_path, agent).unwrap_or_else(|| "{}".into());
        let mut doc: Value = serde_json::from_str(&cur).unwrap_or_else(|_| json!({}));
        for k in ["pcb_placements", "schematic_placements", "edit_events"] {
            if !doc[k].is_array() {
                doc[k] = json!([]);
            }
        }
        let selector = format!(".{name}");
        let placements = doc["pcb_placements"].as_array_mut().unwrap();
        placements.retain(|p| p["selector"].as_str() != Some(&selector));
        placements.push(json!({
            "selector": selector,
            "center": {"x": round3(x - pos.group_x), "y": round3(y - pos.group_y)},
            "relative_to": "group_center",
        }));
        let text = serde_json::to_string_pretty(&doc)? + "\n";
        write(self, inner, me_path, text)?;
        Ok(PlacementResult { method: "manual_edits".into(), file: me_path.into() })
    }
}

fn round3(v: f64) -> f64 {
    (v * 1000.0).round() / 1000.0
}

fn fmt_num(v: f64) -> String {
    let r = round3(v);
    if r == r.trunc() { format!("{}", r as i64) } else { format!("{r}") }
}

fn parse_mm(v: &str) -> Option<f64> {
    let t = v.trim().trim_matches(|c| c == '{' || c == '}').trim().trim_matches('"').trim_matches('\'');
    t.trim_end_matches("mm").trim().parse().ok()
}

/// Byte span of the JSX element (opening tag) whose `name` attribute is `name`.
pub(crate) fn find_element(src: &str, name: &str) -> Option<(usize, usize)> {
    let re = Regex::new(&format!(r#"\bname\s*=\s*(?:"{0}"|'{0}'|\{{\s*"{0}"\s*\}})"#, regex::escape(name))).ok()?;
    for m in re.find_iter(src) {
        // Walk back to the '<' that opens this tag.
        let before = &src[..m.start()];
        let lt = before.rfind('<')?;
        if !src[lt + 1..].chars().next().is_some_and(|c| c.is_ascii_alphabetic()) {
            continue;
        }
        // Walk forward to the end of the opening tag, skipping braces and strings.
        let bytes = src.as_bytes();
        let (mut i, mut depth, mut quote) = (lt + 1, 0i32, 0u8);
        while i < bytes.len() {
            let c = bytes[i];
            if quote != 0 {
                if c == quote {
                    quote = 0;
                }
            } else if c == b'"' || c == b'\'' || c == b'`' {
                quote = c;
            } else if c == b'{' {
                depth += 1;
            } else if c == b'}' {
                depth -= 1;
            } else if c == b'>' && depth == 0 {
                return Some((lt, i + 1));
            }
            i += 1;
        }
    }
    None
}

/// Raw value text of `attr` in an opening tag: `{-24}`, `"3mm"`.
pub(crate) fn attr_value(el: &str, attr: &str) -> Option<String> {
    let re = Regex::new(&format!(r#"\b{attr}\s*=\s*(\{{[^}}]*\}}|"[^"]*"|'[^']*')"#)).ok()?;
    re.captures(el).map(|c| c[1].to_string())
}

/// Set `attr={value}` in an opening tag, replacing or inserting after the tag name / name attr.
pub(crate) fn set_attr(el: &str, attr: &str, value: &str) -> String {
    let re = Regex::new(&format!(r#"\b{attr}\s*=\s*(\{{[^}}]*\}}|"[^"]*"|'[^']*')"#)).unwrap();
    if re.is_match(el) {
        return re.replace(el, format!("{attr}={{{value}}}").as_str()).into_owned();
    }
    let end = if el.ends_with("/>") { el.len() - 2 } else { el.len() - 1 };
    let head = el[..end].trim_end();
    // Whitespace that sat before `/>` (or `>`) is kept, so the closing keeps its indentation.
    let ws = &el[head.len()..end];
    let ws = if ws.is_empty() && el.ends_with("/>") { " " } else { ws };
    // Multi-line tags get the new attribute on its own line, indented like the last attribute.
    let sep = if head.contains('\n') {
        let indent: String = head.lines().last().unwrap_or("").chars().take_while(|c| c.is_whitespace()).collect();
        format!("\n{indent}")
    } else {
        " ".to_string()
    };
    format!("{head}{sep}{attr}={{{value}}}{ws}{}", &el[end..])
}

fn walk(root: &Path, dir: &Path, f: &mut dyn FnMut(&str, u64)) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    let mut entries: Vec<_> = rd.flatten().collect();
    entries.sort_by_key(|e| e.file_name());
    for e in entries {
        let name = e.file_name().to_string_lossy().into_owned();
        let p = e.path();
        if p.is_dir() {
            if SKIP_DIRS.contains(&name.as_str()) || name.starts_with('.') {
                continue;
            }
            walk(root, &p, f);
        } else {
            let ext = p.extension().and_then(|x| x.to_str()).unwrap_or("");
            if !SOURCE_EXTS.contains(&ext) || name.ends_with(".traceworks-tmp") {
                continue;
            }
            if let Ok(rel) = p.strip_prefix(root) {
                f(&rel.to_string_lossy(), e.metadata().map(|m| m.len()).unwrap_or(0));
            }
        }
    }
}

#[uniffi::export]
impl Project {
    /// Open a project folder; creates the git repo (and .gitignore) on first open and restores a
    /// pending agent branch if one exists.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>> {
        let root = PathBuf::from(&path);
        if !root.is_dir() {
            return Err(CoreError::Io(format!("not a folder: {path}")));
        }
        let gi = root.join(".gitignore");
        if !gi.exists() {
            std::fs::write(&gi, "node_modules/\ndist/\n.traceworks/*\n!.traceworks/threads/\n")?;
        }
        let repo = git::ensure_repo(&root)?;
        let mut overlay = None;
        if let Some((branch, files)) = git::pending_agent_branch(&repo)? {
            let files = files
                .into_iter()
                .map(|(p, content)| {
                    let base = std::fs::read_to_string(root.join(&p)).ok();
                    (p, OverlayFile { base, content })
                })
                .collect();
            overlay = Some(Overlay { branch, files });
        }
        Ok(Arc::new(Project { root, inner: Mutex::new(Inner { overlay, circuit_json: Arc::new(json!([])) }) }))
    }

    pub fn root_path(&self) -> String {
        self.root.to_string_lossy().into_owned()
    }

    pub fn name(&self) -> String {
        self.root.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "project".into())
    }

    pub fn list_files(&self) -> Vec<FileEntry> {
        let inner = self.lock();
        let mut out: BTreeMap<String, FileEntry> = BTreeMap::new();
        walk(&self.root, &self.root, &mut |rel, size| {
            out.insert(rel.to_string(), FileEntry { path: rel.to_string(), size, agent_modified: false });
        });
        if let Some(ov) = &inner.overlay {
            for (p, f) in &ov.files {
                let size = f.content.as_ref().map(|c| c.len() as u64).unwrap_or(0);
                out.insert(p.clone(), FileEntry { path: p.clone(), size, agent_modified: true });
            }
        }
        out.into_values().collect()
    }

    /// `agent_view`: show the pending agent branch's version when there is one.
    pub fn read_file(&self, path: String, agent_view: bool) -> Result<String> {
        let path = rel_ok(&path)?;
        let inner = self.lock();
        self.read_as(&inner, &path, agent_view).ok_or_else(|| CoreError::Io(format!("no such file: {path}")))
    }

    /// The user's own edit (code editor, variables drawer): writes main's working tree.
    pub fn write_file(&self, path: String, content: String) -> Result<()> {
        let path = rel_ok(&path)?;
        self.disk_write(&path, &content)
    }

    pub fn delete_file(&self, path: String) -> Result<()> {
        let path = rel_ok(&path)?;
        std::fs::remove_file(self.root.join(path))?;
        Ok(())
    }

    /// `{path: source}` for the engine.
    pub fn file_map_json(&self, agent_view: bool) -> String {
        let inner = self.lock();
        serde_json::to_string(&self.source_files(&inner, agent_view)).unwrap_or_else(|_| "{}".into())
    }

    /// Entry file the engine compiles: package.json "main", else index.tsx / index.circuit.tsx.
    pub fn entry_path(&self) -> String {
        if let Some(pkg) = self.disk_read("package.json") {
            if let Ok(v) = serde_json::from_str::<Value>(&pkg) {
                if let Some(m) = v["main"].as_str() {
                    if self.root.join(m).exists() {
                        return m.trim_start_matches("./").to_string();
                    }
                }
            }
        }
        for c in ["index.tsx", "index.circuit.tsx", "main.tsx", "board.tsx"] {
            if self.root.join(c).exists() {
                return c.into();
            }
        }
        "index.tsx".into()
    }

    /// Latest Circuit JSON (from whichever compile the UI is showing). Tools read it.
    pub fn set_circuit_json(&self, json: String) {
        let v: Value = serde_json::from_str(&json).unwrap_or_else(|_| json!([]));
        self.lock().circuit_json = Arc::new(v);
    }

    /// Touch placement: move `component` to absolute board coordinates (mm), on main.
    pub fn set_placement(&self, component: String, x: f64, y: f64, rotation: Option<f64>) -> Result<PlacementResult> {
        let mut inner = self.lock();
        let name = component.trim_start_matches('.').to_string();
        self.place(&mut inner, &name, x, y, rotation, false)
    }

    pub fn has_pending_change(&self) -> bool {
        self.lock().overlay.is_some()
    }

    pub fn pending_change(&self) -> Option<AgentChange> {
        let inner = self.lock();
        let ov = inner.overlay.as_ref()?;
        let files: Vec<FileDiff> = ov
            .files
            .iter()
            .map(|(p, f)| {
                let cur = self.disk_read(p);
                diff::file_diff(p, cur.as_deref(), f.content.as_deref())
            })
            .filter(|d| d.added + d.removed > 0)
            .collect();
        let added = files.iter().map(|f| f.added).sum();
        let removed = files.iter().map(|f| f.removed).sum();
        Some(AgentChange { branch: ov.branch.clone(), files, added, removed })
    }

    /// Gutter marks for `path`: the agent's version against main.
    pub fn line_marks(&self, path: String) -> Vec<LineMark> {
        let inner = self.lock();
        let Some(f) = inner.overlay.as_ref().and_then(|o| o.files.get(&path)) else { return vec![] };
        let cur = self.disk_read(&path).unwrap_or_default();
        diff::line_marks(&cur, f.content.as_deref().unwrap_or(""))
    }

    /// Accept the agent's change: three-way merge onto main's working tree (the user may have
    /// edited the same files meanwhile), squash-commit with `message`, delete the agent branch.
    pub fn accept_change(&self, message: String) -> Result<Option<String>> {
        let mut inner = self.lock();
        let Some(ov) = inner.overlay.take() else { return Ok(None) };
        let repo = self.repo()?;
        // Merge everything first so a conflict leaves both main and the branch untouched.
        let mut merged_files: Vec<(String, Option<String>)> = Vec::new();
        let mut conflict: Option<String> = None;
        for (p, f) in &ov.files {
            let cur = self.disk_read(p);
            let merged = match (&f.base, &cur, &f.content) {
                (b, c, new) if b == c => new.clone(),
                (Some(b), Some(c), Some(new)) => match diff::merge3(b, c, new) {
                    Ok(m) => Some(m),
                    Err(_) => {
                        conflict = Some(p.clone());
                        break;
                    }
                },
                (_, _, new) => new.clone(),
            };
            merged_files.push((p.clone(), merged));
        }
        if let Some(p) = conflict {
            inner.overlay = Some(ov);
            return Err(CoreError::Invalid(format!(
                "{p} changed on main since the agent edited it and the edits overlap; resolve by hand or discard"
            )));
        }
        for (p, merged) in merged_files {
            match merged {
                Some(c) => self.disk_write(&p, &c)?,
                None => {
                    let _ = std::fs::remove_file(self.root.join(&p));
                }
            }
        }
        let id = git::commit_all(&repo, &message)?;
        git::delete_branch(&repo, &ov.branch)?;
        Ok(id)
    }

    pub fn discard_change(&self) -> Result<()> {
        let mut inner = self.lock();
        if let Some(ov) = inner.overlay.take() {
            git::delete_branch(&self.repo()?, &ov.branch)?;
        }
        Ok(())
    }

    /// Commit whatever changed on main (touch-edit bursts, code edits). None if nothing changed.
    pub fn commit_all(&self, message: String) -> Result<Option<String>> {
        let _inner = self.lock();
        git::commit_all(&self.repo()?, &message)
    }

    pub fn history(&self, limit: u32) -> Result<Vec<git::CommitInfo>> {
        git::log(&self.repo()?, limit as usize)
    }

    pub fn commit_diff(&self, id: String) -> Result<Vec<FileDiff>> {
        git::commit_diff(&self.repo()?, &id)
    }

    pub fn restore_file(&self, id: String, path: String) -> Result<()> {
        let path = rel_ok(&path)?;
        match git::file_at(&self.repo()?, &id, &path)? {
            Some(c) => self.disk_write(&path, &c),
            None => {
                let _ = std::fs::remove_file(self.root.join(&path));
                Ok(())
            }
        }
    }

    pub fn restore_all(&self, id: String) -> Result<Option<String>> {
        let _inner = self.lock();
        git::restore_all(&self.repo()?, &id)
    }

    pub fn create_branch(&self, name: String, id: String) -> Result<()> {
        git::create_branch(&self.repo()?, &name, &id)
    }

    /// Shown in the title bar: the agent branch while a change is pending, else HEAD's branch.
    pub fn current_branch(&self) -> String {
        if let Some(ov) = &self.lock().overlay {
            return ov.branch.clone();
        }
        self.repo().map(|r| git::head_name(&r)).unwrap_or_else(|_| "main".into())
    }

    /// Changed-on-main paths (uncommitted), for the files list "M" badge.
    pub fn uncommitted_paths(&self) -> Vec<String> {
        let Ok(repo) = self.repo() else { return vec![] };
        let mut opts = git2::StatusOptions::new();
        opts.include_untracked(true);
        let Ok(st) = repo.statuses(Some(&mut opts)) else { return vec![] };
        st.iter().filter_map(|s| s.path().map(str::to_string)).collect()
    }

    pub fn settings(&self) -> ProjectSettings {
        let v: Value = self
            .disk_read(".traceworks/settings.json")
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_else(|| json!({}));
        ProjectSettings {
            network_tools: v["network_tools"].as_bool().unwrap_or(true),
            provider: v["provider"].as_str().unwrap_or("anthropic").to_string(),
            model: v["model"].as_str().unwrap_or("claude-opus-5-5").to_string(),
        }
    }

    pub fn save_settings(&self, settings: ProjectSettings) -> Result<()> {
        let v = json!({"network_tools": settings.network_tools, "provider": settings.provider, "model": settings.model});
        self.disk_write(".traceworks/settings.json", &serde_json::to_string_pretty(&v)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn element_and_attrs() {
        let src = "<group>\n  <chip\n    name=\"U3\"\n    footprint=\"sot23_6\"\n    pcbX={-14}\n    pcbY={4}\n  />\n  <resistor name=\"R1\" resistance=\"1k\" />\n</group>";
        let (s, e) = find_element(src, "U3").unwrap();
        let el = &src[s..e];
        assert!(el.starts_with("<chip") && el.ends_with("/>"));
        assert_eq!(attr_value(el, "pcbX").unwrap(), "{-14}");
        let el2 = set_attr(el, "pcbX", "-12.5");
        assert!(el2.contains("pcbX={-12.5}"));
        let (s, e) = find_element(src, "R1").unwrap();
        let r = set_attr(&src[s..e], "pcbX", "3");
        assert_eq!(r, "<resistor name=\"R1\" resistance=\"1k\" pcbX={3} />");
        let r = set_attr(&src[find_element(src, "U3").unwrap().0..find_element(src, "U3").unwrap().1], "pcbRotation", "90");
        assert!(r.contains("\n    pcbRotation={90}\n  />"), "{r}");
    }

    #[test]
    fn slug() {
        assert_eq!(slugify("Add ESD protection on the USB data lines."), "add-esd-protection-usb");
    }
}
