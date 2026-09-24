use super::{git, git_ok};
use crate::error::{Error, Result};
use crate::executor::Executor;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorktreeInfo {
    pub path: String,
    pub head: Option<String>,
    pub branch: Option<String>,
    pub bare: bool,
    pub detached: bool,
    pub locked: bool,
    /// Set by the caller: which session owns this worktree, if any.
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub session_name: Option<String>,
    #[serde(default)]
    pub orphan: bool,
}

/// `git rev-parse --show-toplevel` — the real repo root for a directory.
pub async fn repo_root(exec: &dyn Executor, dir: &str) -> Result<String> {
    let out = git(exec, Some(dir), &["rev-parse", "--show-toplevel"]).await?;
    if !out.ok() {
        return Err(Error::msg(format!("{dir} is not inside a git repository")));
    }
    Ok(out.stdout.trim().to_string())
}

/// Inner repositories / submodules under `root`, which a single worktree cannot carry.
pub async fn nested_repos(exec: &dyn Executor, root: &str) -> Result<Vec<String>> {
    let script = format!(
        "find {} -mindepth 2 -maxdepth 5 -name .git -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null | head -50",
        shell_escape::escape(root.into())
    );
    let out = exec.exec("sh", &["-lc".into(), script], None).await?;
    let root_trim = root.trim_end_matches('/');
    Ok(out
        .stdout
        .lines()
        .filter_map(|l| {
            let p = l.trim();
            if p.is_empty() {
                return None;
            }
            let dir = p.strip_suffix("/.git").unwrap_or(p);
            let rel = dir.strip_prefix(root_trim).unwrap_or(dir);
            Some(rel.trim_start_matches('/').to_string())
        })
        .filter(|s| !s.is_empty())
        .collect())
}

pub async fn list(exec: &dyn Executor, root: &str) -> Result<Vec<WorktreeInfo>> {
    let out = git_ok(exec, Some(root), &["worktree", "list", "--porcelain"]).await?;
    let mut result = Vec::new();
    let mut cur: Option<WorktreeInfo> = None;
    for line in out.lines() {
        if line.is_empty() {
            if let Some(w) = cur.take() {
                result.push(w);
            }
            continue;
        }
        let (key, val) = match line.split_once(' ') {
            Some((k, v)) => (k, v),
            None => (line, ""),
        };
        match key {
            "worktree" => {
                if let Some(w) = cur.take() {
                    result.push(w);
                }
                cur = Some(WorktreeInfo {
                    path: val.to_string(),
                    head: None,
                    branch: None,
                    bare: false,
                    detached: false,
                    locked: false,
                    session_id: None,
                    session_name: None,
                    orphan: false,
                });
            }
            "HEAD" => {
                if let Some(w) = cur.as_mut() {
                    w.head = Some(val.to_string());
                }
            }
            "branch" => {
                if let Some(w) = cur.as_mut() {
                    w.branch = Some(val.trim_start_matches("refs/heads/").to_string());
                }
            }
            "bare" => {
                if let Some(w) = cur.as_mut() {
                    w.bare = true;
                }
            }
            "detached" => {
                if let Some(w) = cur.as_mut() {
                    w.detached = true;
                }
            }
            "locked" => {
                if let Some(w) = cur.as_mut() {
                    w.locked = true;
                }
            }
            _ => {}
        }
    }
    if let Some(w) = cur.take() {
        result.push(w);
    }
    Ok(result)
}

pub async fn add(
    exec: &dyn Executor,
    root: &str,
    path: &str,
    branch: &str,
    base_ref: &str,
) -> Result<()> {
    if let Some(parent) = std::path::Path::new(path).parent() {
        exec.mkdir_p(&parent.to_string_lossy()).await?;
    }
    let base = if base_ref.trim().is_empty() { "HEAD" } else { base_ref };
    let out = git(
        exec,
        Some(root),
        &["worktree", "add", "-b", branch, path, base],
    )
    .await?;
    if !out.ok() {
        // Branch already exists (e.g. a restarted automation): attach instead.
        let retry = git(exec, Some(root), &["worktree", "add", path, branch]).await?;
        if !retry.ok() {
            return Err(Error::Command {
                code: out.code,
                stderr: format!("git worktree add: {}", out.stderr.trim()),
            });
        }
    }
    // Submodules, when present, otherwise the worktree is missing their content.
    let has_modules = exec
        .exists(&format!("{}/.gitmodules", root.trim_end_matches('/')))
        .await
        .unwrap_or(false);
    if has_modules {
        let _ = git(exec, Some(path), &["submodule", "update", "--init", "--recursive"]).await;
    }
    Ok(())
}

pub async fn remove(
    exec: &dyn Executor,
    root: &str,
    path: &str,
    delete_branch: Option<&str>,
) -> Result<()> {
    let out = git(exec, Some(root), &["worktree", "remove", "--force", path]).await?;
    if !out.ok() {
        // Directory may already be gone; prune and fall back to rm -rf.
        exec.remove_dir_all(path).await?;
        let _ = git(exec, Some(root), &["worktree", "prune"]).await;
    }
    if let Some(branch) = delete_branch {
        let _ = git(exec, Some(root), &["branch", "-D", branch]).await;
    }
    Ok(())
}

pub async fn prune(exec: &dyn Executor, root: &str) -> Result<()> {
    git_ok(exec, Some(root), &["worktree", "prune"]).await?;
    Ok(())
}

pub fn slugify(input: &str) -> String {
    let mut out = String::new();
    let mut last_dash = true;
    for ch in input.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
            last_dash = false;
        } else if !last_dash && out.len() < 40 {
            out.push('-');
            last_dash = true;
        }
        if out.len() >= 40 {
            break;
        }
    }
    let s = out.trim_matches('-').to_string();
    if s.is_empty() {
        "session".into()
    } else {
        s
    }
}

pub fn short_hash(input: &str) -> String {
    let digest = Sha256::digest(input.as_bytes());
    digest.iter().take(4).map(|b| format!("{b:02x}")).collect()
}

/// Expand `{home} {repo} {hash} {slug} {branch} {prefix}` in a path/branch template.
pub fn render_template(
    template: &str,
    home: &str,
    repo: &str,
    hash: &str,
    slug: &str,
    branch: &str,
    prefix: &str,
) -> String {
    template
        .replace("{home}", home)
        .replace("{repo}", repo)
        .replace("{hash}", hash)
        .replace("{slug}", slug)
        .replace("{branch}", branch)
        .replace("{prefix}", prefix)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slug_is_filesystem_safe() {
        assert_eq!(slugify("Add OAuth login!"), "add-oauth-login");
        assert_eq!(slugify("   "), "session");
        assert!(slugify(&"x".repeat(200)).len() <= 40);
    }

    #[test]
    fn template_expands_every_token() {
        let out = render_template(
            "{home}/.abstract/worktrees/{repo}-{hash}/{slug}",
            "/Users/w",
            "api",
            "ab12cd34",
            "fix-login",
            "abstract/fix-login",
            "abstract/",
        );
        assert_eq!(out, "/Users/w/.abstract/worktrees/api-ab12cd34/fix-login");
    }

    #[test]
    fn hash_is_stable_and_short() {
        assert_eq!(short_hash("/repo/a").len(), 8);
        assert_eq!(short_hash("/repo/a"), short_hash("/repo/a"));
        assert_ne!(short_hash("/repo/a"), short_hash("/repo/b"));
    }
}
