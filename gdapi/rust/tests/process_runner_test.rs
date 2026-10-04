use gdapi::process_runner::{PollOutcome, ProcessRunnerCore};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .canonicalize()
        .expect("repo root should exist")
}

fn fixture_tool(name: &str) -> PathBuf {
    repo_root()
        .join("tests")
        .join("fixtures")
        .join("m6_project")
        .join("tools")
        .join(name)
}

fn python_executable() -> String {
    std::env::var("PYTHON").unwrap_or_else(|_| "python".to_string())
}

fn wait_for_terminal(
    runner: &mut ProcessRunnerCore,
    id: i64,
    timeout: Duration,
) -> gdapi::process_runner::TerminalProcessResult {
    let started = Instant::now();
    loop {
        match runner.poll(id) {
            PollOutcome::Running => {
                assert!(
                    started.elapsed() < timeout,
                    "job {id} did not finish within {:?}",
                    timeout
                );
                thread::sleep(Duration::from_millis(20));
            }
            PollOutcome::Done(result) => return result,
            PollOutcome::Missing => panic!("job {id} disappeared before terminal result"),
        }
    }
}

#[test]
fn process_runner_preserves_arguments_without_shell_expansion() {
    let mut runner = ProcessRunnerCore::new();
    let script = fixture_tool("echo_args.py");
    let cwd = repo_root();
    let id = runner
        .start(
            &python_executable(),
            &[
                script.display().to_string(),
                "literal;value".to_string(),
                "$(not-run)".to_string(),
                "space value".to_string(),
                "*.gd".to_string(),
            ],
            &cwd,
            2_000,
            65_536,
        )
        .expect("spawn should succeed");

    let result = wait_for_terminal(&mut runner, id, Duration::from_secs(5));
    assert_eq!(result.exit_code, Some(0));
    assert!(!result.timed_out);
    assert!(!result.cancelled);
    assert!(result.stdout.contains("\"literal;value\""));
    assert!(result.stdout.contains("\"$(not-run)\""));
    assert!(result.stdout.contains("\"space value\""));
    assert!(result.stdout.contains("\"*.gd\""));
    assert!(!result.truncated);
    assert!(matches!(runner.poll(id), PollOutcome::Missing));
}

#[test]
fn process_runner_kills_and_reaps_after_timeout() {
    let mut runner = ProcessRunnerCore::new();
    let script = fixture_tool("sleep.py");
    let cwd = repo_root();
    let started = Instant::now();
    let id = runner
        .start(
            &python_executable(),
            &[script.display().to_string(), "5000".to_string()],
            &cwd,
            150,
            8_192,
        )
        .expect("spawn should succeed");

    let result = wait_for_terminal(&mut runner, id, Duration::from_secs(5));
    assert!(result.timed_out);
    assert!(!result.cancelled);
    assert!(started.elapsed() < Duration::from_secs(2));
    assert!(matches!(runner.poll(id), PollOutcome::Missing));
}

#[test]
fn process_runner_caps_combined_output() {
    let mut runner = ProcessRunnerCore::new();
    let script = fixture_tool("emit_output.py");
    let cwd = repo_root();
    let id = runner
        .start(
            &python_executable(),
            &[
                script.display().to_string(),
                "6000".to_string(),
                "6000".to_string(),
            ],
            &cwd,
            2_000,
            1_024,
        )
        .expect("spawn should succeed");

    let result = wait_for_terminal(&mut runner, id, Duration::from_secs(5));
    assert_eq!(result.exit_code, Some(0));
    assert!(result.truncated);
    assert!(result.stdout.len() + result.stderr.len() <= 1_024);
}

#[test]
fn process_runner_cancel_returns_terminal_result_once() {
    let mut runner = ProcessRunnerCore::new();
    let script = fixture_tool("sleep.py");
    let cwd = repo_root();
    let id = runner
        .start(
            &python_executable(),
            &[script.display().to_string(), "5000".to_string()],
            &cwd,
            2_000,
            8_192,
        )
        .expect("spawn should succeed");

    assert!(runner.cancel(id));
    let result = wait_for_terminal(&mut runner, id, Duration::from_secs(5));
    assert!(result.cancelled);
    assert!(!result.timed_out);
    assert!(matches!(runner.poll(id), PollOutcome::Missing));
}

struct TreeFixture {
    directory: PathBuf,
    ready: PathBuf,
    marker: PathBuf,
}

impl TreeFixture {
    fn new() -> Self {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory =
            std::env::temp_dir().join(format!("gdapi-process-{}-{unique}", std::process::id()));
        std::fs::create_dir(&directory).unwrap();
        Self {
            ready: directory.join("ready"),
            marker: directory.join("late-marker"),
            directory,
        }
    }

    fn start(&self, runner: &ProcessRunnerCore, mode: &str, timeout_ms: i64) -> i64 {
        runner
            .start(
                &python_executable(),
                &[
                    fixture_tool("process_tree.py").display().to_string(),
                    mode.to_string(),
                    self.ready.display().to_string(),
                    self.marker.display().to_string(),
                ],
                &repo_root(),
                timeout_ms,
                8192,
            )
            .expect("tree process should start")
    }

