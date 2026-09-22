use serde::{Deserialize, Serialize};

fn now() -> String {
    chrono::Utc::now().to_rfc3339()
}

pub fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

pub fn timestamp() -> String {
    now()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Project {
    pub id: String,
    pub name: String,
    pub executor: String,
    pub root_path: String,
    pub ssh_host: Option<String>,
    pub ssh_extra_args: Option<String>,
    pub default_base_ref: String,
    pub default_provider_id: String,
    pub default_permission_policy: String,
    pub nested_repos: Vec<String>,
    pub worktree_template: Option<String>,
    pub branch_prefix: Option<String>,
    pub sort_order: i64,
    pub created_at: String,
    pub archived_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    pub id: String,
    pub project_id: Option<String>,
    pub name: String,
    pub provider_id: String,
    pub provider_session_id: Option<String>,
    pub worktree_path: Option<String>,
    pub branch: Option<String>,
    pub base_ref: Option<String>,
    pub status: String,
    pub status_detail: Option<String>,
    pub permission_policy: String,
    pub prompt: Option<String>,
    pub automation_id: Option<String>,
    pub created_at: String,
    pub last_event_at: Option<String>,
    pub archived_at: Option<String>,
    /// Runtime only: is a process currently attached.
    #[serde(default)]
    pub alive: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Automation {
    pub id: String,
    pub name: String,
    pub prompt: String,
    pub provider_id: String,
    pub project_id: Option<String>,
    pub rrule: String,
    pub timezone: String,
    pub dtstart: String,
    pub workspace_mode: String,
    pub pinned_session_id: Option<String>,
    pub continue_agent_session: bool,
    pub permission_policy: String,
    pub catch_up: bool,
    pub enabled: bool,
    pub next_run_at: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AutomationRun {
    pub id: String,
    pub automation_id: String,
    pub fired_at: String,
    pub trigger: String,
    pub status: String,
    pub session_id: Option<String>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UsageRecord {
    pub session_id: String,
    pub project_id: Option<String>,
    pub provider_id: String,
    #[serde(default)]
    pub input_tokens: i64,
    #[serde(default)]
    pub output_tokens: i64,
    #[serde(default)]
    pub cache_read: i64,
    #[serde(default)]
    pub cache_write: i64,
    #[serde(default)]
    pub cost_usd: f64,
    #[serde(default)]
    pub duration_ms: i64,
    #[serde(default)]
    pub turns: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UsageSummary {
    pub provider_id: String,
    pub sessions: i64,
    pub turns: i64,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cache_read: i64,
    pub cache_write: i64,
    pub cost_usd: f64,
    pub duration_ms: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UsageDay {
    pub day: String,
    pub provider_id: String,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cost_usd: f64,
}
