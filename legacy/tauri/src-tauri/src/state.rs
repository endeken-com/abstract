use crate::db::Db;
use crate::error::{Error, Result};
use crate::executor::{local::LocalExecutor, Executor};
use crate::models::Project;
use crate::sessions::manager::SessionManager;
use crate::store;
use parking_lot::Mutex;
use std::sync::Arc;

pub const DEFAULT_WORKTREE_TEMPLATE: &str = "{home}/.abstract/worktrees/{repo}-{hash}/{slug}";
pub const DEFAULT_BRANCH_PREFIX: &str = "abstract/";

pub struct AppState {
    pub db: Db,
    pub sessions: Arc<SessionManager>,
    pub local: Arc<dyn Executor>,
    pub scheduler_wake: Mutex<Option<tokio::sync::mpsc::UnboundedSender<()>>>,
}

impl AppState {
    pub fn new(db: Db) -> Self {
        let sessions = Arc::new(SessionManager::new(db.clone()));
        AppState {
            db,
            sessions,
            local: Arc::new(LocalExecutor::new()),
            scheduler_wake: Mutex::new(None),
        }
    }

    /// Executor for a project. SSH projects are rejected until the SSH
    /// executor lands; the trait boundary is already in place for it.
    pub fn executor_for(&self, project: Option<&Project>) -> Result<Arc<dyn Executor>> {
        match project {
            None => Ok(self.local.clone()),
            Some(p) if p.executor == "local" => Ok(self.local.clone()),
            Some(p) => Err(Error::msg(format!(
                "project `{}` targets {} over SSH; remote execution is not available yet",
                p.name,
                p.ssh_host.clone().unwrap_or_else(|| "a remote host".into())
            ))),
        }
    }

    pub fn worktree_template(&self, project: Option<&Project>) -> String {
        project
            .and_then(|p| p.worktree_template.clone())
            .filter(|s| !s.trim().is_empty())
            .or_else(|| store::setting_str(&self.db, "worktree_template"))
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| DEFAULT_WORKTREE_TEMPLATE.to_string())
    }

    pub fn branch_prefix(&self, project: Option<&Project>) -> String {
        project
            .and_then(|p| p.branch_prefix.clone())
            .filter(|s| !s.trim().is_empty())
            .or_else(|| store::setting_str(&self.db, "branch_prefix"))
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| DEFAULT_BRANCH_PREFIX.to_string())
    }

    pub fn wake_scheduler(&self) {
        if let Some(tx) = self.scheduler_wake.lock().as_ref() {
            let _ = tx.send(());
        }
    }
}
