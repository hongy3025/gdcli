//! gdcli exec — 通过 HTTP 调用 gdapi 路由。
//!
//! 本模块实现了 `gdcli exec` 命令，用于向运行中的 Godot 项目发送 HTTP 请求。
//! 核心流程：
//!   1. 从 `.godot/gdapi.json` 读取 gdapi 元数据（HTTP 端口等）
//!   2. 解析用户提供的请求数据（字面 JSON、@文件路径或 stdin）
//!   3. 构造 HTTP POST 请求并发送到 gdapi 服务器
//!   4. 根据响应状态码返回对应的退出码
//!
//! 退出码约定：
//!   - 0: 成功（2xx 响应）
//!   - 1: 服务器错误（5xx 响应）
//!   - 2: 客户端错误（4xx 响应或参数错误）
//!   - 3: 网络错误、超时或元数据缺失

use anyhow::{anyhow, Result};
use std::io::Read;
use std::path::Path;
use std::time::Duration;

use crate::gdapi_meta;

/// 执行 gdapi exec 命令的主入口函数。
///
/// 从项目元数据中获取 HTTP 端口，构造请求并发送，返回进程退出码。
///
/// # Arguments
/// * `project` - Godot 项目根目录路径
/// * `command` - gdapi 路由命令名（如 "spawn"、"query" 等）
/// * `data` - 可选的请求数据，支持三种格式：
///   - `None`: 使用空 JSON 对象 `{}`
///   - `Some("-")`: 从 stdin 读取
///   - `Some("@path")`: 从文件读取
///   - `Some(json_str)`: 直接使用字面 JSON 字符串
/// * `timeout_secs` - HTTP 请求超时时间（秒）
///
/// # Returns
/// 进程退出码（0=成功, 1=5xx, 2=4xx/参数错, 3=网络/超时/meta 缺失）
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

/// 解析用户提供的请求数据。
///
/// 支持多种数据来源格式：
/// - `None`: 返回空（调用方使用默认空 JSON）
/// - `Some("-")`: 从标准输入读取
/// - `Some("@filepath")`: 从指定文件读取
/// - `Some(string)`: 直接使用字符串
///
/// # Arguments
/// * `data` - 用户输入的数据参数
///
/// # Returns
/// 解析后的字符串，或 None 表示使用默认值
///
/// # Errors
/// 文件读取失败或 stdin 读取失败时返回错误
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

/// HTTP 响应体最大读取字节数（16MB）。
///
/// 防止服务器返回过大响应导致内存溢出。
const MAX_RESPONSE_BYTES: u64 = 16 * 1024 * 1024;

/// 读取 HTTP 响应体内容。
///
/// 限制最大读取字节数为 MAX_RESPONSE_BYTES，防止内存溢出。
///
/// # Arguments
/// * `resp` - HTTP 响应对象
///
/// # Returns
/// 响应体字符串
///
/// # Errors
/// IO 错误或响应体超过大小限制
fn read_body(resp: ureq::Response) -> Result<String> {
    let mut s = String::new();
    resp.into_reader().take(MAX_RESPONSE_BYTES).read_to_string(&mut s)?;
    Ok(s)
}

/// 根据 HTTP 状态码映射到进程退出码。
///
/// 退出码约定：
/// - 0: 成功（2xx 且非错误）
/// - 2: 客户端错误（4xx）
/// - 1: 服务器错误（5xx 或其他）
///
/// # Arguments
/// * `status` - HTTP 状态码
/// * `is_error` - 是否为错误响应（ureq 的 Status 错误）
///
/// # Returns
/// 对应的进程退出码
fn map_status_to_exit(status: u16, is_error: bool) -> i32 {
    if !is_error && (200..300).contains(&status) {
        0
    } else if (400..500).contains(&status) {
        2
    } else {
        1
    }
}
