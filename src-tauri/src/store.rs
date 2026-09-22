use crate::db::Db;
use crate::error::{Error, Result};
use crate::models::*;
use rusqlite::{params, Row};

fn project_from_row(r: &Row) -> rusqlite::Result<Project> {
    let nested: String = r.get("nested_repos")?;
    Ok(Project {
        id: r.get("id")?,
        name: r.get("name")?,
        executor: r.get("executor")?,
        root_path: r.get("root_path")?,
        ssh_host: r.get("ssh_host")?,
        ssh_extra_args: r.get("ssh_extra_args")?,
        default_base_ref: r.get("default_base_ref")?,
        default_provider_id: r.get("default_provider_id")?,
        default_permission_policy: r.get("default_permission_policy")?,
        nested_repos: serde_json::from_str(&nested).unwrap_or_default(),
        worktree_template: r.get("worktree_template")?,
        branch_prefix: r.get("branch_prefix")?,
        sort_order: r.get("sort_order")?,
        created_at: r.get("created_at")?,
        archived_at: r.get("archived_at")?,
    })
}

fn session_from_row(r: &Row) -> rusqlite::Result<Session> {
    Ok(Session {
        id: r.get("id")?,
        project_id: r.get("project_id")?,
        name: r.get("name")?,
        provider_id: r.get("provider_id")?,
        provider_session_id: r.get("provider_session_id")?,
        worktree_path: r.get("worktree_path")?,
        branch: r.get("branch")?,
        base_ref: r.get("base_ref")?,
        status: r.get("status")?,
        status_detail: r.get("status_detail")?,
        permission_policy: r.get("permission_policy")?,
        prompt: r.get("prompt")?,
        automation_id: r.get("automation_id")?,
        created_at: r.get("created_at")?,
        last_event_at: r.get("last_event_at")?,
        archived_at: r.get("archived_at")?,
        alive: false,
    })
}

fn automation_from_row(r: &Row) -> rusqlite::Result<Automation> {
    Ok(Automation {
        id: r.get("id")?,
        name: r.get("name")?,
        prompt: r.get("prompt")?,
        provider_id: r.get("provider_id")?,
        project_id: r.get("project_id")?,
        rrule: r.get("rrule")?,
        timezone: r.get("timezone")?,
        dtstart: r.get("dtstart")?,
        workspace_mode: r.get("workspace_mode")?,
        pinned_session_id: r.get("pinned_session_id")?,
        continue_agent_session: r.get::<_, i64>("continue_agent_session")? != 0,
        permission_policy: r.get("permission_policy")?,
        catch_up: r.get::<_, i64>("catch_up")? != 0,
        enabled: r.get::<_, i64>("enabled")? != 0,
        next_run_at: r.get("next_run_at")?,
        created_at: r.get("created_at")?,
        updated_at: r.get("updated_at")?,
    })
}

fn run_from_row(r: &Row) -> rusqlite::Result<AutomationRun> {
    Ok(AutomationRun {
        id: r.get("id")?,
        automation_id: r.get("automation_id")?,
        fired_at: r.get("fired_at")?,
        trigger: r.get("trigger")?,
        status: r.get("status")?,
        session_id: r.get("session_id")?,
        error: r.get("error")?,
    })
}

// ---------- settings ----------

pub fn settings_all(db: &Db) -> Result<serde_json::Map<String, serde_json::Value>> {
    db.with(|c| {
        let mut stmt = c.prepare("SELECT key, value FROM settings")?;
        let mut map = serde_json::Map::new();
        let rows = stmt.query_map([], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })?;
        for row in rows {
            let (k, v) = row?;
            map.insert(k, serde_json::from_str(&v).unwrap_or(serde_json::Value::String(v)));
        }
        Ok(map)
    })
}

pub fn settings_set(db: &Db, key: &str, value: &serde_json::Value) -> Result<()> {
    let encoded = serde_json::to_string(value)?;
    db.with(|c| {
        c.execute(
            "INSERT INTO settings(key, value) VALUES(?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, encoded],
        )?;
        Ok(())
    })
}

pub fn setting_str(db: &Db, key: &str) -> Option<String> {
    settings_all(db)
        .ok()
        .and_then(|m| m.get(key).and_then(|v| v.as_str().map(|s| s.to_string())))
}

// ---------- projects ----------

pub fn projects_list(db: &Db) -> Result<Vec<Project>> {
    db.with(|c| {
        let mut stmt = c.prepare("SELECT * FROM projects ORDER BY sort_order, created_at")?;
        let rows = stmt.query_map([], project_from_row)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    })
}

