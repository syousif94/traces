//! The diff applier: search/replace edits, unified-diff patches, three-way merge, and the diffs the
//! UI shows (unified text, +/− counts, per-line gutter marks).

use crate::{CoreError, Result};
use similar::{ChangeTag, TextDiff};

#[derive(Debug, Clone, uniffi::Record)]
pub struct FileDiff {
    pub path: String,
    pub unified: String,
    pub added: u32,
    pub removed: u32,
    /// "added" | "modified" | "deleted"
    pub status: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct LineMark {
    /// 1-based line in the new text.
    pub line: u32,
    /// "added" | "modified" | "deleted_after" (lines removed just after this one)
    pub kind: String,
}

pub struct SearchReplace {
    pub search: String,
    pub replace: String,
}

/// Apply search/replace pairs in order. Each search must match exactly once; if an exact match
/// fails, a match that ignores trailing whitespace on each line is tried.
pub fn apply_search_replace(content: &str, edits: &[SearchReplace]) -> Result<String> {
    let mut text = content.to_string();
    for (i, e) in edits.iter().enumerate() {
        if e.search.is_empty() {
            // Empty search appends.
            if !text.ends_with('\n') && !text.is_empty() {
                text.push('\n');
            }
            text.push_str(&e.replace);
            continue;
        }
        let n = text.matches(&e.search).count();
        if n == 1 {
            text = text.replacen(&e.search, &e.replace, 1);
            continue;
        }
        if n > 1 {
            return Err(CoreError::Invalid(format!(
                "edit {}: search text matches {n} times; include more surrounding lines so it is unique",
                i + 1
            )));
        }
        match fuzzy_find(&text, &e.search) {
            Some((start, end)) => text.replace_range(start..end, &e.replace),
            None => {
                return Err(CoreError::Invalid(format!(
                    "edit {}: search text not found; read_file first and copy the exact lines",
                    i + 1
                )));
            }
        }
    }
    Ok(text)
}

/// Find `needle` in `hay` comparing line by line with trailing whitespace ignored. Returns a byte
/// range in `hay` when exactly one match exists.
fn fuzzy_find(hay: &str, needle: &str) -> Option<(usize, usize)> {
    let nlines: Vec<&str> = needle.trim_end_matches('\n').lines().map(str::trim_end).collect();
    if nlines.is_empty() {
        return None;
    }
    let mut offsets = Vec::new();
    let mut pos = 0;
    let hlines: Vec<&str> = hay.split_inclusive('\n').collect();
    for l in &hlines {
        offsets.push(pos);
        pos += l.len();
    }
    offsets.push(pos);
    let mut found = None;
    for i in 0..hlines.len() {
        if i + nlines.len() > hlines.len() {
            break;
        }
        if (0..nlines.len()).all(|k| hlines[i + k].trim_end() == nlines[k]) {
            if found.is_some() {
                return None;
            }
            let end_line = i + nlines.len() - 1;
            let mut end = offsets[end_line + 1];
            if !needle.ends_with('\n') && hlines[end_line].ends_with('\n') {
                end -= 1;
            }
            found = Some((offsets[i], end));
        }
    }
    found
}

/// Apply a unified diff (one file's hunks) to `content`.
pub fn apply_unified(content: &str, patch: &str) -> Result<String> {
    let patch = if patch.contains("--- ") {
        patch.to_string()
    } else {
        format!("--- a\n+++ b\n{patch}")
    };
    let p = diffy::Patch::from_str(&patch).map_err(|e| CoreError::Invalid(format!("bad diff: {e}")))?;
    diffy::apply(content, &p).map_err(|e| CoreError::Invalid(format!("diff does not apply: {e}; read_file and retry")))
}

/// Three-way merge used when the user edited a file the agent also changed.
pub fn merge3(base: &str, ours: &str, theirs: &str) -> std::result::Result<String, String> {
    diffy::merge(base, ours, theirs)
}

pub fn file_diff(path: &str, old: Option<&str>, new: Option<&str>) -> FileDiff {
    let o = old.unwrap_or("");
    let n = new.unwrap_or("");
    let d = TextDiff::from_lines(o, n);
    let (mut added, mut removed) = (0u32, 0u32);
    for c in d.iter_all_changes() {
        match c.tag() {
            ChangeTag::Insert => added += 1,
            ChangeTag::Delete => removed += 1,
            ChangeTag::Equal => {}
        }
    }
    let unified = d
        .unified_diff()
        .context_radius(3)
        .header(&format!("a/{path}"), &format!("b/{path}"))
        .to_string();
    let status = match (old, new) {
        (None, Some(_)) => "added",
        (Some(_), None) => "deleted",
        _ => "modified",
    };
    FileDiff { path: path.to_string(), unified, added, removed, status: status.into() }
}

pub fn line_marks(old: &str, new: &str) -> Vec<LineMark> {
    let d = TextDiff::from_lines(old, new);
    let mut marks = Vec::new();
    for op in d.ops() {
        let (tag, _old_range, new_range) = op.as_tag_tuple();
        match tag {
            similar::DiffTag::Insert => {
                for l in new_range {
                    marks.push(LineMark { line: l as u32 + 1, kind: "added".into() });
                }
            }
            similar::DiffTag::Replace => {
                for l in new_range {
                    marks.push(LineMark { line: l as u32 + 1, kind: "modified".into() });
                }
            }
            similar::DiffTag::Delete => {
                marks.push(LineMark { line: new_range.start as u32, kind: "deleted_after".into() });
            }
            similar::DiffTag::Equal => {}
        }
    }
    marks
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn search_replace_exact_and_fuzzy() {
        let src = "a\n  b  \nc\n";
        let out = apply_search_replace(src, &[SearchReplace { search: "b".into(), replace: "B".into() }]).unwrap();
        assert_eq!(out, "a\n  B  \nc\n");
        let out = apply_search_replace(src, &[SearchReplace { search: "  b\nc".into(), replace: "x".into() }]).unwrap();
        assert_eq!(out, "a\nx\n");
        assert!(apply_search_replace("x\nx\n", &[SearchReplace { search: "x".into(), replace: "y".into() }]).is_err());
    }

    #[test]
    fn unified_roundtrip() {
        let old = "one\ntwo\nthree\n";
        let new = "one\n2\nthree\nfour\n";
        let d = file_diff("f.tsx", Some(old), Some(new));
        assert_eq!((d.added, d.removed), (2, 1));
        assert_eq!(apply_unified(old, &d.unified).unwrap(), new);
        let marks = line_marks(old, new);
        assert!(marks.iter().any(|m| m.line == 2 && m.kind == "modified"));
        assert!(marks.iter().any(|m| m.line == 4 && m.kind == "added"));
    }
}
