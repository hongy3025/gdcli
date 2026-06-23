//! gdcli exec — 通过 HTTP 调用 gdapi 路由。

use anyhow::{anyhow, Result};
use std::io::Read;
use std::path::Path;
use std::time::Duration;

use crate::gdapi_meta;

/// 退出码：0=成功, 1=5xx, 2=4xx/参数错, 3=网络/超时/meta 缺失
pub fn run(
    project: &Path,
    command: &str,
    data: Option<&str>,
    timeout_secs: u64,
) -> Result<i32> {
    // 1. 读 .godot/gdapi.json
    let meta = match gdapi_meta::read(project) {
        Ok(m) => m,
        Err(e) => {
            eprintln!(
                "gdapi not running: {}\nHint: open the project in Godot editor with gdapi plugin enabled, or run 'gdcli install' first.",
                e
            );
            return Ok(3);
        }
    };

    // 2. 准备请求 body
    let body_text = match resolve_data(data)? {
        Some(t) => t,
        None => "{}".to_string(),
    };
    // 客户端先验证 JSON 合法性
    if let Err(e) = serde_json::from_str::<serde_json::Value>(&body_text) {
        eprintln!("invalid JSON in --data: {}", e);
        return Ok(2);
    }

    // 3. 构造 URL
    let path = command.trim_start_matches('/');
    let url = format!("http://127.0.0.1:{}/{}", meta.http_port, path);

    // 4. 发请求
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(timeout_secs))
        .build();

    let resp = agent
        .post(&url)
        .set("content-type", "application/json")
        .send_string(&body_text);

    match resp {
        Ok(r) => {
            let status = r.status();
            let body = read_body(r)?;
            print!("{}", body);
            Ok(map_status_to_exit(status, false))
        }
        Err(ureq::Error::Status(code, r)) => {
            let body = read_body(r)?;
            eprintln!("Error (HTTP {}): {}", code, body.trim());
            Ok(map_status_to_exit(code, true))
        }
        Err(ureq::Error::Transport(t)) => {
            eprintln!("network error: {}", t);
            Ok(3)
        }
    }
}

fn resolve_data(data: Option<&str>) -> Result<Option<String>> {
    match data {
        None => Ok(None),
        Some("-") => {
            let mut s = String::new();
            std::io::stdin().read_to_string(&mut s)?;
            Ok(Some(s))
        }
        Some(d) if d.starts_with('@') => {
            let path = &d[1..];
            let s = std::fs::read_to_string(path)
                .map_err(|e| anyhow!("cannot read {}: {}", path, e))?;
            Ok(Some(s))
        }
        Some(d) => Ok(Some(d.to_string())),
    }
}

const MAX_RESPONSE_BYTES: u64 = 16 * 1024 * 1024;

fn read_body(resp: ureq::Response) -> Result<String> {
    let mut s = String::new();
    resp.into_reader().take(MAX_RESPONSE_BYTES).read_to_string(&mut s)?;
    Ok(s)
}

fn map_status_to_exit(status: u16, is_error: bool) -> i32 {
    if !is_error && (200..300).contains(&status) {
        0
    } else if (400..500).contains(&status) {
        2
    } else if (500..600).contains(&status) {
        1
    } else {
        1
    }
}
