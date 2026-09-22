pub mod scheduler;

use crate::error::{Error, Result};
use crate::models::*;
use crate::paths;
use crate::state::AppState;
use crate::store;
use serde::Serialize;
use std::sync::Arc;
use tauri::{AppHandle, Emitter};

/// Sent to the frontend, which owns provider-specific launch details.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FirePayload {
    pub run_id: String,
    pub automation_id: String,
    pub automation_name: String,
    pub session_id: String,
    pub provider_id: String,
    pub prompt: String,
    pub cwd: String,
    pub permission_policy: String,
    /// launch = fresh process, resume = relaunch a provider session,
    /// continue = write into the still-running process.
    pub mode: String,
    pub resume_id: Option<String>,
}

/// Create the run and its workspace, then hand off to the frontend to launch.
/// Mirrors superset semantics: a run counts as `created` once its workspace
/// exists; whether the agent's work succeeds is the session's business.
pub async fn fire(app: &AppHandle, state: &Arc<AppState>, automation_id: &str, trigger: &str) -> Result<String> {
    let a = store::automation_get(&state.db, automation_id)?;
    let run_id = new_id();
    store::run_insert(
        &state.db,
        &AutomationRun {
            id: run_id.clone(),
            automation_id: a.id.clone(),
            fired_at: timestamp(),
            trigger: trigger.to_string(),
            status: "creating".into(),
            session_id: None,
            error: None,
        },
    )?;

    match build_run(state, &a, &run_id).await {
        Ok(payload) => {
            store::run_update(&state.db, &run_id, "created", Some(&payload.session_id), None)?;
            app.emit("automation://fire", &payload)
                .map_err(|e| Error::msg(format!("could not reach the app window: {e}")))?;
            let _ = app.emit("sessions://changed", ());
            Ok(run_id)
        }
        Err(e) => {
            store::run_update(&state.db, &run_id, "failed", None, Some(&e.to_string()))?;
            let _ = app.emit("automation://failed", (run_id.clone(), e.to_string()));
            Err(e)
        }
    }
}

async fn build_run(state: &Arc<AppState>, a: &Automation, run_id: &str) -> Result<FirePayload> {
    let project = match &a.project_id {
        Some(pid) => Some(store::project_get(&state.db, pid)?),
        None => None,
    };

    let pinned = a
        .pinned_session_id
        .as_ref()
        .filter(|_| a.workspace_mode == "pinned")
        .map(|sid| store::session_get(&state.db, sid))
        .transpose()?;

    // Continue the automation's own previous session when asked and possible;
    // anything unavailable falls through to a normal launch rather than failing.
    if a.continue_agent_session {
        if let Some(prev) = store::last_run(&state.db, &a.id)?
            .and_then(|r| r.session_id)
            .and_then(|sid| store::session_get(&state.db, &sid).ok())
        {
            if prev.provider_id == a.provider_id {
                if state.sessions.is_alive(&prev.id) {
                    return Ok(FirePayload {
                        run_id: run_id.to_string(),
                        automation_id: a.id.clone(),
                        automation_name: a.name.clone(),
                        session_id: prev.id.clone(),
                        provider_id: a.provider_id.clone(),
                        prompt: a.prompt.clone(),
                        cwd: prev.worktree_path.clone().unwrap_or_default(),
                        permission_policy: a.permission_policy.clone(),
                        mode: "continue".into(),
                        resume_id: prev.provider_session_id.clone(),
                    });
                }
                if let Some(resume_id) = prev.provider_session_id.clone() {
                    return Ok(FirePayload {
                        run_id: run_id.to_string(),
                        automation_id: a.id.clone(),
                        automation_name: a.name.clone(),
                        session_id: prev.id.clone(),
                        provider_id: a.provider_id.clone(),
                        prompt: a.prompt.clone(),
                        cwd: prev.worktree_path.clone().unwrap_or_default(),
                        permission_policy: a.permission_policy.clone(),
                        mode: "resume".into(),
                        resume_id: Some(resume_id),
                    });
                }
            }
        }
    }

    // Otherwise: a new session. Pinned mode reuses the pinned worktree,
    // new_worktree mode provisions a fresh one, no-project uses a scratch dir.
    let session_id = new_id();
    let name = format!("{} · {}", a.name, chrono::Local::now().format("%b %d %H:%M"));

    let (cwd, branch) = match (&project, &pinned) {
        (_, Some(p)) => (
            p.worktree_path
                .clone()
                .ok_or_else(|| Error::msg("the pinned session has no worktree"))?,
            p.branch.clone(),
        ),
        (None, None) => (
            paths::scratch_dir(run_id)?.to_string_lossy().to_string(),
            None,
        ),
        (Some(proj), None) => {
            let exec = state.executor_for(Some(proj))?;
            let home = exec.home().await?;
            let repo_name = std::path::Path::new(&proj.root_path)
                .file_name()
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_else(|| "repo".into());
            let hash = crate::git::worktree::short_hash(&proj.root_path);
            let prefix = state.branch_prefix(Some(proj));
            let stamp = chrono::Local::now().format("%Y%m%d-%H%M").to_string();
            let slug = format!("auto-{}-{}", crate::git::worktree::slugify(&a.name), stamp);
            let branch = format!("{prefix}{slug}");
            let path = crate::git::worktree::render_template(
                &state.worktree_template(Some(proj)),
                &home,
                &repo_name,
                &hash,
                &slug,
                &branch,
                &prefix,
            );
            crate::git::worktree::add(exec.as_ref(), &proj.root_path, &path, &branch, &proj.default_base_ref).await?;
            (path, Some(branch))
        }
    };

    let session = Session {
        id: session_id.clone(),
        project_id: a.project_id.clone(),
        name,
        provider_id: a.provider_id.clone(),
        provider_session_id: None,
        worktree_path: Some(cwd.clone()),
        branch,
        base_ref: project.as_ref().map(|p| p.default_base_ref.clone()),
        status: "created".into(),
        status_detail: None,
        permission_policy: a.permission_policy.clone(),
        prompt: Some(a.prompt.clone()),
        automation_id: Some(a.id.clone()),
        created_at: timestamp(),
        last_event_at: None,
        archived_at: None,
        alive: false,
    };
    store::session_insert(&state.db, &session)?;

    Ok(FirePayload {
        run_id: run_id.to_string(),
        automation_id: a.id.clone(),
        automation_name: a.name.clone(),
        session_id,
        provider_id: a.provider_id.clone(),
        prompt: a.prompt.clone(),
        cwd,
        permission_policy: a.permission_policy.clone(),
        mode: "launch".into(),
        resume_id: None,
    })
}

