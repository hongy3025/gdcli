use anyhow::Result;
use std::path::Path;

pub fn run(_project: &Path, _command: &str, _data: Option<&str>, _timeout_secs: u64) -> Result<i32> {
    anyhow::bail!("exec not yet implemented")
}
