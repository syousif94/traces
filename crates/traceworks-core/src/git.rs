//! Git for a project folder (libgit2, vendored). Every project is a repo on `main`. Agent runs live on
//! `agent/<slug>` branches built straight from blobs (no checkout), so the working tree stays on
//! main while the user keeps editing; accepting squashes onto main.

use crate::diff::{FileDiff, file_diff};
use crate::{CoreError, Result};
use git2::{BranchType, IndexAddOption, ObjectType, Oid, Repository, Signature, Tree};
use std::collections::BTreeMap;
use std::path::Path;

#[derive(Debug, Clone, uniffi::Record)]
pub struct CommitInfo {
    pub id: String,
    pub short: String,
    pub summary: String,
    /// Unix seconds.
    pub time: i64,
    pub files_changed: u32,
}

pub fn signature(repo: &Repository) -> Signature<'static> {
    match repo.signature() {
        Ok(s) => Signature::now(s.name().unwrap_or("Traceworks"), s.email().unwrap_or("traceworks@localhost")).unwrap(),
        Err(_) => Signature::now("Traceworks", "traceworks@localhost").unwrap(),
    }
}

/// Open the repo, creating it (with an initial commit on main) if absent.
pub fn ensure_repo(root: &Path) -> Result<Repository> {
    if let Ok(r) = Repository::open(root) {
        if r.head().is_err() {
            commit_all(&r, "Initial commit")?;
        }
        return Ok(r);
    }
    let mut opts = git2::RepositoryInitOptions::new();
    opts.initial_head("main");
    let repo = Repository::init_opts(root, &opts)?;
    commit_all(&repo, "Initial commit")?;
    Ok(repo)
}

fn head_tree(repo: &Repository) -> Option<Tree<'_>> {
    repo.head().ok()?.peel_to_tree().ok()
}

/// Stage everything (respecting .gitignore, including deletions) and commit to HEAD. Returns the new
/// commit id, or None if nothing changed.
pub fn commit_all(repo: &Repository, message: &str) -> Result<Option<String>> {
    let mut index = repo.index()?;
    index.add_all(["*"].iter(), IndexAddOption::DEFAULT, None)?;
    index.update_all(["*"].iter(), None)?;
    index.write()?;
    let tree_id = index.write_tree()?;
    let parent = repo.head().ok().and_then(|h| h.peel_to_commit().ok());
    if let Some(p) = &parent {
        if p.tree_id() == tree_id {
            return Ok(None);
        }
    }
    let tree = repo.find_tree(tree_id)?;
    let sig = signature(repo);
    let parents: Vec<&git2::Commit> = parent.iter().collect();
    let oid = repo.commit(Some("HEAD"), &sig, &sig, message, &tree, &parents)?;
    Ok(Some(oid.to_string()))
}

fn blob_entry(path: &str, id: Oid, len: usize) -> git2::IndexEntry {
    git2::IndexEntry {
        ctime: git2::IndexTime::new(0, 0),
        mtime: git2::IndexTime::new(0, 0),
        dev: 0,
        ino: 0,
        mode: 0o100644,
        uid: 0,
        gid: 0,
        file_size: len as u32,
        id,
        flags: (path.len().min(0xfff)) as u16,
        flags_extended: 0,
        path: path.as_bytes().to_vec(),
    }
}

/// Write `files` (path → Some(content) | None for deleted) on top of HEAD's tree as one commit on
/// `branch`, replacing whatever that branch held. Returns the commit id.
pub fn write_branch(repo: &Repository, branch: &str, files: &BTreeMap<String, Option<String>>, message: &str) -> Result<String> {
    let head = repo.head()?.peel_to_commit()?;
    let mut idx = git2::Index::new()?;
    idx.read_tree(&head.tree()?)?;
    for (path, content) in files {
        match content {
            Some(c) => {
                let id = repo.blob(c.as_bytes())?;
                idx.add(&blob_entry(path, id, c.len()))?;
            }
            None => {
                let _ = idx.remove_path(Path::new(path));
            }
        }
    }
    let tree_id = idx.write_tree_to(repo)?;
    let tree = repo.find_tree(tree_id)?;
    let sig = signature(repo);
    let oid = repo.commit(None, &sig, &sig, message, &tree, &[&head])?;
    repo.reference(&format!("refs/heads/{branch}"), oid, true, "traceworks: agent edit")?;
    Ok(oid.to_string())
}

pub fn delete_branch(repo: &Repository, branch: &str) -> Result<()> {
    if let Ok(mut b) = repo.find_branch(branch, BranchType::Local) {
        b.delete()?;
    }
    Ok(())
}