/// Background loop: sleeps until the earliest next fire, wakes early when an
/// automation changes. Runs as long as the app process does, window or not.
pub fn start_scheduler(app: AppHandle, state: Arc<AppState>) {
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<()>();
    *state.scheduler_wake.lock() = Some(tx);

    tauri::async_runtime::spawn(async move {
        loop {
            let wait = match tick(&app, &state).await {
                Ok(d) => d,
                Err(e) => {
                    tracing::warn!("scheduler tick failed: {e}");
                    std::time::Duration::from_secs(30)
                }
            };
            tokio::select! {
                _ = tokio::time::sleep(wait) => {}
                _ = rx.recv() => {}
            }
        }
    });
}

/// Fire everything due, then report how long to sleep.
async fn tick(app: &AppHandle, state: &Arc<AppState>) -> Result<std::time::Duration> {
    let now = chrono::Utc::now();
    let automations = store::automations_list(&state.db)?;
    let mut earliest: Option<chrono::DateTime<chrono::Utc>> = None;

    for a in automations.iter().filter(|a| a.enabled) {
        let next = match a.next_run_at.as_ref().and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok()) {
            Some(d) => d.with_timezone(&chrono::Utc),
            None => {
                let computed = scheduler::next_occurrence(&a.rrule, &a.timezone, &a.dtstart, now)?;
                store::automation_set_next_run(&state.db, &a.id, computed.map(|d| d.to_rfc3339()).as_deref())?;
                match computed {
                    Some(d) => d,
                    None => continue,
                }
            }
        };

        if next <= now {
            // A missed fire (app was closed) only runs when catch-up is on.
            let overdue_by = now.signed_duration_since(next);
            let missed = overdue_by > chrono::Duration::minutes(5);
            if !missed || a.catch_up {
                if let Err(e) = fire(app, state, &a.id, "schedule").await {
                    tracing::warn!("automation {} failed to fire: {e}", a.name);
                }
            }
            let after = scheduler::next_occurrence(&a.rrule, &a.timezone, &a.dtstart, now)?;
            store::automation_set_next_run(&state.db, &a.id, after.map(|d| d.to_rfc3339()).as_deref())?;
            if let Some(d) = after {
                earliest = Some(earliest.map_or(d, |e| e.min(d)));
            }
        } else {
            earliest = Some(earliest.map_or(next, |e| e.min(next)));
        }
    }

    let _ = app.emit("automations://changed", ());
    Ok(match earliest {
        Some(next) => {
            let secs = (next - chrono::Utc::now()).num_seconds().clamp(1, 300);
            std::time::Duration::from_secs(secs as u64)
        }
        None => std::time::Duration::from_secs(300),
    })
}
