use super::{git, git_ok};
use crate::error::Result;
use crate::executor::Executor;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DiffLine {
    /// ' ' context, '+' added, '-' removed, '\\' no-newline marker.
    pub origin: String,
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Hunk {
    pub index: usize,
    pub header: String,
    pub old_start: u32,
    pub old_lines: u32,
    pub new_start: u32,
    pub new_lines: u32,
    pub lines: Vec<DiffLine>,
    pub additions: u32,
    pub deletions: u32,
    /// Verbatim hunk text, reused when building a partial patch.
    pub raw: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FileDiff {
    pub path: String,
    pub old_path: Option<String>,
    /// added | modified | deleted | renamed
    pub status: String,
    pub binary: bool,
    pub additions: u32,
    pub deletions: u32,
    pub hunks: Vec<Hunk>,
    /// Verbatim `diff --git` preamble through the `+++` line.
    pub raw_header: String,
}

/// Parse `git diff` unified output. Keeps raw text so partial patches stay byte-faithful.
pub fn parse_unified(input: &str) -> Vec<FileDiff> {
    let mut files: Vec<FileDiff> = Vec::new();
    let mut cur: Option<FileDiff> = None;
    let mut cur_hunk: Option<Hunk> = None;
    let mut header_done = false;

    fn finish_hunk(cur: &mut Option<FileDiff>, hunk: &mut Option<Hunk>) {
        if let (Some(f), Some(h)) = (cur.as_mut(), hunk.take()) {
            f.additions += h.additions;
            f.deletions += h.deletions;
            f.hunks.push(h);
        }
    }
    fn finish_file(files: &mut Vec<FileDiff>, cur: &mut Option<FileDiff>, hunk: &mut Option<Hunk>) {
        finish_hunk(cur, hunk);
        if let Some(f) = cur.take() {
            files.push(f);
        }
    }

    for line in input.split('\n') {
        if line.starts_with("diff --git ") {
            finish_file(&mut files, &mut cur, &mut cur_hunk);
            header_done = false;
            let (old_path, path) = parse_diff_git_paths(line);
            cur = Some(FileDiff {
                path,
                old_path,
                status: "modified".into(),
                binary: false,
                additions: 0,
                deletions: 0,
                hunks: Vec::new(),
                raw_header: format!("{line}\n"),
            });
            continue;
        }
        let Some(file) = cur.as_mut() else { continue };

        if line.starts_with("@@") {
            finish_hunk(&mut cur, &mut cur_hunk);
            header_done = true;
            let file = cur.as_mut().unwrap();
            let (os, ol, ns, nl) = parse_hunk_header(line);
            cur_hunk = Some(Hunk {
                index: file.hunks.len(),
                header: line.to_string(),
                old_start: os,
                old_lines: ol,
                new_start: ns,
                new_lines: nl,
                lines: Vec::new(),
                additions: 0,
                deletions: 0,
                raw: format!("{line}\n"),
            });
            continue;
        }

        if !header_done {
            if line.starts_with("new file mode") {
                file.status = "added".into();
            } else if line.starts_with("deleted file mode") {
                file.status = "deleted".into();
            } else if line.starts_with("rename from ") {
                file.status = "renamed".into();
                file.old_path = Some(line.trim_start_matches("rename from ").to_string());
            } else if line.starts_with("rename to ") {
                file.path = line.trim_start_matches("rename to ").to_string();
            } else if line.starts_with("Binary files") || line.starts_with("GIT binary patch") {
                file.binary = true;
            }
            if !line.is_empty() {
                file.raw_header.push_str(line);
                file.raw_header.push('\n');
            }
            continue;
        }

        let Some(h) = cur_hunk.as_mut() else { continue };
        let origin = line.chars().next().unwrap_or(' ');
        match origin {
            '+' | '-' | ' ' | '\\' => {
                h.raw.push_str(line);
                h.raw.push('\n');
                if origin == '+' {
                    h.additions += 1;
                } else if origin == '-' {
                    h.deletions += 1;
                }
                h.lines.push(DiffLine {
                    origin: origin.to_string(),
                    content: line[origin.len_utf8().min(line.len())..].to_string(),
                });
            }
            _ => {
                // Anything else ends the hunk (e.g. trailing blank from split).
                finish_hunk(&mut cur, &mut cur_hunk);
                header_done = false;
            }
        }
    }
    finish_file(&mut files, &mut cur, &mut cur_hunk);
    files
}

fn parse_diff_git_paths(line: &str) -> (Option<String>, String) {
    let rest = line.trim_start_matches("diff --git ");
    if let Some((a, b)) = rest.split_once(" b/") {
        let old = a.trim_start_matches("a/").to_string();
        let new = b.to_string();
        let old_opt = if old == new { None } else { Some(old) };
        (old_opt, new)
    } else {
        (None, rest.to_string())
    }
}

fn parse_hunk_header(line: &str) -> (u32, u32, u32, u32) {
    // @@ -old_start,old_lines +new_start,new_lines @@ optional section heading
    let body = line.trim_start_matches("@@").trim();
    let mut old = (0u32, 1u32);
    let mut new = (0u32, 1u32);
    for tok in body.split_whitespace() {
        if let Some(v) = tok.strip_prefix('-') {
            old = parse_pair(v);
        } else if let Some(v) = tok.strip_prefix('+') {
            new = parse_pair(v);
        } else if tok == "@@" {
            break;
        }
    }
    (old.0, old.1, new.0, new.1)
}

fn parse_pair(v: &str) -> (u32, u32) {
    match v.split_once(',') {
        Some((a, b)) => (a.parse().unwrap_or(0), b.parse().unwrap_or(1)),
        None => (v.parse().unwrap_or(0), 1),
    }
}

/// Build a patch containing only the selected hunks of one file.
/// Hunks are copied verbatim; `git apply` tolerates the line offsets that
/// leaving other hunks out introduces.
pub fn build_patch(file: &FileDiff, hunk_indexes: &[usize]) -> String {
    let mut out = String::new();
    out.push_str(&file.raw_header);
    if !file.raw_header.ends_with('\n') {
        out.push('\n');
    }
    for h in &file.hunks {
        if hunk_indexes.is_empty() || hunk_indexes.contains(&h.index) {
            out.push_str(&h.raw);
        }
    }
    out
}

/// Everything the agent changed in its worktree, including untracked files.
pub async fn collect(exec: &dyn Executor, worktree: &str, exclude: &[String]) -> Result<Vec<FileDiff>> {
    // `add -N` makes untracked files visible to `git diff` as additions.
    let _ = git(exec, Some(worktree), &["add", "-N", "--", "."]).await;
    let mut args: Vec<&str> = vec![
        "--no-pager",
        "diff",
        "HEAD",
        "--no-color",
        "--no-ext-diff",
        "-M",
        "--",
        ".",
    ];
    let excludes: Vec<String> = exclude
        .iter()
        .filter(|e| !e.trim().is_empty())
        .map(|e| format!(":(exclude){}", e.trim_end_matches('/')))
        .collect();
    for e in &excludes {
        args.push(e);
    }
    let out = git_ok(exec, Some(worktree), &args).await?;
    Ok(parse_unified(&out))
}

pub async fn file_original(exec: &dyn Executor, worktree: &str, path: &str) -> Result<String> {
    let spec = format!("HEAD:{path}");
    let out = git(exec, Some(worktree), &["--no-pager", "show", &spec]).await?;
    Ok(if out.ok() { out.stdout } else { String::new() })
}

pub async fn file_current(exec: &dyn Executor, worktree: &str, path: &str) -> Result<String> {
    let full = format!("{}/{}", worktree.trim_end_matches('/'), path);
    Ok(exec.read_file(&full).await.unwrap_or_default())
}

/// Apply a patch. `reverse` undoes it (used to reject a hunk in the worktree).
pub async fn apply_patch(
    exec: &dyn Executor,
    cwd: &str,
    patch: &str,
    reverse: bool,
    three_way: bool,
) -> Result<()> {
    let tmp = format!("{}/.backtick-patch-{}.diff", cwd.trim_end_matches('/'), uuid::Uuid::new_v4());
    write_file(exec, &tmp, patch).await?;
    let mut args: Vec<&str> = vec!["apply"];
    if reverse {
        args.push("-R");
    }
    if three_way {
        args.push("--3way");
    }
    args.push(&tmp);
    let res = git(exec, Some(cwd), &args).await;
    let _ = exec
        .exec("rm", &["-f".into(), tmp.clone()], None)
        .await;
    let out = res?;
    if !out.ok() {
        return Err(crate::error::Error::Command {
            code: out.code,
            stderr: format!("git apply: {}", out.stderr.trim()),
        });
    }
    Ok(())
}

async fn write_file(exec: &dyn Executor, path: &str, content: &str) -> Result<()> {
    // Heredoc keeps this identical for local and ssh executors.
    let script = format!(
        "cat > {} <<'BACKTICK_PATCH_EOF'\n{}\nBACKTICK_PATCH_EOF",
        shell_escape::escape(path.into()),
        content
    );
    exec.exec("sh", &["-lc".into(), script], None)
        .await?
        .require("write patch file")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "diff --git a/src/main.rs b/src/main.rs\nindex 83db48f..bf269f4 100644\n--- a/src/main.rs\n+++ b/src/main.rs\n@@ -1,3 +1,4 @@\n fn main() {\n-    println!(\"old\");\n+    println!(\"new\");\n+    println!(\"extra\");\n }\n@@ -10,2 +11,2 @@ fn other() {\n-    let x = 1;\n+    let x = 2;\n     done();\ndiff --git a/hi.txt b/hi.txt\nnew file mode 100644\nindex 0000000..45b983b\n--- /dev/null\n+++ b/hi.txt\n@@ -0,0 +1 @@\n+hi\n";

    #[test]
    fn parses_files_hunks_and_counts() {
        let files = parse_unified(SAMPLE);
        assert_eq!(files.len(), 2);
        let main = &files[0];
        assert_eq!(main.path, "src/main.rs");
        assert_eq!(main.status, "modified");
        assert_eq!(main.hunks.len(), 2);
        assert_eq!(main.additions, 3);
        assert_eq!(main.deletions, 2);
        assert_eq!(main.hunks[0].old_start, 1);
        assert_eq!(main.hunks[0].new_lines, 4);

        let hi = &files[1];
        assert_eq!(hi.path, "hi.txt");
        assert_eq!(hi.status, "added");
        assert_eq!(hi.additions, 1);
    }

    #[test]
    fn partial_patch_contains_only_selected_hunk() {
        let files = parse_unified(SAMPLE);
        let patch = build_patch(&files[0], &[1]);
        assert!(patch.starts_with("diff --git a/src/main.rs b/src/main.rs\n"));
        assert!(patch.contains("index 83db48f..bf269f4"), "3-way needs the index line");
        assert!(patch.contains("let x = 2"));
        assert!(!patch.contains("println!(\"new\")"), "hunk 0 must be excluded");
    }

    #[test]
    fn empty_selection_means_whole_file() {
        let files = parse_unified(SAMPLE);
        let patch = build_patch(&files[0], &[]);
        assert!(patch.contains("println!(\"new\")"));
        assert!(patch.contains("let x = 2"));
    }

    #[test]
    fn handles_empty_and_garbage_input() {
        assert!(parse_unified("").is_empty());
        assert!(parse_unified("not a diff at all\njust text").is_empty());
    }
}