pub fn project_get(db: &Db, id: &str) -> Result<Project> {
    db.with(|c| {
        let mut stmt = c.prepare("SELECT * FROM projects WHERE id = ?1")?;
        let mut rows = stmt.query_map([id], project_from_row)?;
        rows.next()
            .transpose()?
            .ok_or_else(|| Error::NotFound(format!("project {id}")))
    })
}

pub fn project_insert(db: &Db, p: &Project) -> Result<()> {
    db.with(|c| {
        c.execute(
            "INSERT INTO projects(id,name,executor,root_path,ssh_host,ssh_extra_args,default_base_ref,
             default_provider_id,default_permission_policy,nested_repos,worktree_template,branch_prefix,
             sort_order,created_at,archived_at)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)",
            params![
                p.id, p.name, p.executor, p.root_path, p.ssh_host, p.ssh_extra_args,
                p.default_base_ref, p.default_provider_id, p.default_permission_policy,
                serde_json::to_string(&p.nested_repos)?, p.worktree_template, p.branch_prefix,
                p.sort_order, p.created_at, p.archived_at
            ],
        )?;
        Ok(())
    })
}

pub fn project_update(db: &Db, p: &Project) -> Result<()> {
    db.with(|c| {
        c.execute(
            "UPDATE projects SET name=?2, default_base_ref=?3, default_provider_id=?4,
             default_permission_policy=?5, nested_repos=?6, worktree_template=?7, branch_prefix=?8,
             sort_order=?9, archived_at=?10, ssh_host=?11, ssh_extra_args=?12 WHERE id=?1",
            params![
                p.id, p.name, p.default_base_ref, p.default_provider_id, p.default_permission_policy,
                serde_json::to_string(&p.nested_repos)?, p.worktree_template, p.branch_prefix,
                p.sort_order, p.archived_at, p.ssh_host, p.ssh_extra_args
            ],
        )?;
        Ok(())
    })
}

pub fn project_delete(db: &Db, id: &str) -> Result<()> {
    db.with(|c| {
        c.execute("DELETE FROM projects WHERE id = ?1", [id])?;
        Ok(())
    })
}

// ---------- sessions ----------

pub fn sessions_list(db: &Db) -> Result<Vec<Session>> {
    db.with(|c| {
        let mut stmt = c.prepare(
            "SELECT * FROM sessions ORDER BY COALESCE(last_event_at, created_at) DESC",
        )?;
        let rows = stmt.query_map([], session_from_row)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    })
}

pub fn session_get(db: &Db, id: &str) -> Result<Session> {
    db.with(|c| {
        let mut stmt = c.prepare("SELECT * FROM sessions WHERE id = ?1")?;
        let mut rows = stmt.query_map([id], session_from_row)?;
        rows.next()
            .transpose()?
            .ok_or_else(|| Error::NotFound(format!("session {id}")))
    })
}

pub fn session_insert(db: &Db, s: &Session) -> Result<()> {
    db.with(|c| {
        c.execute(
            "INSERT INTO sessions(id,project_id,name,provider_id,provider_session_id,worktree_path,
             branch,base_ref,status,status_detail,permission_policy,prompt,automation_id,created_at,
             last_event_at,archived_at)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)",
            params![
                s.id, s.project_id, s.name, s.provider_id, s.provider_session_id, s.worktree_path,
                s.branch, s.base_ref, s.status, s.status_detail, s.permission_policy, s.prompt,
                s.automation_id, s.created_at, s.last_event_at, s.archived_at
            ],
        )?;
        Ok(())
    })
}

pub fn session_set_status(db: &Db, id: &str, status: &str, detail: Option<&str>) -> Result<()> {
    db.with(|c| {
        c.execute(
            "UPDATE sessions SET status=?2, status_detail=?3, last_event_at=?4 WHERE id=?1",
            params![id, status, detail, timestamp()],
        )?;
        Ok(())
    })
}

pub fn session_set_provider_session_id(db: &Db, id: &str, psid: &str) -> Result<()> {
    db.with(|c| {
        c.execute(
            "UPDATE sessions SET provider_session_id=?2 WHERE id=?1",
            params![id, psid],
        )?;
        Ok(())
    })
}

pub fn session_rename(db: &Db, id: &str, name: &str) -> Result<()> {
    db.with(|c| {
        c.execute("UPDATE sessions SET name=?2 WHERE id=?1", params![id, name])?;
        Ok(())
    })
}

