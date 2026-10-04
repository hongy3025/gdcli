use crate::queue::{CancelReason, RequestControl};
use std::collections::HashMap;
use std::io::{ErrorKind, Read};
use std::path::Path;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
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
    jobs: Arc<Mutex<HashMap<i64, Arc<Mutex<Job>>>>>,
}

struct Job {
    child: Child,
    process_tree: Option<ProcessTreeGuard>,
    stdout_thread: Option<JoinHandle<()>>,
    stderr_thread: Option<JoinHandle<()>>,
    output: Arc<Mutex<SharedOutput>>,
    stop_readers: Arc<AtomicBool>,
    deadline: Instant,
    deadline_signal: Arc<DeadlineSignal>,
    finished: Option<TerminalProcessResult>,
    delivered: bool,
}

struct DeadlineSignal {
    finished: Mutex<bool>,
    wake: Condvar,
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

#[cfg(unix)]
struct ProcessTreeGuard {
    group_id: libc::pid_t,
}

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
fn resume_suspended_child(process_id: u32) -> std::io::Result<()> {
    use std::mem::{size_of, zeroed};
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE};

    #[repr(C)]
    struct ThreadEntry32 {
        size: u32,
        usage: u32,
        thread_id: u32,
        owner_process_id: u32,
        base_priority: i32,
        delta_priority: i32,
        flags: u32,
    }

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn CreateToolhelp32Snapshot(flags: u32, process_id: u32) -> HANDLE;
        fn Thread32First(snapshot: HANDLE, entry: *mut ThreadEntry32) -> i32;
        fn Thread32Next(snapshot: HANDLE, entry: *mut ThreadEntry32) -> i32;
        fn OpenThread(access: u32, inherit: i32, thread_id: u32) -> HANDLE;
        fn ResumeThread(thread: HANDLE) -> u32;
    }

    const TH32CS_SNAPTHREAD: u32 = 0x0000_0004;
    const THREAD_SUSPEND_RESUME: u32 = 0x0002;
    const INVALID_RESUME_COUNT: u32 = u32::MAX;

    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
        if snapshot == INVALID_HANDLE_VALUE {
            return Err(std::io::Error::last_os_error());
        }
        let mut entry: ThreadEntry32 = zeroed();
        entry.size = size_of::<ThreadEntry32>() as u32;
        let mut found = None;
        let mut has_entry = Thread32First(snapshot, &mut entry) != 0;
        while has_entry {
            if entry.owner_process_id == process_id {
                let thread = OpenThread(THREAD_SUSPEND_RESUME, 0, entry.thread_id);
                if !thread.is_null() {
                    found = Some(thread);
                    break;
                }
            }
            has_entry = Thread32Next(snapshot, &mut entry) != 0;
        }
        CloseHandle(snapshot);

        let Some(thread) = found else {
            return Err(std::io::Error::last_os_error());
        };
        let result = ResumeThread(thread);
        let error = (result == INVALID_RESUME_COUNT).then(std::io::Error::last_os_error);
        CloseHandle(thread);
        error.map_or(Ok(()), Err)
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

#[cfg(unix)]
impl ProcessTreeGuard {
    fn attach(child: &Child) -> std::io::Result<Self> {
        Ok(Self {
            group_id: child.id() as libc::pid_t,
        })
    }

    fn terminate(mut self) {
        // process_group(0) is applied before exec, so descendants never race
        // attachment and inherit this independent group from their first instruction.
        unsafe {
            libc::kill(-self.group_id, libc::SIGKILL);
        }
        self.group_id = 0;
    }
}

