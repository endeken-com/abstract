use crate::error::{Error, Result};
use std::path::PathBuf;

/// Root of all Backtick state on this machine: `~/.backtick` unless overridden.
pub fn data_root() -> Result<PathBuf> {
    if let Ok(custom) = std::env::var("BACKTICK_DATA_DIR") {
        return Ok(PathBuf::from(custom));
    }
    let home = dirs::home_dir().ok_or_else(|| Error::msg("cannot resolve home directory"))?;
    Ok(home.join(".backtick"))
}

pub fn ensure_dir(p: &PathBuf) -> Result<()> {
    std::fs::create_dir_all(p)?;
    Ok(())
}

pub fn db_file() -> Result<PathBuf> {
    let root = data_root()?;
    ensure_dir(&root)?;
    Ok(root.join("backtick.db"))
}

pub fn session_log_dir() -> Result<PathBuf> {
    let d = data_root()?.join("sessions");
    ensure_dir(&d)?;
    Ok(d)
}

pub fn session_log_file(session_id: &str) -> Result<PathBuf> {
    Ok(session_log_dir()?.join(format!("{session_id}.jsonl")))
}

pub fn scratch_dir(run_id: &str) -> Result<PathBuf> {
    let d = data_root()?.join("scratch").join(run_id);
    ensure_dir(&d)?;
    Ok(d)
}

pub fn default_worktree_root() -> Result<PathBuf> {
    Ok(data_root()?.join("worktrees"))
}