    fn wait_ready(&self) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !self.ready.exists() {
            assert!(
                Instant::now() < deadline,
                "descendant never held the output pipes"
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn assert_no_late_side_effect(&self, ready_at: Instant) {
        thread::sleep(
            (ready_at + Duration::from_millis(3300)).saturating_duration_since(Instant::now()),
        );
        assert!(
            !self.marker.exists(),
            "a descendant survived terminal cleanup"
        );
    }
}

impl Drop for TreeFixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

#[test]
fn process_tree_natural_completion_closes_inherited_stdout_and_stderr() {
    let fixture = TreeFixture::new();
    let mut runner = ProcessRunnerCore::new();
    let id = fixture.start(&runner, "exit", 5000);
    fixture.wait_ready();
    let ready_at = Instant::now();
    let result = wait_for_terminal(&mut runner, id, Duration::from_secs(1));
    assert!(
        ready_at.elapsed() < Duration::from_secs(1),
        "output readers blocked on descendants"
    );
    assert_eq!(result.exit_code, Some(0));
    assert!(!result.timed_out && !result.cancelled);
    assert!(result.stdout.contains("descendant stdout") && result.stdout.contains("parent stdout"));
    assert!(result.stderr.contains("descendant stderr") && result.stderr.contains("parent stderr"));
    fixture.assert_no_late_side_effect(ready_at);
}

#[test]
fn process_tree_timeout_cleans_descendants_holding_both_pipes() {
    let fixture = TreeFixture::new();
    let mut runner = ProcessRunnerCore::new();
    let started = Instant::now();
    let id = fixture.start(&runner, "wait", 2000);
    fixture.wait_ready();
    let ready_at = Instant::now();
    let result = wait_for_terminal(&mut runner, id, Duration::from_secs(3));
    assert!(result.timed_out && !result.cancelled);
    assert!(
        started.elapsed() < Duration::from_millis(2700),
        "timeout waited for pipe descendants"
    );
    assert!(result.stdout.contains("descendant stdout"));
    assert!(result.stderr.contains("descendant stderr"));
    fixture.assert_no_late_side_effect(ready_at);
}

#[test]
fn process_timeout_is_enforced_without_polling() {
    let fixture = TreeFixture::new();
    let runner = ProcessRunnerCore::new();
    let started = Instant::now();
    let request = gdapi::queue::RequestControl::new(Instant::now() + Duration::from_secs(10));
    let id = runner
        .start_for_request(
            &python_executable(),
            &[
                fixture_tool("process_tree.py").display().to_string(),
                "wait".to_string(),
                fixture.ready.display().to_string(),
                fixture.marker.display().to_string(),
            ],
            &repo_root(),
            2000,
            8192,
            request,
        )
        .expect("tree process should start");
    fixture.wait_ready();
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "descendant was not ready before the process deadline"
    );

    // Do not poll while the descendant's delayed marker write becomes due.
    thread::sleep(Duration::from_millis(3400));
    assert!(
        !fixture.marker.exists(),
        "descendant performed a side effect after the process deadline"
    );

    let polled_at = Instant::now();
    let result = match runner.poll(id) {
        PollOutcome::Done(result) => result,
        PollOutcome::Running => panic!("deadline supervisor left the process running"),
        PollOutcome::Missing => panic!("process result disappeared before polling"),
    };
    assert!(
        polled_at.elapsed() < Duration::from_secs(1),
        "poll hung after timeout"
    );
    assert!(result.timed_out && !result.cancelled);
    assert_eq!(
        runner.poll(id),
        PollOutcome::Missing,
        "terminal result was delivered twice"
    );
}

#[test]
fn process_tree_cancel_cleans_descendants_holding_both_pipes() {
    let fixture = TreeFixture::new();
    let mut runner = ProcessRunnerCore::new();
    let id = fixture.start(&runner, "wait", 5000);
    fixture.wait_ready();
    let ready_at = Instant::now();
    assert!(runner.cancel(id));
    assert!(
        ready_at.elapsed() < Duration::from_secs(1),
        "cancel waited for pipe descendants"
    );
    let result = wait_for_terminal(&mut runner, id, Duration::from_secs(1));
    assert!(result.cancelled && !result.timed_out);
    assert!(result.stdout.contains("descendant stdout"));
    assert!(result.stderr.contains("descendant stderr"));
    fixture.assert_no_late_side_effect(ready_at);
}

#[cfg(windows)]
#[test]
fn windows_suspended_spawn_contains_fast_descendant_on_timeout() {
    let fixture = TreeFixture::new();
    let mut runner = ProcessRunnerCore::new();
    let id = fixture.start(&runner, "wait", 2000);
    fixture.wait_ready();
    let ready_at = Instant::now();
    let result = wait_for_terminal(&mut runner, id, Duration::from_secs(3));
    assert!(result.timed_out && !result.cancelled);
    fixture.assert_no_late_side_effect(ready_at);
}

#[test]
fn process_tree_drop_cleans_running_descendants_and_output_readers() {
    let fixture = TreeFixture::new();
    let runner = ProcessRunnerCore::new();
    fixture.start(&runner, "wait", 5000);
    fixture.wait_ready();
    let ready_at = Instant::now();
    drop(runner);
    assert!(
        ready_at.elapsed() < Duration::from_secs(1),
        "drop waited for pipe descendants"
    );
    fixture.assert_no_late_side_effect(ready_at);
}

#[test]
fn cancelled_request_rejects_spawn_without_any_process_side_effect() {
    let fixture = TreeFixture::new();
    let request = gdapi::queue::RequestControl::new(Instant::now() + Duration::from_secs(5));
    request.cancel(gdapi::queue::CancelReason::Disconnected);
    let runner = ProcessRunnerCore::new();
    let error = runner
        .start_for_request(
            &python_executable(),
            &[
                "-c".into(),
                "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('started')".into(),
                fixture.marker.display().to_string(),
            ],
            &repo_root(),
            5000,
            8192,
            request,
        )
        .expect_err("cancelled request must never spawn its executable");
    assert!(error.contains("request cancelled"));
    assert!(!fixture.marker.exists());
}
