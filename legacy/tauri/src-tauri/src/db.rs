use crate::error::Result;
use crate::paths;
use parking_lot::Mutex;
use rusqlite::Connection;
use std::sync::Arc;

#[derive(Clone)]
pub struct Db(Arc<Mutex<Connection>>);

impl Db {
    pub fn open() -> Result<Self> {
        let conn = Connection::open(paths::db_file()?)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        let db = Db(Arc::new(Mutex::new(conn)));
        db.migrate()?;
        Ok(db)
    }

    pub fn with<T>(&self, f: impl FnOnce(&Connection) -> Result<T>) -> Result<T> {
        let guard = self.0.lock();
        f(&guard)
    }

    fn migrate(&self) -> Result<()> {
        self.with(|c| {
            c.execute_batch(
                r#"
CREATE TABLE IF NOT EXISTS settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS projects (
  id                        TEXT PRIMARY KEY,
  name                      TEXT NOT NULL,
  executor                  TEXT NOT NULL DEFAULT 'local',
  root_path                 TEXT NOT NULL,
  ssh_host                  TEXT,
  ssh_extra_args            TEXT,
  default_base_ref          TEXT NOT NULL DEFAULT 'HEAD',
  default_provider_id       TEXT NOT NULL DEFAULT 'claude',
  default_permission_policy TEXT NOT NULL DEFAULT 'ask',
  nested_repos              TEXT NOT NULL DEFAULT '[]',
  worktree_template         TEXT,
  branch_prefix             TEXT,
  sort_order                INTEGER NOT NULL DEFAULT 0,
  created_at                TEXT NOT NULL,
  archived_at               TEXT
);

CREATE TABLE IF NOT EXISTS sessions (
  id                  TEXT PRIMARY KEY,
  project_id          TEXT REFERENCES projects(id) ON DELETE CASCADE,
  name                TEXT NOT NULL,
  provider_id         TEXT NOT NULL,
  provider_session_id TEXT,
  worktree_path       TEXT,
  branch              TEXT,
  base_ref            TEXT,
  status              TEXT NOT NULL DEFAULT 'created',
  status_detail       TEXT,
  permission_policy   TEXT NOT NULL DEFAULT 'ask',
  prompt              TEXT,
  automation_id       TEXT,
  created_at          TEXT NOT NULL,
  last_event_at       TEXT,
  archived_at         TEXT
);
CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project_id);

CREATE TABLE IF NOT EXISTS usage_events (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id    TEXT NOT NULL,
  project_id    TEXT,
  provider_id   TEXT NOT NULL,
  at            TEXT NOT NULL,
  input_tokens  INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  cache_read    INTEGER NOT NULL DEFAULT 0,
  cache_write   INTEGER NOT NULL DEFAULT 0,
  cost_usd      REAL NOT NULL DEFAULT 0,
  duration_ms   INTEGER NOT NULL DEFAULT 0,
  turns         INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_usage_at ON usage_events(at);

CREATE TABLE IF NOT EXISTS automations (
  id                     TEXT PRIMARY KEY,
  name                   TEXT NOT NULL,
  prompt                 TEXT NOT NULL,
  provider_id            TEXT NOT NULL,
  project_id             TEXT REFERENCES projects(id) ON DELETE CASCADE,
  rrule                  TEXT NOT NULL,
  timezone               TEXT NOT NULL,
  dtstart                TEXT NOT NULL,
  workspace_mode         TEXT NOT NULL DEFAULT 'new_worktree',
  pinned_session_id      TEXT,
  continue_agent_session INTEGER NOT NULL DEFAULT 0,
  permission_policy      TEXT NOT NULL DEFAULT 'ask',
  catch_up               INTEGER NOT NULL DEFAULT 0,
  enabled                INTEGER NOT NULL DEFAULT 1,
  next_run_at            TEXT,
  created_at             TEXT NOT NULL,
  updated_at             TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS automation_runs (
  id            TEXT PRIMARY KEY,
  automation_id TEXT NOT NULL REFERENCES automations(id) ON DELETE CASCADE,
  fired_at      TEXT NOT NULL,
  trigger       TEXT NOT NULL,
  status        TEXT NOT NULL,
  session_id    TEXT,
  error         TEXT
);
CREATE INDEX IF NOT EXISTS idx_runs_automation ON automation_runs(automation_id, fired_at DESC);

CREATE TABLE IF NOT EXISTS paired_devices (
  device_id        TEXT PRIMARY KEY,
  name             TEXT NOT NULL,
  cert_fingerprint TEXT NOT NULL,
  last_seen        TEXT,
  paired_at        TEXT NOT NULL
);
"#,
            )?;
            Ok(())
        })
    }
}
