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
    process_tree: Option<ProcessTreeGuard>,
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

#[cfg(windows)]
struct ProcessTreeGuard {
    handle: usize,
}

#[cfg(not(windows))]
struct ProcessTreeGuard;

#[cfg(windows)]
impl ProcessTreeGuard {
    fn attach(child: &Child) -> std::io::Result<Self> {
        use std::mem::size_of;
        use std::os::windows::io::AsRawHandle;
        use std::ptr;
        use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
        use windows_sys::Win32::System::JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
            SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        };

        unsafe {
            let handle = CreateJobObjectW(ptr::null(), ptr::null());
            if handle.is_null() {
                return Err(std::io::Error::last_os_error());
            }

            let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if SetInformationJobObject(
                handle,
                JobObjectExtendedLimitInformation,
                &limits as *const _ as *const std::ffi::c_void,
                size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            ) == 0
            {
                let error = std::io::Error::last_os_error();
                CloseHandle(handle);
                return Err(error);
            }
            if AssignProcessToJobObject(handle, child.as_raw_handle() as HANDLE) == 0 {
                let error = std::io::Error::last_os_error();
                CloseHandle(handle);
                return Err(error);
            }
            Ok(Self {
                handle: handle as usize,
            })
        }
    }

    fn terminate(&self) {
        use windows_sys::Win32::Foundation::HANDLE;
        use windows_sys::Win32::System::JobObjects::TerminateJobObject;

        unsafe {
            TerminateJobObject(self.handle as HANDLE, 1);
        }
    }
}

#[cfg(windows)]
impl Drop for ProcessTreeGuard {
    fn drop(&mut self) {
        use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};

        unsafe {
            CloseHandle(self.handle as HANDLE);
        }
    }
}

#[cfg(not(windows))]
impl ProcessTreeGuard {
    fn attach(_child: &Child) -> std::io::Result<Self> {
        Ok(Self)
    }

    fn terminate(&self) {}
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
        let process_tree = match ProcessTreeGuard::attach(&child) {
            Ok(tree) => tree,
            Err(err) => {
                let _ = kill_and_wait(&mut child, None);
                return Err(format!("failed to supervise process tree: {err}"));
            }
        };

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
            process_tree: Some(process_tree),
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
                        let process_tree = job.process_tree.take();
                        let status = kill_and_wait(&mut job.child, process_tree);
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

        let process_tree = job.process_tree.take();
        let status = kill_and_wait(&mut job.child, process_tree);
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

fn kill_and_wait(child: &mut Child, process_tree: Option<ProcessTreeGuard>) -> Option<ExitStatus> {
    if let Some(process_tree) = process_tree {
        process_tree.terminate();
    }
    match child.kill() {
        Ok(()) => {}
        Err(err) if err.kind() == ErrorKind::InvalidInput => {}
        Err(_) => {}
    }
    child.wait().ok()
}

fn finish_job(job: &mut Job, status: Option<ExitStatus>, timed_out: bool, cancelled: bool) {
    if let Some(process_tree) = job.process_tree.take() {
        process_tree.terminate();
    }
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
