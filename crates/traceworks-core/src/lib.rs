//! Traceworks core, exported to Swift with UniFFI.
//!
//! - [`project::Project`]: one open project folder. Owns every write to it (code editor, touch
//!   placement, agent), the agent's pending branch (an overlay committed to `agent/<slug>`), and git.
//! - [`tools`]: the typed tool registry. The in-app agent and the Mac MCP server both call it.
//! - [`agent::Agent`]: the tool-calling loop with Anthropic and OpenAI-compatible providers.
//! - [`EngineHost`]: implemented in Swift; runs the embedded tscircuit engine and the renderers.

uniffi::setup_scaffolding!();

pub mod agent;
pub mod circuit;
pub mod diff;
pub mod git;
pub mod mcp;
pub mod project;
pub mod tools;

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum CoreError {
    #[error("{0}")]
    Io(String),
    #[error("git: {0}")]
    Git(String),
    #[error("{0}")]
    Invalid(String),
    #[error("network: {0}")]
    Network(String),
    #[error("model: {0}")]
    Model(String),
}

impl From<std::io::Error> for CoreError {
    fn from(e: std::io::Error) -> Self {
        CoreError::Io(e.to_string())
    }
}
impl From<git2::Error> for CoreError {
    fn from(e: git2::Error) -> Self {
        CoreError::Git(e.message().to_string())
    }
}
impl From<serde_json::Error> for CoreError {
    fn from(e: serde_json::Error) -> Self {
        CoreError::Invalid(format!("json: {e}"))
    }
}

pub type Result<T> = std::result::Result<T, CoreError>;

/// The engine and renderers, implemented in Swift. Calls block the calling (Rust worker) thread;
/// Swift hops to the main actor internally. Every payload is JSON so the bridge stays tiny.
#[uniffi::export(with_foreign)]
pub trait EngineHost: Send + Sync {
    /// Compile `files_json` (`{path: source}`) with the tscircuit engine. Returns the engine's
    /// compile result: `{"circuitJson": [...], "errors": [...], "ms": n}`. Swift also shows the
    /// result in the views, so the user watches the agent's board.
    fn compile(&self, files_json: String, autoroute: bool) -> String;
    /// Run DRC on `circuit_json`. Returns `{"violations": [...]}`.
    fn run_drc(&self, circuit_json: String) -> String;
    /// Render `view` ("pcb" | "schematic" | "3d") of the latest compile off-screen, highlighting the
    /// given component names. Returns PNG bytes (empty if the view cannot render).
    fn render_snapshot(&self, view: String, highlight: Vec<String>) -> Vec<u8>;
    /// Export fabrication files for the latest compile. Returns `{"zip": path, "files": [...]}` or
    /// `{"error": "..."}`.
    fn export_fab(&self, formats: Vec<String>) -> String;
}

#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