#[cfg(unix)]
impl Drop for ProcessTreeGuard {
    fn drop(&mut self) {
        if self.group_id != 0 {
            unsafe {
                libc::kill(-self.group_id, libc::SIGKILL);
            }
        }
    }
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
        self.start_inner(executable, args, cwd, timeout_ms, max_output_bytes, None)
    }

    pub fn start_for_request(
        &self,
        executable: &str,
        args: &[String],
        cwd: &Path,
        timeout_ms: i64,
        max_output_bytes: i64,
        request: Arc<RequestControl>,
    ) -> Result<i64, String> {
        request.run_if_active(|| {
            let id = self.start_inner(
                executable,
                args,
                cwd,
                timeout_ms,
                max_output_bytes,
                Some(Arc::clone(&request)),
            )?;
            let jobs = Arc::downgrade(&self.jobs);
            Ok((
                id,
                Box::new(move |reason| {
                    if let Some(jobs) = jobs.upgrade() {
                        let job = jobs
                            .lock()
                            .expect("process runner job lock poisoned")
                            .get(&id)
                            .cloned();
                        if let Some(job) = job {
                            cancel_job(
                                &mut job.lock().expect("process job lock poisoned"),
                                reason == CancelReason::Timeout,
                            );
                        }
                    }
                }),
            ))
        })
    }

    fn start_inner(
        &self,
        executable: &str,
        args: &[String],
        cwd: &Path,
        timeout_ms: i64,
        max_output_bytes: i64,
        request: Option<Arc<RequestControl>>,
    ) -> Result<i64, String> {
        if timeout_ms <= 0 {
            return Err("timeout_ms must be positive".to_string());
        }
        if max_output_bytes <= 0 {
            return Err("max_output_bytes must be positive".to_string());
        }

        let started = Instant::now();
        let deadline = started + Duration::from_millis(timeout_ms as u64);
        let deadline = request
            .as_ref()
            .map_or(deadline, |control| deadline.min(control.deadline));
        if request
            .as_ref()
            .is_some_and(|control| control.reason().is_some())
            || deadline <= started
        {
            return Err("request cancelled before process start".to_string());
        }
        let exe = resolve_executable(cwd, executable);
        let mut command = Command::new(&exe);
        command
            .args(args)
            .current_dir(cwd)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.process_group(0);
        }
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            // CREATE_SUSPENDED prevents user code (and descendants) from running
            // until after Job Object assignment succeeds.
            command.creation_flags(0x0000_0004);
        }
        let mut child = command
            .spawn()
            .map_err(|err| format!("spawn failed: {err}"))?;
        let process_tree = match ProcessTreeGuard::attach(&child) {
            Ok(tree) => tree,
            Err(err) => {
                let _ = kill_and_wait(&mut child, None);
                return Err(format!("failed to supervise process tree: {err}"));
            }
        };
        #[cfg(windows)]
        if let Err(err) = resume_suspended_child(child.id()) {
            let _ = kill_and_wait(&mut child, Some(process_tree));
            return Err(format!("failed to resume supervised process: {err}"));
        }

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
        if let Err(error) = stdout.prepare().and_then(|()| stderr.prepare()) {
            let _ = kill_and_wait(&mut child, Some(process_tree));
            return Err(format!("failed to configure process output: {error}"));
        }
        let stop_readers = Arc::new(AtomicBool::new(false));
        let deadline_signal = Arc::new(DeadlineSignal {
            finished: Mutex::new(false),
            wake: Condvar::new(),
        });

        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let job = Arc::new(Mutex::new(Job {
            child,
            process_tree: Some(process_tree),
            stdout_thread: Some(spawn_output_reader(
                stdout,
                OutputStream::Stdout,
                Arc::clone(&output),
                Arc::clone(&stop_readers),
            )),
            stderr_thread: Some(spawn_output_reader(
                stderr,
                OutputStream::Stderr,
                Arc::clone(&output),
                Arc::clone(&stop_readers),
            )),
            output,
            stop_readers,
            deadline,
            deadline_signal: Arc::clone(&deadline_signal),
            finished: None,
            delivered: false,
        }));

        self.jobs
            .lock()
            .expect("process runner job lock poisoned")
            .insert(id, Arc::clone(&job));

        let jobs = Arc::downgrade(&self.jobs);
        let supervisor = thread::Builder::new()
            .name(format!("process-deadline-{id}"))
            .spawn(move || supervise_deadline(jobs, id, deadline, deadline_signal));
        if let Err(error) = supervisor {
            self.jobs
                .lock()
                .expect("process runner job lock poisoned")
                .remove(&id);
            cancel_job(&mut job.lock().expect("process job lock poisoned"), false);
            return Err(format!(
                "failed to start process deadline supervisor: {error}"
            ));
        }
        Ok(id)
    }

    pub fn poll(&self, id: i64) -> PollOutcome {
        let Some(job) = self
            .jobs
            .lock()
            .expect("process runner job lock poisoned")
            .get(&id)
            .cloned()
        else {
            return PollOutcome::Missing;
        };
        let mut job = job.lock().expect("process job lock poisoned");
        if job.delivered {
            return PollOutcome::Missing;
        }
        if job.finished.is_none() && !try_finish_natural(&mut job) && Instant::now() >= job.deadline
        {
            let process_tree = job.process_tree.take();
            let status = kill_and_wait(&mut job.child, process_tree);
            finish_job(&mut job, status, true, false);
        }
        let Some(result) = job.finished.take() else {
            return PollOutcome::Running;
        };
        job.delivered = true;
        drop(job);
        self.jobs
            .lock()
            .expect("process runner job lock poisoned")
            .remove(&id);
        PollOutcome::Done(result)
    }

    pub fn cancel(&self, id: i64) -> bool {
        let Some(job) = self
            .jobs
            .lock()
            .expect("process runner job lock poisoned")
            .get(&id)
            .cloned()
        else {
            return false;
        };
        let mut job = job.lock().expect("process job lock poisoned");
        if job.finished.is_some() || job.delivered {
            return false;
        }

        cancel_job(&mut job, false);
        true
    }
}

