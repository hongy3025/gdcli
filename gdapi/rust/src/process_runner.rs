use std::collections::HashMap;
use std::io::{ErrorKind, Read};
use std::path::Path;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalProcessResult {
    pub exit_code: Option<i32>,
    pub timed_out: bool,
    pub cancelled: bool,
    pub stdout: String,
    pub stderr: String,
    pub truncated: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PollOutcome {
    Running,
    Done(TerminalProcessResult),
    Missing,
}

pub struct ProcessRunnerCore {
    next_id: AtomicI64,
    jobs: Arc<Mutex<HashMap<i64, Job>>>,
}

struct Job {
    child: Child,
    stdout_thread: Option<JoinHandle<()>>,
    stderr_thread: Option<JoinHandle<()>>,
    output: Arc<Mutex<SharedOutput>>,
    deadline: Instant,
    finished: Option<TerminalProcessResult>,
    terminal_delivered: bool,
}

struct SharedOutput {
    remaining_bytes: usize,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    truncated: bool,
}

enum OutputStream {
    Stdout,
    Stderr,
}

impl ProcessRunnerCore {
    pub fn new() -> Self {
        Self {
            next_id: AtomicI64::new(1),
            jobs: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn start(
        &self,
        executable: &str,
        args: &[String],
        cwd: &Path,
        timeout_ms: i64,
        max_output_bytes: i64,
    ) -> Result<i64, String> {
        if timeout_ms <= 0 {
            return Err("timeout_ms must be positive".to_string());
        }
        if max_output_bytes <= 0 {
            return Err("max_output_bytes must be positive".to_string());
        }

        let exe = resolve_executable(cwd, executable);
        let mut child = Command::new(&exe)
            .args(args)
            .current_dir(cwd)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|err| format!("spawn failed: {err}"))?;

        let output = Arc::new(Mutex::new(SharedOutput {
            remaining_bytes: max_output_bytes as usize,
            stdout: Vec::new(),
            stderr: Vec::new(),
            truncated: false,
        }));

        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "child stdout pipe missing".to_string())?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| "child stderr pipe missing".to_string())?;

        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let job = Job {
            child,
            stdout_thread: Some(spawn_output_reader(
                stdout,
                OutputStream::Stdout,
                Arc::clone(&output),
            )),
            stderr_thread: Some(spawn_output_reader(
                stderr,
                OutputStream::Stderr,
                Arc::clone(&output),
            )),
            output,
            deadline: Instant::now() + Duration::from_millis(timeout_ms as u64),
            finished: None,
            terminal_delivered: false,
        };

        self.jobs
            .lock()
            .expect("process runner job lock poisoned")
            .insert(id, job);
        Ok(id)
    }

    pub fn poll(&self, id: i64) -> PollOutcome {
        let mut jobs = self.jobs.lock().expect("process runner job lock poisoned");
        let mut remove_after_poll = false;
        let outcome = match jobs.get_mut(&id) {
            None => PollOutcome::Missing,
            Some(job) => {
                if job.finished.is_none() {
                    if Instant::now() >= job.deadline {
                        let status = kill_and_wait(&mut job.child);
                        finish_job(job, status, true, false);
                    } else if let Ok(Some(status)) = job.child.try_wait() {
                        finish_job(job, Some(status), false, false);
                    }
                }

                match &job.finished {
                    Some(result) if !job.terminal_delivered => {
                        job.terminal_delivered = true;
                        PollOutcome::Done(result.clone())
                    }
                    Some(_) => {
                        remove_after_poll = true;
                        PollOutcome::Missing
                    }
                    None => PollOutcome::Running,
                }
            }
        };

        if remove_after_poll {
            jobs.remove(&id);
        }

        outcome
    }

    pub fn cancel(&self, id: i64) -> bool {
        let mut jobs = self.jobs.lock().expect("process runner job lock poisoned");
        let Some(job) = jobs.get_mut(&id) else {
            return false;
        };
        if job.finished.is_some() {
            return false;
        }

        let status = kill_and_wait(&mut job.child);
        finish_job(job, status, false, true);
        true
    }
}

impl Default for ProcessRunnerCore {
    fn default() -> Self {
        Self::new()
    }
}

fn spawn_output_reader<R>(
    mut reader: R,
    stream: OutputStream,
    output: Arc<Mutex<SharedOutput>>,
) -> JoinHandle<()>
where
    R: Read + Send + 'static,
{
    thread::spawn(move || {
        let mut buf = [0u8; 4096];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    let mut shared = output.lock().expect("process output lock poisoned");
                    let allowed = shared.remaining_bytes.min(n);
                    if allowed > 0 {
                        match stream {
                            OutputStream::Stdout => {
                                shared.stdout.extend_from_slice(&buf[..allowed]);
                            }
                            OutputStream::Stderr => {
                                shared.stderr.extend_from_slice(&buf[..allowed]);
                            }
                        }
                        shared.remaining_bytes -= allowed;
                    }
                    if allowed < n {
                        shared.truncated = true;
                    }
                }
                Err(err) if err.kind() == ErrorKind::Interrupted => continue,
                Err(_) => break,
            }
        }
    })
}

fn kill_and_wait(child: &mut Child) -> Option<ExitStatus> {
    match child.kill() {
        Ok(()) => {}
        Err(err) if err.kind() == ErrorKind::InvalidInput => {}
        Err(_) => {}
    }
    child.wait().ok()
}

fn finish_job(job: &mut Job, status: Option<ExitStatus>, timed_out: bool, cancelled: bool) {
    if let Some(handle) = job.stdout_thread.take() {
        let _ = handle.join();
    }
    if let Some(handle) = job.stderr_thread.take() {
        let _ = handle.join();
    }

    let shared = job.output.lock().expect("process output lock poisoned");
    job.finished = Some(TerminalProcessResult {
        exit_code: status.and_then(|exit| exit.code()),
        timed_out,
        cancelled,
        stdout: String::from_utf8_lossy(&shared.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&shared.stderr).into_owned(),
        truncated: shared.truncated,
    });
}

fn resolve_executable(cwd: &Path, executable: &str) -> String {
    let direct = cwd.join(executable);
    if direct.exists() {
        return direct.to_string_lossy().to_string();
    }
    let exts = [".exe", ".com", ".bat", ".cmd"];
    for ext in &exts {
        let candidate = cwd.join(format!("{executable}{ext}"));
        if candidate.exists() {
            return candidate.to_string_lossy().to_string();
        }
    }
    executable.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn cwd() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
    }

    #[test]
    fn rejects_nonpositive_timeout_before_spawn() {
        let runner = ProcessRunnerCore::new();
        let err = runner
            .start("python", &[], &cwd(), 0, 1024)
            .expect_err("nonpositive timeout should be rejected");
        assert!(err.contains("timeout_ms"));
    }

    #[test]
    fn rejects_nonpositive_output_cap_before_spawn() {
        let runner = ProcessRunnerCore::new();
        let err = runner
            .start("python", &[], &cwd(), 1000, 0)
            .expect_err("nonpositive cap should be rejected");
        assert!(err.contains("max_output_bytes"));
    }
}
