pub mod diff;
pub mod worktree;

use crate::error::Result;
use crate::executor::{ExecOutput, Executor};

pub async fn git(
    exec: &dyn Executor,
    cwd: Option<&str>,
    args: &[&str],
) -> Result<ExecOutput> {
    let args: Vec<String> = args.iter().map(|s| s.to_string()).collect();
    exec.exec("git", &args, cwd).await
}

pub async fn git_ok(exec: &dyn Executor, cwd: Option<&str>, args: &[&str]) -> Result<String> {
    let out = git(exec, cwd, args).await?;
    let label = format!("git {}", args.join(" "));
    Ok(out.require(&label)?.stdout)
}