pub fn session_set_archived(db: &Db, id: &str, archived: bool) -> Result<()> {
    let at = if archived { Some(timestamp()) } else { None };
    db.with(|c| {
        c.execute("UPDATE sessions SET archived_at=?2 WHERE id=?1", params![id, at])?;
        Ok(())
    })
}

pub fn session_touch(db: &Db, id: &str) -> Result<()> {
    db.with(|c| {
        c.execute(
            "UPDATE sessions SET last_event_at=?2 WHERE id=?1",
            params![id, timestamp()],
        )?;
        Ok(())
    })
}

pub fn session_delete(db: &Db, id: &str) -> Result<()> {
    db.with(|c| {
        c.execute("DELETE FROM sessions WHERE id=?1", [id])?;
        Ok(())
    })
}

// ---------- usage ----------

pub fn usage_insert(db: &Db, u: &UsageRecord) -> Result<()> {
    db.with(|c| {
        c.execute(
            "INSERT INTO usage_events(session_id,project_id,provider_id,at,input_tokens,output_tokens,
             cache_read,cache_write,cost_usd,duration_ms,turns)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
            params![
                u.session_id, u.project_id, u.provider_id, timestamp(), u.input_tokens,
                u.output_tokens, u.cache_read, u.cache_write, u.cost_usd, u.duration_ms, u.turns
            ],
        )?;
        Ok(())
    })
}

/// `since` is an RFC3339 lower bound; None means all time.
pub fn usage_summary(db: &Db, since: Option<&str>, project_id: Option<&str>) -> Result<Vec<UsageSummary>> {
    db.with(|c| {
        let mut sql = String::from(
            "SELECT provider_id, COUNT(DISTINCT session_id) AS sessions, SUM(turns) AS turns,
                    SUM(input_tokens) AS it, SUM(output_tokens) AS ot, SUM(cache_read) AS cr,
                    SUM(cache_write) AS cw, SUM(cost_usd) AS cost, SUM(duration_ms) AS dur
             FROM usage_events WHERE 1=1",
        );
        if since.is_some() {
            sql.push_str(" AND at >= ?1");
        }
        if project_id.is_some() {
            sql.push_str(if since.is_some() { " AND project_id = ?2" } else { " AND project_id = ?1" });
        }
        sql.push_str(" GROUP BY provider_id ORDER BY provider_id");
        let mut stmt = c.prepare(&sql)?;
        let map = |r: &Row| -> rusqlite::Result<UsageSummary> {
            Ok(UsageSummary {
                provider_id: r.get(0)?,
                sessions: r.get::<_, Option<i64>>(1)?.unwrap_or(0),
                turns: r.get::<_, Option<i64>>(2)?.unwrap_or(0),
                input_tokens: r.get::<_, Option<i64>>(3)?.unwrap_or(0),
                output_tokens: r.get::<_, Option<i64>>(4)?.unwrap_or(0),
                cache_read: r.get::<_, Option<i64>>(5)?.unwrap_or(0),
                cache_write: r.get::<_, Option<i64>>(6)?.unwrap_or(0),
                cost_usd: r.get::<_, Option<f64>>(7)?.unwrap_or(0.0),
                duration_ms: r.get::<_, Option<i64>>(8)?.unwrap_or(0),
            })
        };
        let rows: Vec<UsageSummary> = match (since, project_id) {
            (Some(s), Some(p)) => stmt.query_map(params![s, p], map)?.collect::<rusqlite::Result<_>>()?,
            (Some(s), None) => stmt.query_map(params![s], map)?.collect::<rusqlite::Result<_>>()?,
            (None, Some(p)) => stmt.query_map(params![p], map)?.collect::<rusqlite::Result<_>>()?,
            (None, None) => stmt.query_map([], map)?.collect::<rusqlite::Result<_>>()?,
        };
        Ok(rows)
    })
}

pub fn usage_by_day(db: &Db, since: Option<&str>) -> Result<Vec<UsageDay>> {
    db.with(|c| {
        let mut sql = String::from(
            "SELECT substr(at,1,10) AS day, provider_id, SUM(input_tokens), SUM(output_tokens), SUM(cost_usd)
             FROM usage_events WHERE 1=1",
        );
        if since.is_some() {
            sql.push_str(" AND at >= ?1");
        }
        sql.push_str(" GROUP BY day, provider_id ORDER BY day");
        let mut stmt = c.prepare(&sql)?;
        let map = |r: &Row| -> rusqlite::Result<UsageDay> {
            Ok(UsageDay {
                day: r.get(0)?,
                provider_id: r.get(1)?,
                input_tokens: r.get::<_, Option<i64>>(2)?.unwrap_or(0),
                output_tokens: r.get::<_, Option<i64>>(3)?.unwrap_or(0),
                cost_usd: r.get::<_, Option<f64>>(4)?.unwrap_or(0.0),
            })
        };
        let rows: Vec<UsageDay> = match since {
            Some(s) => stmt.query_map(params![s], map)?.collect::<rusqlite::Result<_>>()?,
            None => stmt.query_map([], map)?.collect::<rusqlite::Result<_>>()?,
        };
        Ok(rows)
    })
}

