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
