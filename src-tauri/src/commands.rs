use crate::automations::scheduler;
use crate::error::{Error, Result};
use crate::executor::{Executor, LaunchSpec};
use crate::git::{diff, worktree};
use crate::models::*;
use crate::paths;
use crate::sessions::manager::SessionEvent;
use crate::state::AppState;
use crate::store;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tauri::ipc::Channel;
use tauri::State;

type S<'a> = State<'a, Arc<AppState>>;

// ---------------- settings ----------------

#[tauri::command]
pub fn settings_get_all(state: S) -> Result<serde_json::Value> {
    let mut map = store::settings_all(&state.db)?;
    map.entry("worktree_template".to_string())
        .or_insert_with(|| crate::state::DEFAULT_WORKTREE_TEMPLATE.into());
    map.entry("branch_prefix".to_string())
        .or_insert_with(|| crate::state::DEFAULT_BRANCH_PREFIX.into());
    Ok(serde_json::Value::Object(map))
}

#[tauri::command]
pub fn settings_set(state: S, key: String, value: serde_json::Value) -> Result<()> {
    store::settings_set(&state.db, &key, &value)
}

// ---------------- projects ----------------

#[derive(Debug, Deserialize)]
pub struct ProjectProbe {
    pub path: String,
}

#[derive(Debug, Serialize)]
pub struct ProbeResult {
    pub root_path: String,
    pub name: String,
    pub is_root: bool,
    pub nested_repos: Vec<String>,
    pub default_branch: String,
}

#[tauri::command]
pub async fn project_probe(state: S<'_>, args: ProjectProbe) -> Result<ProbeResult> {
    let exec = state.local.clone();
    let root = worktree::repo_root(exec.as_ref(), &args.path).await?;
    let nested = worktree::nested_repos(exec.as_ref(), &root).await.unwrap_or_default();
    let head = crate::git::git(exec.as_ref(), Some(&root), &["symbolic-ref", "--short", "HEAD"])
        .await?;
    let default_branch = if head.ok() {
        head.stdout.trim().to_string()
    } else {
        "HEAD".to_string()
    };
    let name = std::path::Path::new(&root)
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| root.clone());
    Ok(ProbeResult {
        is_root: std::path::Path::new(&args.path) == std::path::Path::new(&root),
        root_path: root,
        name,
        nested_repos: nested,
        default_branch,
    })
}

#[derive(Debug, Deserialize)]
pub struct NewProject {
    pub name: String,
    pub root_path: String,
    #[serde(default)]
    pub default_base_ref: Option<String>,
    #[serde(default)]
    pub default_provider_id: Option<String>,
    #[serde(default)]
    pub default_permission_policy: Option<String>,
    #[serde(default)]
    pub nested_repos: Vec<String>,
}

#[tauri::command]
pub fn project_add(state: S, args: NewProject) -> Result<Project> {
    let existing = store::projects_list(&state.db)?;
    if let Some(dup) = existing.iter().find(|p| p.root_path == args.root_path) {
        return Err(Error::msg(format!(
            "`{}` is already a project ({})",
            args.root_path, dup.name
        )));
    }
    let p = Project {
        id: new_id(),
        name: args.name,
        executor: "local".into(),
        root_path: args.root_path,
        ssh_host: None,
        ssh_extra_args: None,
        default_base_ref: args.default_base_ref.unwrap_or_else(|| "HEAD".into()),
        default_provider_id: args.default_provider_id.unwrap_or_else(|| "claude".into()),
        default_permission_policy: args.default_permission_policy.unwrap_or_else(|| "ask".into()),
        nested_repos: args.nested_repos,
        worktree_template: None,
        branch_prefix: None,
        sort_order: existing.len() as i64,
        created_at: timestamp(),
        archived_at: None,
    };
    store::project_insert(&state.db, &p)?;
    Ok(p)
}

#[tauri::command]
pub fn projects_list(state: S) -> Result<Vec<Project>> {
    store::projects_list(&state.db)
}

#[tauri::command]
pub fn project_update(state: S, project: Project) -> Result<()> {
    store::project_update(&state.db, &project)
}

#[tauri::command]
pub fn project_delete(state: S, id: String) -> Result<()> {
    store::project_delete(&state.db, &id)
}