impl Drop for ProcessRunnerCore {
    fn drop(&mut self) {
        let jobs = self
            .jobs
            .lock()
            .expect("process runner job lock poisoned")
            .drain()
            .map(|(_, job)| job)
            .collect::<Vec<_>>();
        for job in jobs {
            cancel_job(&mut job.lock().expect("process job lock poisoned"), false);
        }
    }
}

fn cancel_job(job: &mut Job, timed_out: bool) {
    if job.finished.is_some() || job.delivered {
        return;
    }
    let process_tree = job.process_tree.take();
    let status = kill_and_wait(&mut job.child, process_tree);
    finish_job(job, status, timed_out, !timed_out);
}

trait OutputPipe: Read + Send {
    fn prepare(&self) -> std::io::Result<()>;
    fn read_available(&mut self, buffer: &mut [u8]) -> std::io::Result<usize>;
}

#[cfg(unix)]
impl<R: Read + Send + std::os::fd::AsRawFd> OutputPipe for R {
    fn prepare(&self) -> std::io::Result<()> {
        let fd = self.as_raw_fd();
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(())
    }

    fn read_available(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        self.read(buffer)
    }
}

#[cfg(windows)]
impl<R: Read + Send + std::os::windows::io::AsRawHandle> OutputPipe for R {
    fn prepare(&self) -> std::io::Result<()> {
        Ok(())
    }