/// The first `agent/*` branch, with its changes against HEAD (path → new content or None).
pub fn pending_agent_branch(repo: &Repository) -> Result<Option<(String, BTreeMap<String, Option<String>>)>> {
    let Some(head) = head_tree(repo) else { return Ok(None) };
    for b in repo.branches(Some(BranchType::Local))? {
        let (b, _) = b?;
        let Some(name) = b.name()?.map(str::to_string) else { continue };
        if !name.starts_with("agent/") {
            continue;
        }
        let tree = b.get().peel_to_tree()?;
        let changes = tree_changes(repo, Some(&head), &tree)?;
        if changes.is_empty() {
            delete_branch(repo, &name)?;
            continue;
        }
        let map = changes.into_iter().map(|(p, _old, new)| (p, new)).collect();
        return Ok(Some((name, map)));
    }
    Ok(None)
}

fn blob_text(repo: &Repository, id: Oid) -> Option<String> {
    if id.is_zero() {
        return None;
    }
    repo.find_blob(id).ok().map(|b| String::from_utf8_lossy(b.content()).into_owned())
}

/// (path, old, new) for each file that differs between two trees.
fn tree_changes(repo: &Repository, old: Option<&Tree>, new: &Tree) -> Result<Vec<(String, Option<String>, Option<String>)>> {
    let diff = repo.diff_tree_to_tree(old, Some(new), None)?;
    let mut out = Vec::new();
    for d in diff.deltas() {
        let path = d.new_file().path().or(d.old_file().path()).map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
        out.push((path, blob_text(repo, d.old_file().id()), blob_text(repo, d.new_file().id())));
    }
    Ok(out)
}

pub fn log(repo: &Repository, limit: usize) -> Result<Vec<CommitInfo>> {
    let mut walk = repo.revwalk()?;
    if walk.push_head().is_err() {
        return Ok(vec![]);
    }
    let mut out = Vec::new();
    for oid in walk.take(limit) {
        let c = repo.find_commit(oid?)?;
        let parent_tree = c.parent(0).ok().and_then(|p| p.tree().ok());
        let files = repo.diff_tree_to_tree(parent_tree.as_ref(), Some(&c.tree()?), None).map(|d| d.deltas().len()).unwrap_or(0);
        out.push(CommitInfo {
            id: c.id().to_string(),
            short: c.id().to_string()[..7].to_string(),
            summary: c.summary().unwrap_or("").to_string(),
            time: c.time().seconds(),
            files_changed: files as u32,
        });
    }
    Ok(out)
}

pub fn commit_diff(repo: &Repository, id: &str) -> Result<Vec<FileDiff>> {
    let c = repo.find_commit(Oid::from_str(id)?)?;
    let parent_tree = c.parent(0).ok().and_then(|p| p.tree().ok());
    Ok(tree_changes(repo, parent_tree.as_ref(), &c.tree()?)?
        .into_iter()
        .map(|(p, o, n)| file_diff(&p, o.as_deref(), n.as_deref()))
        .collect())
}

pub fn file_at(repo: &Repository, rev: &str, path: &str) -> Result<Option<String>> {
    let obj = repo.revparse_single(rev)?;
    let tree = obj.peel_to_tree()?;
    match tree.get_path(Path::new(path)) {
        Ok(e) if e.kind() == Some(ObjectType::Blob) => Ok(blob_text(repo, e.id())),
        _ => Ok(None),
    }
}

/// Make the working tree match `id` (tracked files), then commit that as a new commit on main.
pub fn restore_all(repo: &Repository, id: &str) -> Result<Option<String>> {
    let c = repo.find_commit(Oid::from_str(id)?)?;
    let mut co = git2::build::CheckoutBuilder::new();
    co.force().remove_untracked(false);
    repo.checkout_tree(c.as_object(), Some(&mut co))?;
    commit_all(repo, &format!("Restore board to {}", &id[..7.min(id.len())]))
}

pub fn create_branch(repo: &Repository, name: &str, id: &str) -> Result<()> {
    let c = repo.find_commit(Oid::from_str(id)?)?;
    repo.branch(name, &c, false)?;
    Ok(())
}

pub fn head_name(repo: &Repository) -> String {
    repo.head().ok().and_then(|h| h.shorthand().map(str::to_string)).unwrap_or_else(|| "main".into())
}

pub fn err(msg: impl Into<String>) -> CoreError {
    CoreError::Git(msg.into())
}
