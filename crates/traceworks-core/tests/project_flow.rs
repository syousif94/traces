//! End-to-end checks of the project model against the real template and a real compile result:
//! agent edits stay on the agent branch, accept merges onto main, placement round-trips.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use traceworks_core::EngineHost;
use traceworks_core::project::Project;
use traceworks_core::tools;

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for e in std::fs::read_dir(from).unwrap().flatten() {
        let p = e.path();
        if p.is_dir() {
            copy_dir(&p, &to.join(e.file_name()));
        } else {
            std::fs::copy(&p, to.join(e.file_name())).unwrap();
        }
    }
}

fn fresh_project() -> (tempfile::TempDir, Arc<Project>) {
    let dir = tempfile::tempdir().unwrap();
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../templates/esp32-s3-devboard");
    let dest = dir.path().join("esp32-s3-devboard");
    copy_dir(&root, &dest);
    let p = Project::open(dest.to_string_lossy().into_owned()).unwrap();
    p.set_circuit_json(std::fs::read_to_string(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/devboard.circuit.json")).unwrap());
    (dir, p)
}

/// A host that "compiles" by returning the fixture, so tools run without the JS engine.
struct FixtureHost;
impl EngineHost for FixtureHost {
    fn compile(&self, _files: String, _autoroute: bool) -> String {
        let cj = std::fs::read_to_string(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/devboard.circuit.json")).unwrap();
        format!("{{\"circuitJson\": {cj}, \"errors\": [], \"ms\": 1}}")
    }
    fn run_drc(&self, _cj: String) -> String {
        "{\"violations\": []}".into()
    }
    fn render_snapshot(&self, _view: String, _hl: Vec<String>) -> Vec<u8> {
        vec![]
    }
    fn export_fab(&self, _f: Vec<String>) -> String {
        "{\"error\": \"not in tests\"}".into()
    }
}

#[test]
fn opens_with_git_and_initial_commit() {
    let (_d, p) = fresh_project();
    assert_eq!(p.current_branch(), "main");
    let h = p.history(10).unwrap();
    assert_eq!(h.len(), 1);
    assert_eq!(h[0].summary, "Initial commit");
    assert!(p.list_files().iter().any(|f| f.path == "index.tsx"));
    assert_eq!(p.entry_path(), "index.tsx");
}

#[test]
fn agent_edit_lives_on_branch_until_accepted() {
    let (_d, p) = fresh_project();
    let host = FixtureHost;
    let out = tools::call(
        &p,
        &host,
        "edit_file",
        &serde_json::json!({"path": "power.tsx", "edits": [{"search": "capacitance=\"10uF\" footprint=\"0402\" pcbX={-5}", "replace": "capacitance=\"22uF\" footprint=\"0402\" pcbX={-5}"}]}),
        "Bigger input capacitor",
    );
    assert!(!out.is_error, "{}", out.text);
    assert_eq!(out.chip, "+1 −1");
    // Main is untouched; the agent view and the branch have the change.
    assert!(!std::fs::read_to_string(Path::new(&p.root_path()).join("power.tsx")).unwrap().contains("22uF"));
    assert!(p.read_file("power.tsx".into(), true).unwrap().contains("22uF"));
    assert_eq!(p.current_branch(), "agent/bigger-input-capacitor");
    let change = p.pending_change().unwrap();
    assert_eq!((change.added, change.removed), (1, 1));
    assert!(p.line_marks("power.tsx".into()).iter().any(|m| m.kind == "modified"));

    // Reopening restores the pending change from the branch.
    let p2 = Project::open(p.root_path()).unwrap();
    assert!(p2.has_pending_change());
    drop(p2);

    // The user edits another part of the same file meanwhile; accept three-way merges.
    let path = Path::new(&p.root_path()).join("power.tsx");
    let user = std::fs::read_to_string(&path).unwrap().replace("AP2112K-3.3", "AP2112K-3.3TRG1");
    std::fs::write(&path, user).unwrap();
    let id = p.accept_change("Use a 22uF input capacitor".into()).unwrap();
    assert!(id.is_some());
    let merged = std::fs::read_to_string(&path).unwrap();
    assert!(merged.contains("22uF") && merged.contains("AP2112K-3.3TRG1"), "{merged}");
    assert_eq!(p.current_branch(), "main");
    assert!(!p.has_pending_change());
    assert_eq!(p.history(10).unwrap()[0].summary, "Use a 22uF input capacitor");
}

#[test]
fn discard_removes_branch() {
    let (_d, p) = fresh_project();
    let out = tools::call(&p, &FixtureHost, "create_file", &serde_json::json!({"path": "esd.tsx", "content": "export const X = 1\n"}), "add esd");
    assert!(!out.is_error);
    assert!(p.has_pending_change());
    p.discard_change().unwrap();
    assert!(!p.has_pending_change());
    assert!(!Path::new(&p.root_path()).join("esd.tsx").exists());
    let repo = git2::Repository::open(p.root_path()).unwrap();
    assert!(repo.find_branch("agent/add-esd", git2::BranchType::Local).is_err());
}

#[test]
fn placement_uses_literals_or_manual_edits() {
    let (_d, p) = fresh_project();
    // D1 has pcbX/pcbY literals at the board root (-4, -10): the literals move.
    let r = p.set_placement("D1".into(), -6.0, -9.0, None).unwrap();
    assert_eq!(r.method, "source_literal");
    let idx = std::fs::read_to_string(Path::new(&p.root_path()).join("index.tsx")).unwrap();
    assert!(idx.contains("name=\"D1\" color=\"green\" footprint=\"0603\" pcbX={-6} pcbY={-9}"), "{idx}");
    // U2 has no literals and the board imports manual-edits.json: a placement relative to its group (-10, 10).
    let r = p.set_placement("U2".into(), -12.0, 12.5, None).unwrap();
    assert_eq!(r.method, "manual_edits");
    let me: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(Path::new(&p.root_path()).join("manual-edits.json")).unwrap()).unwrap();
    assert_eq!(me["pcb_placements"][0]["selector"], ".U2");
    assert_eq!(me["pcb_placements"][0]["center"]["x"], -2.0);
    assert_eq!(me["pcb_placements"][0]["center"]["y"], 2.5);
    // Rotation goes to the source.
    p.set_placement("U2".into(), -12.0, 12.5, Some(90.0)).unwrap();
    let pw = std::fs::read_to_string(Path::new(&p.root_path()).join("power.tsx")).unwrap();
    assert!(pw.contains("pcbRotation={90}"), "{pw}");
    // Touch edits commit on main.
    assert!(p.commit_all("Move D1 and U2".into()).unwrap().is_some());
    assert_eq!(p.history(5).unwrap()[0].files_changed, 3);
}

#[test]
fn tools_report_and_query() {
    let (_d, p) = fresh_project();
    let c = tools::call(&p, &FixtureHost, "compile", &serde_json::json!({}), "x");
    assert_eq!(c.chip, "0 errors");
    let q = tools::call(&p, &FixtureHost, "query_circuit", &serde_json::json!({"selector": ".U1"}), "x");
    assert!(q.text.contains("ESP32-S3-WROOM-1"), "{}", &q.text[..200.min(q.text.len())]);
    let all = tools::call(&p, &FixtureHost, "query_circuit", &serde_json::json!({"selector": "*"}), "x");
    assert!(all.text.contains("\"components\""));
    let d = tools::call(&p, &FixtureHost, "run_drc", &serde_json::json!({}), "x");
    assert_eq!(d.chip, "0 issues");
    let mcp = traceworks_core::mcp::mcp_handle(p.clone(), Arc::new(FixtureHost), r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.into()).unwrap();
    assert!(mcp.contains("set_placement"));
}