    fn read_available(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        use windows_sys::Win32::System::Pipes::PeekNamedPipe;
        let mut available = 0;
        let ok = unsafe {
            PeekNamedPipe(
                self.as_raw_handle(),
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                &mut available,
                std::ptr::null_mut(),
            )
        };
        if ok == 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == ErrorKind::BrokenPipe {
                return Ok(0);
            }
            return Err(error);
        }
        if available == 0 {
            return Err(std::io::Error::from(ErrorKind::WouldBlock));
        }
        let count = buffer.len().min(available as usize);
        self.read(&mut buffer[..count])
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
    stop: Arc<AtomicBool>,
) -> JoinHandle<()>
where
    R: OutputPipe + 'static,
{
    thread::spawn(move || {
        let mut buf = [0u8; 4096];
        let mut stop_deadline = None;
        loop {
            if stop.load(Ordering::Acquire) {
                let deadline = *stop_deadline
                    .get_or_insert_with(|| Instant::now() + Duration::from_millis(100));
                if Instant::now() >= deadline {
                    break;
                }
            }
            match reader.read_available(&mut buf) {
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
                Err(err) if err.kind() == ErrorKind::WouldBlock => {
                    if stop.load(Ordering::Acquire) {
                        break;
                    }
                    thread::sleep(Duration::from_millis(5));
                }
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

fn decode_output(bytes: Vec<u8>) -> String {
    match String::from_utf8(bytes) {
        Ok(output) => output,
        Err(error) => String::from_utf8_lossy(error.as_bytes()).into_owned(),
    }
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

fn supervise_deadline(
    jobs: std::sync::Weak<Mutex<HashMap<i64, Arc<Mutex<Job>>>>>,
    id: i64,
    deadline: Instant,
    signal: Arc<DeadlineSignal>,
) {
    let mut finished = signal
        .finished
        .lock()
        .expect("process deadline signal lock poisoned");
    while !*finished {
        let now = Instant::now();
        if now >= deadline {
            break;
        }
        let (next, _) = signal
            .wake
            .wait_timeout(finished, deadline.saturating_duration_since(now))
            .expect("process deadline signal lock poisoned");
        finished = next;
    }
    if *finished {
        return;
    }
    drop(finished);

    let Some(jobs) = jobs.upgrade() else {
        return;
    };
    let job = jobs
        .lock()
        .expect("process runner job lock poisoned")
        .get(&id)
        .cloned();
    let Some(job) = job else {
        return;
    };
    let mut job = job.lock().expect("process job lock poisoned");
    if job.delivered || job.finished.is_some() || try_finish_natural(&mut job) {
        return;
    }
    let process_tree = job.process_tree.take();
    let status = kill_and_wait(&mut job.child, process_tree);
    finish_job(&mut job, status, true, false);
}

fn try_finish_natural(job: &mut Job) -> bool {
    #[cfg(unix)]
    {
        match child_has_exited_without_reaping(&job.child) {
            Ok(true) => {
                terminate_process_tree(job);
                let status = job.child.wait().ok();
                finish_job(job, status, false, false);
                true
            }
            Ok(false) | Err(_) => false,
        }
    }

    #[cfg(windows)]
    {
        if let Ok(Some(status)) = job.child.try_wait() {
            finish_job(job, Some(status), false, false);
            true
        } else {
            false
        }
    }
}

#[cfg(unix)]
fn child_has_exited_without_reaping(child: &Child) -> std::io::Result<bool> {
    loop {
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                child.id() as libc::id_t,
                &mut info,
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        };
        if result == 0 {
            return Ok(info.si_signo != 0);
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

fn terminate_process_tree(job: &mut Job) {
    if let Some(process_tree) = job.process_tree.take() {
        process_tree.terminate();
    }
}

fn finish_job(job: &mut Job, status: Option<ExitStatus>, timed_out: bool, cancelled: bool) {
    terminate_process_tree(job);
    {
        let mut finished = job
            .deadline_signal
            .finished
            .lock()
            .expect("process deadline signal lock poisoned");
        *finished = true;
        job.deadline_signal.wake.notify_one();
    }
    job.stop_readers.store(true, Ordering::Release);
    if let Some(handle) = job.stdout_thread.take() {
        let _ = handle.join();
    }
    if let Some(handle) = job.stderr_thread.take() {
        let _ = handle.join();
    }

    let mut shared = job.output.lock().expect("process output lock poisoned");
    job.finished = Some(TerminalProcessResult {
        exit_code: status.and_then(|exit| exit.code()),
        timed_out,
        cancelled,
        stdout: decode_output(std::mem::take(&mut shared.stdout)),
        stderr: decode_output(std::mem::take(&mut shared.stderr)),
        truncated: shared.truncated,
    });
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