// ---------------- providers ----------------

#[derive(Debug, Serialize)]
pub struct ProviderStatus {
    pub id: String,
    pub available: bool,
    pub path: Option<String>,
    pub version: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct DetectArgs {
    pub providers: Vec<DetectProvider>,
    #[serde(default)]
    pub project_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct DetectProvider {
    pub id: String,
    pub binary: String,
    #[serde(default)]
    pub detect_args: Vec<String>,
}

#[tauri::command]
pub async fn providers_detect(state: S<'_>, args: DetectArgs) -> Result<Vec<ProviderStatus>> {
    let project = match &args.project_id {
        Some(id) => Some(store::project_get(&state.db, id)?),
        None => None,
    };
    let exec = state.executor_for(project.as_ref())?;
    let mut out = Vec::new();
    for p in args.providers {
        let path = exec.which(&p.binary).await.unwrap_or(None);
        let version = match &path {
            Some(bin) => {
                let res = exec.exec(bin, &p.detect_args, None).await.ok();
                res.filter(|r| r.ok())
                    .map(|r| r.stdout.trim().lines().next().unwrap_or("").to_string())
            }
            None => None,
        };
        out.push(ProviderStatus {
            id: p.id,
            available: path.is_some(),
            path,
            version,
        });
    }
    Ok(out)
}

// ---------------- sessions ----------------

#[derive(Debug, Deserialize)]
pub struct NewSession {
    pub project_id: Option<String>,
    pub provider_id: String,
    pub prompt: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub base_ref: Option<String>,
    #[serde(default)]
    pub permission_policy: Option<String>,
    #[serde(default)]
    pub automation_id: Option<String>,
}

/// Creates the DB row and provisions the worktree. The caller then builds a
/// LaunchSpec (provider-specific, frontend side) and calls `session_launch`.
#[tauri::command]
pub async fn session_create(state: S<'_>, args: NewSession) -> Result<Session> {
    let project = match &args.project_id {
        Some(id) => Some(store::project_get(&state.db, id)?),
        None => None,
    };
    let name = args
        .name
        .filter(|n| !n.trim().is_empty())
        .unwrap_or_else(|| derive_name(&args.prompt));
    let id = new_id();

    let mut session = Session {
        id: id.clone(),
        project_id: args.project_id.clone(),
        name: name.clone(),
        provider_id: args.provider_id,
        provider_session_id: None,
        worktree_path: None,
        branch: None,
        base_ref: args.base_ref.clone(),
        status: "provisioning".into(),
        status_detail: None,
        permission_policy: args
            .permission_policy
            .or_else(|| project.as_ref().map(|p| p.default_permission_policy.clone()))
            .unwrap_or_else(|| "ask".into()),
        prompt: Some(args.prompt.clone()),
        automation_id: args.automation_id.clone(),
        created_at: timestamp(),
        last_event_at: None,
        archived_at: None,
        alive: false,
    };

    match &project {
        None => {
            // "No project" session: a scratch directory, no worktree, no diff.
            let dir = paths::scratch_dir(&id)?;
            session.worktree_path = Some(dir.to_string_lossy().to_string());
        }
        Some(p) => {
            let exec = state.executor_for(Some(p))?;
            let (path, branch) = provision_worktree(&state, exec.as_ref(), p, &name, args.base_ref.as_deref()).await?;
            session.worktree_path = Some(path);
            session.branch = Some(branch);
        }
    }

    session.status = "created".into();
    store::session_insert(&state.db, &session)?;
    Ok(session)
}

async fn provision_worktree(
    state: &Arc<AppState>,
    exec: &dyn Executor,
    project: &Project,
    session_name: &str,
    base_ref: Option<&str>,
) -> Result<(String, String)> {
    let home = exec.home().await?;
    let repo_name = std::path::Path::new(&project.root_path)
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "repo".into());
    let hash = worktree::short_hash(&project.root_path);
    let base_slug = worktree::slugify(session_name);
    let prefix = state.branch_prefix(Some(project));
    let template = state.worktree_template(Some(project));

    // Keep trying suffixed slugs until both the path and the branch are free.
    for attempt in 0..50 {
        let slug = if attempt == 0 {
            base_slug.clone()
        } else {
            format!("{base_slug}-{attempt}")
        };
        let branch = format!("{prefix}{slug}");
        let path = worktree::render_template(&template, &home, &repo_name, &hash, &slug, &branch, &prefix);
        if exec.exists(&path).await.unwrap_or(false) {
            continue;
        }
        let branch_exists = crate::git::git(exec, Some(&project.root_path), &["rev-parse", "--verify", &branch])
            .await
            .map(|o| o.ok())
            .unwrap_or(false);
        if branch_exists {
            continue;
        }
        let base = base_ref
            .filter(|b| !b.trim().is_empty())
            .unwrap_or(&project.default_base_ref);
        worktree::add(exec, &project.root_path, &path, &branch, base).await?;
        return Ok((path, branch));
    }
    Err(Error::msg("could not find a free worktree path or branch name"))
}

fn derive_name(prompt: &str) -> String {
    let first = prompt.lines().find(|l| !l.trim().is_empty()).unwrap_or("session");
    let trimmed: String = first.trim().chars().take(60).collect();
    if trimmed.is_empty() {
        "session".into()
    } else {
        trimmed
    }
}

#[tauri::command]
pub fn sessions_list(state: S) -> Result<Vec<Session>> {
    let mut list = store::sessions_list(&state.db)?;
    for s in list.iter_mut() {
        s.alive = state.sessions.is_alive(&s.id);
    }
    Ok(list)
}

#[tauri::command]
pub fn session_get(state: S, id: String) -> Result<Session> {
    let mut s = store::session_get(&state.db, &id)?;
    s.alive = state.sessions.is_alive(&s.id);
    Ok(s)
}

#[tauri::command]
pub async fn session_launch(state: S<'_>, id: String, spec: LaunchSpec) -> Result<()> {
    let session = store::session_get(&state.db, &id)?;
    let project = match &session.project_id {
        Some(pid) => Some(store::project_get(&state.db, pid)?),
        None => None,
    };
    let exec = state.executor_for(project.as_ref())?;
    state.sessions.launch(exec, &id, spec).await
}

#[tauri::command]
pub fn session_write(state: S, id: String, data: String) -> Result<()> {
    state.sessions.write_stdin(&id, &data)?;
    state.sessions.touch(&id);
    Ok(())
}

#[tauri::command]
pub fn session_stop(state: S, id: String) -> Result<()> {
    state.sessions.stop(&id)
}

#[tauri::command]
pub fn session_set_status(state: S, id: String, status: String, detail: Option<String>) -> Result<()> {
    state.sessions.set_status(&id, &status, detail.as_deref())
}

#[tauri::command]
pub fn session_set_provider_session_id(state: S, id: String, provider_session_id: String) -> Result<()> {
    store::session_set_provider_session_id(&state.db, &id, &provider_session_id)
}

#[tauri::command]
pub fn session_rename(state: S, id: String, name: String) -> Result<()> {
    store::session_rename(&state.db, &id, &name)
}

#[tauri::command]
pub fn session_archive(state: S, id: String, archived: bool) -> Result<()> {
    store::session_set_archived(&state.db, &id, archived)
}

#[tauri::command]
pub fn session_replay(state: S, id: String, from_seq: Option<u64>) -> Result<Vec<SessionEvent>> {
    state.sessions.replay(&id, from_seq.unwrap_or(0))
}

#[tauri::command]
pub fn session_subscribe(state: S, channel: Channel<SessionEvent>) -> Result<()> {
    let mut rx = state.sessions.subscribe();
    tauri::async_runtime::spawn(async move {
        while let Ok(ev) = rx.recv().await {
            if channel.send(ev).is_err() {
                break;
            }
        }
    });
    Ok(())
}

#[derive(Debug, Deserialize)]
pub struct DeleteSession {
    pub id: String,
    #[serde(default)]
    pub remove_worktree: bool,
    #[serde(default)]
    pub delete_branch: bool,
}

#[tauri::command]
pub async fn session_delete(state: S<'_>, args: DeleteSession) -> Result<()> {
    let session = store::session_get(&state.db, &args.id)?;
    if state.sessions.is_alive(&args.id) {
        let _ = state.sessions.stop(&args.id);
    }
    if args.remove_worktree {
        if let (Some(pid), Some(path)) = (&session.project_id, &session.worktree_path) {
            let project = store::project_get(&state.db, pid)?;
            let exec = state.executor_for(Some(&project))?;
            let branch = if args.delete_branch { session.branch.as_deref() } else { None };
            worktree::remove(exec.as_ref(), &project.root_path, path, branch).await?;
        }
    }
    state.sessions.forget(&args.id);
    let _ = state.sessions.clear_log(&args.id);
    store::session_delete(&state.db, &args.id)
}

// ---------------- usage ----------------

#[tauri::command]
pub fn usage_record(state: S, record: UsageRecord) -> Result<()> {
    store::usage_insert(&state.db, &record)
}

#[tauri::command]
pub fn usage_summary(state: S, since: Option<String>, project_id: Option<String>) -> Result<Vec<UsageSummary>> {
    store::usage_summary(&state.db, since.as_deref(), project_id.as_deref())
}

#[tauri::command]
pub fn usage_by_day(state: S, since: Option<String>) -> Result<Vec<UsageDay>> {
    store::usage_by_day(&state.db, since.as_deref())
}

// ---------------- worktrees ----------------

#[tauri::command]
pub async fn worktrees_list(state: S<'_>, project_id: String) -> Result<Vec<worktree::WorktreeInfo>> {
    let project = store::project_get(&state.db, &project_id)?;
    let exec = state.executor_for(Some(&project))?;
    let mut list = worktree::list(exec.as_ref(), &project.root_path).await?;
    let sessions = store::sessions_list(&state.db)?;
    let root = std::path::Path::new(&project.root_path);
    for w in list.iter_mut() {
        if std::path::Path::new(&w.path) == root {
            continue;
        }
        match sessions
            .iter()
            .find(|s| s.worktree_path.as_deref() == Some(w.path.as_str()))
        {
            Some(s) => {
                w.session_id = Some(s.id.clone());
                w.session_name = Some(s.name.clone());
            }
            None => w.orphan = true,
        }
    }
    Ok(list)
}

#[derive(Debug, Deserialize)]
pub struct RemoveWorktree {
    pub project_id: String,
    pub path: String,
    #[serde(default)]
    pub delete_branch: Option<String>,
}

#[tauri::command]
pub async fn worktree_remove(state: S<'_>, args: RemoveWorktree) -> Result<()> {
    let project = store::project_get(&state.db, &args.project_id)?;
    let exec = state.executor_for(Some(&project))?;
    worktree::remove(exec.as_ref(), &project.root_path, &args.path, args.delete_branch.as_deref()).await
}

#[tauri::command]
pub async fn worktree_prune(state: S<'_>, project_id: String) -> Result<()> {
    let project = store::project_get(&state.db, &project_id)?;
    let exec = state.executor_for(Some(&project))?;
    worktree::prune(exec.as_ref(), &project.root_path).await
}

// ---------------- diff ----------------

#[derive(Debug, Serialize)]
pub struct SessionDiff {
    pub files: Vec<diff::FileDiff>,
    pub worktree_path: Option<String>,
    pub excluded: Vec<String>,
}

#[tauri::command]
pub async fn diff_collect(state: S<'_>, session_id: String) -> Result<SessionDiff> {
    let session = store::session_get(&state.db, &session_id)?;
    let Some(worktree_path) = session.worktree_path.clone() else {
        return Ok(SessionDiff { files: vec![], worktree_path: None, excluded: vec![] });
    };
    let Some(pid) = session.project_id.clone() else {
        return Ok(SessionDiff { files: vec![], worktree_path: Some(worktree_path), excluded: vec![] });
    };
    let project = store::project_get(&state.db, &pid)?;
    let exec = state.executor_for(Some(&project))?;
    let files = diff::collect(exec.as_ref(), &worktree_path, &project.nested_repos).await?;
    Ok(SessionDiff {
        files,
        worktree_path: Some(worktree_path),
        excluded: project.nested_repos,
    })
}

#[derive(Debug, Serialize)]
pub struct FileContents {
    pub original: String,
    pub modified: String,
}

#[tauri::command]
pub async fn diff_file_contents(state: S<'_>, session_id: String, path: String) -> Result<FileContents> {
    let session = store::session_get(&state.db, &session_id)?;
    let worktree_path = session
        .worktree_path
        .ok_or_else(|| Error::msg("session has no worktree"))?;
    let project = match session.project_id {
        Some(pid) => store::project_get(&state.db, &pid)?,
        None => return Err(Error::msg("session has no project")),
    };
    let exec = state.executor_for(Some(&project))?;
    Ok(FileContents {
        original: diff::file_original(exec.as_ref(), &worktree_path, &path).await?,
        modified: diff::file_current(exec.as_ref(), &worktree_path, &path).await?,
    })
}

#[derive(Debug, Deserialize)]
pub struct DiffAction {
    pub session_id: String,
    /// Empty means every changed file.
    #[serde(default)]
    pub path: Option<String>,
    /// Empty means every hunk of that file.
    #[serde(default)]
    pub hunks: Vec<usize>,
}

/// Apply the selected changes onto the project's main working tree.
#[tauri::command]
pub async fn diff_accept(state: S<'_>, args: DiffAction) -> Result<()> {
    let (project, exec, files, _wt) = load_diff_context(&state, &args.session_id).await?;
    let selected = select_files(&files, args.path.as_deref())?;
    for f in selected {
        let patch = diff::build_patch(f, &args.hunks);
        diff::apply_patch(exec.as_ref(), &project.root_path, &patch, false, true).await?;
    }
    Ok(())
}

/// Undo the selected changes inside the agent's worktree.
#[tauri::command]
pub async fn diff_reject(state: S<'_>, args: DiffAction) -> Result<()> {
    let (_project, exec, files, worktree_path) = load_diff_context(&state, &args.session_id).await?;
    let selected = select_files(&files, args.path.as_deref())?;
    for f in selected {
        if f.status == "added" && args.hunks.is_empty() {
            let full = format!("{}/{}", worktree_path.trim_end_matches('/'), f.path);
            let _ = exec.exec("rm", &["-f".into(), full], None).await;
            let _ = crate::git::git(exec.as_ref(), Some(&worktree_path), &["rm", "-f", "--cached", "--", &f.path]).await;
            continue;
        }
        let patch = diff::build_patch(f, &args.hunks);
        diff::apply_patch(exec.as_ref(), &worktree_path, &patch, true, false).await?;
    }
    Ok(())
}

async fn load_diff_context(
    state: &Arc<AppState>,
    session_id: &str,
) -> Result<(Project, Arc<dyn Executor>, Vec<diff::FileDiff>, String)> {
    let session = store::session_get(&state.db, session_id)?;
    let worktree_path = session
        .worktree_path
        .ok_or_else(|| Error::msg("session has no worktree"))?;
    let pid = session
        .project_id
        .ok_or_else(|| Error::msg("session has no project to merge into"))?;
    let project = store::project_get(&state.db, &pid)?;
    let exec = state.executor_for(Some(&project))?;
    let files = diff::collect(exec.as_ref(), &worktree_path, &project.nested_repos).await?;
    Ok((project, exec, files, worktree_path))
}

fn select_files<'a>(files: &'a [diff::FileDiff], path: Option<&str>) -> Result<Vec<&'a diff::FileDiff>> {
    match path {
        None => Ok(files.iter().collect()),
        Some(p) => files
            .iter()
            .find(|f| f.path == p)
            .map(|f| vec![f])
            .ok_or_else(|| Error::NotFound(format!("changed file {p}"))),
    }
}