// ---------- automations ----------

pub fn automations_list(db: &Db) -> Result<Vec<Automation>> {
    db.with(|c| {
        let mut stmt = c.prepare("SELECT * FROM automations ORDER BY created_at")?;
        let rows = stmt.query_map([], automation_from_row)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    })
}

pub fn automation_get(db: &Db, id: &str) -> Result<Automation> {
    db.with(|c| {
        let mut stmt = c.prepare("SELECT * FROM automations WHERE id=?1")?;
        let mut rows = stmt.query_map([id], automation_from_row)?;
        rows.next()
            .transpose()?
            .ok_or_else(|| Error::NotFound(format!("automation {id}")))
    })
}

pub fn automation_upsert(db: &Db, a: &Automation) -> Result<()> {
    db.with(|c| {
        c.execute(
            "INSERT INTO automations(id,name,prompt,provider_id,project_id,rrule,timezone,dtstart,
             workspace_mode,pinned_session_id,continue_agent_session,permission_policy,catch_up,enabled,
             next_run_at,created_at,updated_at)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)
             ON CONFLICT(id) DO UPDATE SET name=excluded.name, prompt=excluded.prompt,
               provider_id=excluded.provider_id, project_id=excluded.project_id, rrule=excluded.rrule,
               timezone=excluded.timezone, dtstart=excluded.dtstart, workspace_mode=excluded.workspace_mode,
               pinned_session_id=excluded.pinned_session_id,
               continue_agent_session=excluded.continue_agent_session,
               permission_policy=excluded.permission_policy, catch_up=excluded.catch_up,
               enabled=excluded.enabled, next_run_at=excluded.next_run_at, updated_at=excluded.updated_at",
            params![
                a.id, a.name, a.prompt, a.provider_id, a.project_id, a.rrule, a.timezone, a.dtstart,
                a.workspace_mode, a.pinned_session_id, a.continue_agent_session as i64,
                a.permission_policy, a.catch_up as i64, a.enabled as i64, a.next_run_at,
                a.created_at, a.updated_at
            ],
        )?;
        Ok(())
    })
}

pub fn automation_set_next_run(db: &Db, id: &str, next: Option<&str>) -> Result<()> {
    db.with(|c| {
        c.execute("UPDATE automations SET next_run_at=?2 WHERE id=?1", params![id, next])?;
        Ok(())
    })
}

pub fn automation_delete(db: &Db, id: &str) -> Result<()> {
    db.with(|c| {
        c.execute("DELETE FROM automations WHERE id=?1", [id])?;
        Ok(())
    })
}

pub fn run_insert(db: &Db, r: &AutomationRun) -> Result<()> {
    db.with(|c| {
        c.execute(
            "INSERT INTO automation_runs(id,automation_id,fired_at,trigger,status,session_id,error)
             VALUES(?1,?2,?3,?4,?5,?6,?7)",
            params![r.id, r.automation_id, r.fired_at, r.trigger, r.status, r.session_id, r.error],
        )?;
        Ok(())
    })
}

pub fn run_update(db: &Db, id: &str, status: &str, session_id: Option<&str>, error: Option<&str>) -> Result<()> {
    db.with(|c| {
        c.execute(
            "UPDATE automation_runs SET status=?2, session_id=COALESCE(?3, session_id), error=?4 WHERE id=?1",
            params![id, status, session_id, error],
        )?;
        Ok(())
    })
}

pub fn runs_list(db: &Db, automation_id: &str, limit: i64) -> Result<Vec<AutomationRun>> {
    db.with(|c| {
        let mut stmt = c.prepare(
            "SELECT * FROM automation_runs WHERE automation_id=?1 ORDER BY fired_at DESC LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![automation_id, limit], run_from_row)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    })
}

pub fn last_run(db: &Db, automation_id: &str) -> Result<Option<AutomationRun>> {
    Ok(runs_list(db, automation_id, 1)?.into_iter().next())
}
