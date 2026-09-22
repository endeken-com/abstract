pub mod local;

use crate::error::Result;
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum ExecutorKind {
    Local,
    Ssh { host: String },
}

/// What to spawn. Built by a provider definition on the frontend, or by the
/// scheduler for automations; the core never inspects the contents.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LaunchSpec {
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
    pub cwd: String,
    #[serde(default)]
    pub env: HashMap<String, String>,
    #[serde(default)]
    pub stdin_initial: Option<String>,
    #[serde(default)]
    pub keep_stdin_open: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct ExecOutput {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

impl ExecOutput {
    pub fn ok(&self) -> bool {
        self.code == 0
    }
    pub fn require(self, what: &str) -> Result<Self> {
        if self.ok() {
            Ok(self)
        } else {
            Err(crate::error::Error::Command {
                code: self.code,
                stderr: format!("{what}: {}", self.stderr.trim()),
            })
        }
    }
}

/// One raw line of agent output, relayed verbatim to the frontend parser.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcLine {
    pub stream: String,
    pub line: String,
}

pub type LineSink = Arc<dyn Fn(ProcLine) + Send + Sync>;
pub type ExitSink = Arc<dyn Fn(Option<i32>) + Send + Sync>;

/// Handle on a running agent process.
pub struct ProcHandle {
    pub stdin: Option<tokio::sync::mpsc::UnboundedSender<String>>,
    pub kill: Box<dyn Fn() + Send + Sync>,
    pub pid: Option<u32>,
}

#[async_trait]
pub trait Executor: Send + Sync {
    fn kind(&self) -> ExecutorKind;

    async fn exec(&self, cmd: &str, args: &[String], cwd: Option<&str>) -> Result<ExecOutput>;

    async fn spawn_stream(
        &self,
        spec: LaunchSpec,
        on_line: LineSink,
        on_exit: ExitSink,
    ) -> Result<ProcHandle>;

    async fn read_file(&self, path: &str) -> Result<String>;
    async fn exists(&self, path: &str) -> Result<bool>;
    async fn home(&self) -> Result<String>;
    async fn mkdir_p(&self, path: &str) -> Result<()>;
    async fn remove_dir_all(&self, path: &str) -> Result<()>;

    /// Resolve a binary on this host's PATH; returns its path when present.
    async fn which(&self, binary: &str) -> Result<Option<String>> {
        let out = self
            .exec("sh", &["-lc".into(), format!("command -v {binary}")], None)
            .await?;
        Ok(if out.ok() {
            let p = out.stdout.trim().to_string();
            if p.is_empty() {
                None
            } else {
                Some(p)
            }
        } else {
            None
        })
    }
}

pub fn git_args(args: &[&str]) -> Vec<String> {
    args.iter().map(|s| s.to_string()).collect()
}
