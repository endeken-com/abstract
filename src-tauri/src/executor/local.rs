use super::*;
use crate::error::{Error, Result};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;

pub struct LocalExecutor;

impl LocalExecutor {
    pub fn new() -> Self {
        LocalExecutor
    }
}

#[async_trait]
impl Executor for LocalExecutor {
    fn kind(&self) -> ExecutorKind {
        ExecutorKind::Local
    }

    async fn exec(&self, cmd: &str, args: &[String], cwd: Option<&str>) -> Result<ExecOutput> {
        let mut c = Command::new(cmd);
        c.args(args);
        if let Some(d) = cwd {
            c.current_dir(d);
        }
        // Keep git quiet and scriptable.
        c.env("GIT_TERMINAL_PROMPT", "0");
        let out = c.output().await?;
        Ok(ExecOutput {
            code: out.status.code().unwrap_or(-1),
            stdout: String::from_utf8_lossy(&out.stdout).to_string(),
            stderr: String::from_utf8_lossy(&out.stderr).to_string(),
        })
    }

    async fn spawn_stream(
        &self,
        spec: LaunchSpec,
        on_line: LineSink,
        on_exit: ExitSink,
    ) -> Result<ProcHandle> {
        let mut c = Command::new(&spec.command);
        c.args(&spec.args)
            .current_dir(&spec.cwd)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(false);
        for (k, v) in &spec.env {
            c.env(k, v);
        }
        let mut child = c.spawn().map_err(|e| {
            Error::msg(format!("failed to spawn `{}`: {e}", spec.command))
        })?;
        let pid = child.id();

        let stdout = child.stdout.take().ok_or_else(|| Error::msg("no stdout"))?;
        let stderr = child.stderr.take().ok_or_else(|| Error::msg("no stderr"))?;
        let mut stdin = child.stdin.take().ok_or_else(|| Error::msg("no stdin"))?;

        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();
        if let Some(initial) = spec.stdin_initial.clone() {
            let _ = tx.send(initial);
        }
        let keep_open = spec.keep_stdin_open;
        tokio::spawn(async move {
            while let Some(data) = rx.recv().await {
                if stdin.write_all(data.as_bytes()).await.is_err() {
                    break;
                }
                let _ = stdin.flush().await;
                if !keep_open {
                    break;
                }
            }
            // Dropping stdin closes it, which is what non-interactive agents need.
            drop(stdin);
        });

        for (reader, name) in [
            (Box::new(stdout) as Box<dyn tokio::io::AsyncRead + Unpin + Send>, "stdout"),
            (Box::new(stderr) as Box<dyn tokio::io::AsyncRead + Unpin + Send>, "stderr"),
        ] {
            let sink = on_line.clone();
            tokio::spawn(async move {
                let mut lines = BufReader::new(reader).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    sink(ProcLine {
                        stream: name.to_string(),
                        line,
                    });
                }
            });
        }

        let kill_pid = pid;
        let handle = ProcHandle {
            stdin: Some(tx),
            pid,
            kill: Box::new(move || {
                if let Some(p) = kill_pid {
                    // SIGTERM first; the wait task below reports the exit.
                    unsafe {
                        libc_kill(p as i32, 15);
                    }
                }
            }),
        };

        tokio::spawn(async move {
            let status = child.wait().await.ok();
            on_exit(status.and_then(|s| s.code()));
        });

        Ok(handle)
    }

    async fn read_file(&self, path: &str) -> Result<String> {
        Ok(tokio::fs::read_to_string(path).await?)
    }

    async fn exists(&self, path: &str) -> Result<bool> {
        Ok(tokio::fs::try_exists(path).await.unwrap_or(false))
    }

    async fn home(&self) -> Result<String> {
        dirs::home_dir()
            .map(|p| p.to_string_lossy().to_string())
            .ok_or_else(|| Error::msg("no home directory"))
    }

    async fn mkdir_p(&self, path: &str) -> Result<()> {
        tokio::fs::create_dir_all(path).await?;
        Ok(())
    }

    async fn remove_dir_all(&self, path: &str) -> Result<()> {
        match tokio::fs::remove_dir_all(path).await {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.into()),
        }
    }
}

extern "C" {
    #[link_name = "kill"]
    fn libc_kill(pid: i32, sig: i32) -> i32;
}
