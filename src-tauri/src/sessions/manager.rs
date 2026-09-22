use crate::db::Db;
use crate::error::{Error, Result};
use crate::executor::{Executor, LaunchSpec, ProcHandle, ProcLine};
use crate::paths;
use crate::store;
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::Write;
use std::sync::Arc;
use tokio::sync::broadcast;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SessionEvent {
    Line {
        session_id: String,
        seq: u64,
        stream: String,
        line: String,
    },
    Exit {
        session_id: String,
        code: Option<i32>,
    },
    Status {
        session_id: String,
        status: String,
        detail: Option<String>,
    },
}

struct Running {
    handle: ProcHandle,
    /// Shared with the reader task so replay and live streaming agree on
    /// sequence numbers.
    #[allow(dead_code)]
    seq: Arc<Mutex<u64>>,
}

pub struct SessionManager {
    db: Db,
    running: Mutex<HashMap<String, Running>>,
    bus: broadcast::Sender<SessionEvent>,
}

impl SessionManager {
    pub fn new(db: Db) -> Self {
        let (bus, _) = broadcast::channel(4096);
        SessionManager {
            db,
            running: Mutex::new(HashMap::new()),
            bus,
        }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<SessionEvent> {
        self.bus.subscribe()
    }

    pub fn is_alive(&self, session_id: &str) -> bool {
        self.running.lock().contains_key(session_id)
    }

    pub fn alive_ids(&self) -> Vec<String> {
        self.running.lock().keys().cloned().collect()
    }

    fn emit(&self, ev: SessionEvent) {
        let _ = self.bus.send(ev);
    }

    /// Spawn the agent process for an existing session row.
    pub async fn launch(
        &self,
        exec: Arc<dyn Executor>,
        session_id: &str,
        spec: LaunchSpec,
    ) -> Result<()> {
        if self.is_alive(session_id) {
            return Err(Error::msg("session already running"));
        }
        let log_path = paths::session_log_file(session_id)?;
        let seq = Arc::new(Mutex::new(0u64));

        let bus = self.bus.clone();
        let sid = session_id.to_string();
        let seq_for_lines = seq.clone();
        let log_for_lines = log_path.clone();
        let on_line = Arc::new(move |pl: ProcLine| {
            let n = {
                let mut s = seq_for_lines.lock();
                *s += 1;
                *s
            };
            append_log(&log_for_lines, &pl);
            let _ = bus.send(SessionEvent::Line {
                session_id: sid.clone(),
                seq: n,
                stream: pl.stream,
                line: pl.line,
            });
        });

        let bus_exit = self.bus.clone();
        let sid_exit = session_id.to_string();
        let db_exit = self.db.clone();
        let on_exit = Arc::new(move |code: Option<i32>| {
            let status = if code == Some(0) { "finished" } else { "errored" };
            let _ = store::session_set_status(&db_exit, &sid_exit, status, None);
            let _ = bus_exit.send(SessionEvent::Exit {
                session_id: sid_exit.clone(),
                code,
            });
            let _ = bus_exit.send(SessionEvent::Status {
                session_id: sid_exit.clone(),
                status: status.to_string(),
                detail: None,
            });
        });

        let handle = exec.spawn_stream(spec, on_line, on_exit).await?;
        self.running
            .lock()
            .insert(session_id.to_string(), Running { handle, seq });

        store::session_set_status(&self.db, session_id, "running", None)?;
        self.emit(SessionEvent::Status {
            session_id: session_id.to_string(),
            status: "running".into(),
            detail: None,
        });
        Ok(())
    }

    pub fn write_stdin(&self, session_id: &str, data: &str) -> Result<()> {
        let running = self.running.lock();
        let r = running
            .get(session_id)
            .ok_or_else(|| Error::msg("session is not running"))?;
        let tx = r
            .handle
            .stdin
            .as_ref()
            .ok_or_else(|| Error::msg("session stdin is closed"))?;
        tx.send(data.to_string())
            .map_err(|_| Error::msg("session stdin is closed"))?;
        Ok(())
    }

    pub fn stop(&self, session_id: &str) -> Result<()> {
        let running = self.running.lock();
        if let Some(r) = running.get(session_id) {
            (r.handle.kill)();
            Ok(())
        } else {
            Err(Error::msg("session is not running"))
        }
    }

    /// Called from the exit path and on explicit cleanup.
    pub fn forget(&self, session_id: &str) {
        self.running.lock().remove(session_id);
    }

    pub fn set_status(&self, session_id: &str, status: &str, detail: Option<&str>) -> Result<()> {
        store::session_set_status(&self.db, session_id, status, detail)?;
        if matches!(status, "finished" | "errored") {
            self.forget(session_id);
        }
        self.emit(SessionEvent::Status {
            session_id: session_id.to_string(),
            status: status.to_string(),
            detail: detail.map(|s| s.to_string()),
        });
        Ok(())
    }

    /// Replay the recorded raw output of a session (for reopening a chat).
    pub fn replay(&self, session_id: &str, from_seq: u64) -> Result<Vec<SessionEvent>> {
        let path = paths::session_log_file(session_id)?;
        let Ok(content) = std::fs::read_to_string(&path) else {
            return Ok(Vec::new());
        };
        let mut out = Vec::new();
        for (i, line) in content.lines().enumerate() {
            let seq = (i + 1) as u64;
            if seq <= from_seq {
                continue;
            }
            if let Ok(pl) = serde_json::from_str::<ProcLine>(line) {
                out.push(SessionEvent::Line {
                    session_id: session_id.to_string(),
                    seq,
                    stream: pl.stream,
                    line: pl.line,
                });
            }
        }
        Ok(out)
    }

    pub fn clear_log(&self, session_id: &str) -> Result<()> {
        let path = paths::session_log_file(session_id)?;
        let _ = std::fs::remove_file(path);
        Ok(())
    }

    /// Mark sessions that were running when the app was last closed.
    pub fn reconcile_on_start(&self) -> Result<()> {
        let sessions = store::sessions_list(&self.db)?;
        for s in sessions {
            if matches!(s.status.as_str(), "running" | "provisioning" | "waiting_input") {
                store::session_set_status(
                    &self.db,
                    &s.id,
                    "errored",
                    Some("interrupted when Backtick last closed"),
                )?;
            }
        }
        Ok(())
    }

    pub fn touch(&self, session_id: &str) {
        let _ = store::session_touch(&self.db, session_id);
    }
}

fn append_log(path: &std::path::Path, pl: &ProcLine) {
    if let Ok(json) = serde_json::to_string(pl) {
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(f, "{json}");
        }
    }
}