// ---------------- automations ----------------

#[derive(Debug, Deserialize)]
pub struct AutomationInput {
    #[serde(default)]
    pub id: Option<String>,
    pub name: String,
    pub prompt: String,
    pub provider_id: String,
    #[serde(default)]
    pub project_id: Option<String>,
    pub rrule: String,
    pub timezone: String,
    #[serde(default)]
    pub dtstart: Option<String>,
    #[serde(default)]
    pub workspace_mode: Option<String>,
    #[serde(default)]
    pub pinned_session_id: Option<String>,
    #[serde(default)]
    pub continue_agent_session: bool,
    #[serde(default)]
    pub permission_policy: Option<String>,
    #[serde(default)]
    pub catch_up: bool,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

fn default_true() -> bool {
    true
}

#[tauri::command]
pub fn automation_save(state: S, args: AutomationInput) -> Result<Automation> {
    let now = timestamp();
    let existing = args.id.as_ref().and_then(|id| store::automation_get(&state.db, id).ok());
    let dtstart = args
        .dtstart
        .or_else(|| existing.as_ref().map(|a| a.dtstart.clone()))
        .unwrap_or_else(|| now.clone());
    let workspace_mode = args.workspace_mode.unwrap_or_else(|| "new_worktree".into());
    // Continuing a session only means anything when a worktree is pinned.
    let pinned = if workspace_mode == "pinned" { args.pinned_session_id.clone() } else { None };
    let continue_session = workspace_mode == "pinned" && pinned.is_some() && args.continue_agent_session;

    // Validate the schedule before storing it.
    let next = scheduler::next_occurrence(&args.rrule, &args.timezone, &dtstart, chrono::Utc::now())?;

    let a = Automation {
        id: args.id.unwrap_or_else(new_id),
        name: args.name,
        prompt: args.prompt,
        provider_id: args.provider_id,
        project_id: args.project_id,
        rrule: args.rrule,
        timezone: args.timezone,
        dtstart,
        workspace_mode,
        pinned_session_id: pinned,
        continue_agent_session: continue_session,
        permission_policy: args.permission_policy.unwrap_or_else(|| "auto-edits".into()),
        catch_up: args.catch_up,
        enabled: args.enabled,
        next_run_at: if args.enabled { next.map(|d| d.to_rfc3339()) } else { None },
        created_at: existing.map(|e| e.created_at).unwrap_or_else(|| now.clone()),
        updated_at: now,
    };
    store::automation_upsert(&state.db, &a)?;
    state.wake_scheduler();
    Ok(a)
}

#[tauri::command]
pub fn automations_list(state: S) -> Result<Vec<Automation>> {
    store::automations_list(&state.db)
}

#[tauri::command]
pub fn automation_get(state: S, id: String) -> Result<Automation> {
    store::automation_get(&state.db, &id)
}

#[tauri::command]
pub fn automation_set_enabled(state: S, id: String, enabled: bool) -> Result<Automation> {
    let mut a = store::automation_get(&state.db, &id)?;
    a.enabled = enabled;
    a.updated_at = timestamp();
    a.next_run_at = if enabled {
        scheduler::next_occurrence(&a.rrule, &a.timezone, &a.dtstart, chrono::Utc::now())?
            .map(|d| d.to_rfc3339())
    } else {
        None
    };
    store::automation_upsert(&state.db, &a)?;
    state.wake_scheduler();
    Ok(a)
}

#[tauri::command]
pub fn automation_delete(state: S, id: String) -> Result<()> {
    store::automation_delete(&state.db, &id)?;
    state.wake_scheduler();
    Ok(())
}

#[tauri::command]
pub fn automation_runs(state: S, id: String, limit: Option<i64>) -> Result<Vec<AutomationRun>> {
    store::runs_list(&state.db, &id, limit.unwrap_or(20))
}

#[tauri::command]
pub fn schedule_preview(rrule: String, timezone: String, dtstart: Option<String>, count: Option<usize>) -> Result<Vec<String>> {
    let start = dtstart.unwrap_or_else(timestamp);
    Ok(scheduler::preview(&rrule, &timezone, &start, count.unwrap_or(3))?
        .into_iter()
        .map(|d| d.to_rfc3339())
        .collect())
}

#[tauri::command]
pub fn schedule_preset(preset: String, hour: u32, minute: u32) -> Result<String> {
    scheduler::preset_rrule(&preset, hour, minute)
        .ok_or_else(|| Error::msg(format!("unknown preset `{preset}`")))
}

#[tauri::command]
pub async fn automation_run_now(app: tauri::AppHandle, state: S<'_>, id: String) -> Result<String> {
    crate::automations::fire(&app, &state, &id, "manual").await
}

/// Called by the frontend once it has launched (or failed to launch) a run.
#[tauri::command]
pub fn automation_run_report(state: S, run_id: String, status: String, session_id: Option<String>, error: Option<String>) -> Result<()> {
    store::run_update(&state.db, &run_id, &status, session_id.as_deref(), error.as_deref())
}
