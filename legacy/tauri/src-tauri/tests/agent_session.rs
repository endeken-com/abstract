//! Drives a real agent CLI through the session manager: spawn with the exact
//! argv the provider builds, stream its output, persist it, and replay it.
//!
//! Needs the `claude` binary and a logged-in subscription, so it is opt-in:
//!   ABSTRACT_E2E=1 cargo test --test agent_session -- --nocapture

use abstract_lib::db::Db;
use abstract_lib::executor::{local::LocalExecutor, LaunchSpec};
use abstract_lib::models::{new_id, timestamp, Session};
use abstract_lib::sessions::manager::{SessionEvent, SessionManager};
use abstract_lib::store;
use std::sync::Arc;

#[tokio::test]
async fn streams_persists_and_replays_a_real_agent_run() {
    if std::env::var("ABSTRACT_E2E").is_err() {
        eprintln!("skipping: set ABSTRACT_E2E=1 to run against the real claude CLI");
        return;
    }

    // Keep every side effect inside a throwaway data directory.
    let data_dir = std::env::temp_dir().join(format!("abstract-e2e-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&data_dir).unwrap();
    std::env::set_var("ABSTRACT_DATA_DIR", &data_dir);

    let workdir = data_dir.join("work");
    std::fs::create_dir_all(&workdir).unwrap();

    let db = Db::open().expect("database opens");
    let manager = Arc::new(SessionManager::new(db.clone()));
    let exec: Arc<LocalExecutor> = Arc::new(LocalExecutor::new());

    let session = Session {
        id: new_id(),
        project_id: None,
        name: "e2e".into(),
        provider_id: "claude".into(),
        provider_session_id: None,
        worktree_path: Some(workdir.to_string_lossy().to_string()),
        branch: None,
        base_ref: None,
        status: "created".into(),
        status_detail: None,
        permission_policy: "auto-edits".into(),
        prompt: Some("write hi.txt".into()),
        automation_id: None,
        created_at: timestamp(),
        last_event_at: None,
        archived_at: None,
        alive: false,
    };
    store::session_insert(&db, &session).unwrap();

    let mut rx = manager.subscribe();

    // Exactly what src/providers/claude.ts builds for an auto-edits launch.
    let spec = LaunchSpec {
        command: "claude".into(),
        args: [
            "-p",
            "--output-format",
            "stream-json",
            "--input-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-mode",
            "acceptEdits",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect(),
        cwd: workdir.to_string_lossy().to_string(),
        env: Default::default(),
        stdin_initial: Some(
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Create a file named hi.txt containing the word hi, then stop.\"}]}}\n"
                .into(),
        ),
        keep_stdin_open: true,
    };

    manager
        .launch(exec.clone(), &session.id, spec)
        .await
        .expect("agent process spawned");

    assert!(manager.is_alive(&session.id), "session is tracked while running");
    assert_eq!(
        store::session_get(&db, &session.id).unwrap().status,
        "running",
        "status flips to running on spawn"
    );

    // Collect the stream until the process exits.
    // The turn ends at the `result` frame. The process stays alive after it,
    // waiting for a follow-up, which is exactly how a chat session behaves.
    let mut lines: Vec<String> = Vec::new();
    let mut reached_result = false;
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(180);
    while tokio::time::Instant::now() < deadline && !reached_result {
        match tokio::time::timeout_at(deadline, rx.recv()).await {
            Ok(Ok(SessionEvent::Line { line, .. })) => {
                reached_result = line.contains("\"type\":\"result\"");
                lines.push(line);
            }
            Ok(Ok(SessionEvent::Exit { .. })) => break,
            Ok(Ok(SessionEvent::Status { .. })) => {}
            _ => break,
        }
    }
    assert!(reached_result, "the turn finished within the time limit");

    // The agent's stdin stays open for follow-ups, so close it by stopping.
    let _ = manager.stop(&session.id);

    assert!(!lines.is_empty(), "the agent produced output");
    assert!(
        lines.iter().any(|l| l.contains("\"subtype\":\"init\"")),
        "the init frame carries the agent's own session id"
    );
    assert!(
        lines.iter().any(|l| l.contains("\"type\":\"result\"")),
        "the run reached a result frame"
    );
    assert!(
        workdir.join("hi.txt").exists(),
        "the agent worked inside the directory it was given"
    );

    // Everything streamed was also written to disk and replays in order.
    let replayed = manager.replay(&session.id, 0).unwrap();
    assert_eq!(replayed.len(), lines.len(), "replay covers every streamed line");
    let first_replay_line = match &replayed[0] {
        SessionEvent::Line { line, seq, .. } => {
            assert_eq!(*seq, 1, "sequence numbers start at one");
            line.clone()
        }
        other => panic!("expected a line event, got {other:?}"),
    };
    assert_eq!(first_replay_line, lines[0]);

    // Replaying from a sequence number skips what the UI already has.
    let tail = manager.replay(&session.id, (lines.len() - 1) as u64).unwrap();
    assert_eq!(tail.len(), 1, "only the newest line is replayed");

    eprintln!("streamed {} lines before the turn ended", lines.len());
    let _ = std::fs::remove_dir_all(&data_dir);
}
