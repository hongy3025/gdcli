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
    args: &[String],
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

    // 2. 准备请求 body（含 help 命令的位置参数特殊处理）
    let body_text = match build_body(command, args, data)? {
        BuildBodyOutcome::Body(t) => t,
        BuildBodyOutcome::Reject(msg) => {
            eprintln!("{}", msg);
            return Ok(2);
        }
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

/// build_body 的输出。
///
/// 调用方根据变体决定行为：Body 用作 HTTP 请求体；
/// Reject 表示构造前置校验失败，调用方打印 msg 到 stderr 后退出 2。
pub(crate) enum BuildBodyOutcome {
    /// 构造好的 JSON 字符串，可直接发送
    Body(String),
    /// 构造前置校验失败，msg 已包含给用户的解释
    Reject(String),
}

/// 根据 command/args/data 构造请求体。
///
/// 规则：
/// - command == "help": 必须无 --data；位置参数最多一个作为 path
///   - 无位置参数 → "{}"
///   - 一个位置参数 → {"path": "<arg>"}
///   - 多个位置参数 → Reject
/// - 其他 command: 位置参数必须为空，否则 Reject；body 来自 resolve_data
///   - 无 --data → "{}"
///   - 有 --data → resolve_data 解析（字面 JSON / @file / stdin）
///
/// # Arguments
/// * `command` - 路由命令名
/// * `args` - 位置参数数组
/// * `data` - --data 参数原始值
///
/// # Returns
/// BuildBodyOutcome::Body 或 BuildBodyOutcome::Reject
///
/// # Errors
/// resolve_data 失败（文件读取/stdin 错误）时返回 Err
pub(crate) fn build_body(
    command: &str,
    args: &[String],
    data: Option<&str>,
) -> Result<BuildBodyOutcome> {
    if command == "help" {
        if data.is_some() {
            return Ok(BuildBodyOutcome::Reject(
                "'help' command does not accept --data; use positional path argument instead".to_string(),
            ));
        }
        if args.len() > 1 {
            return Ok(BuildBodyOutcome::Reject(format!(
                "'help' accepts at most one positional path argument, got {}: {:?}",
                args.len(),
                args
            )));
        }
        let body = match args.first() {
            Some(path) => serde_json::json!({ "path": path }).to_string(),
            None => "{}".to_string(),
        };
        return Ok(BuildBodyOutcome::Body(body));
    }

    if !args.is_empty() {
        return Ok(BuildBodyOutcome::Reject(format!(
            "unexpected positional arguments for '{}': {:?}",
            command, args
        )));
    }
    let body = match resolve_data(data)? {
        Some(t) => t,
        None => "{}".to_string(),
    };
    Ok(BuildBodyOutcome::Body(body))
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

#[cfg(test)]
mod build_body_tests {
    use super::*;

    fn args(vs: &[&str]) -> Vec<String> {
        vs.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn help_no_args_no_data_yields_empty_object() {
        let out = build_body("help", &[], None).unwrap();
        match out {
            BuildBodyOutcome::Body(s) => assert_eq!(s, "{}"),
            BuildBodyOutcome::Reject(m) => panic!("unexpected reject: {}", m),
        }
    }

    #[test]
    fn help_with_path_arg_builds_path_object() {
        let out = build_body("help", &args(&["editor/scene/save"]), None).unwrap();
        match out {
            BuildBodyOutcome::Body(s) => assert_eq!(s, r#"{"path":"editor/scene/save"}"#),
            BuildBodyOutcome::Reject(m) => panic!("unexpected reject: {}", m),
        }
    }

    #[test]
    fn help_with_path_containing_quotes_escapes_safely() {
        let out = build_body("help", &args(&[r#"weird"name"#]), None).unwrap();
        match out {
            BuildBodyOutcome::Body(s) => {
                let v: serde_json::Value = serde_json::from_str(&s).unwrap();
                assert_eq!(v["path"], r#"weird"name"#);
            }
            BuildBodyOutcome::Reject(m) => panic!("unexpected reject: {}", m),
        }
    }

    #[test]
    fn help_with_data_is_rejected() {
        let out = build_body("help", &[], Some("{}")).unwrap();
        match out {
            BuildBodyOutcome::Reject(m) => assert!(m.contains("--data"), "msg should mention --data: {}", m),
            BuildBodyOutcome::Body(_) => panic!("should reject"),
        }
    }

    #[test]
    fn non_help_with_extra_positional_is_rejected() {
        let out = build_body("ping", &args(&["unexpected"]), None).unwrap();
        match out {
            BuildBodyOutcome::Reject(m) => assert!(m.contains("positional"), "msg should mention positional: {}", m),
            BuildBodyOutcome::Body(_) => panic!("should reject"),
        }
    }

    #[test]
    fn non_help_with_data_passes_through() {
        let out = build_body("foo", &[], Some(r#"{"x":1}"#)).unwrap();
        match out {
            BuildBodyOutcome::Body(s) => assert_eq!(s, r#"{"x":1}"#),
            BuildBodyOutcome::Reject(m) => panic!("unexpected reject: {}", m),
        }
    }

    #[test]
    fn non_help_no_args_no_data_yields_empty_object() {
        let out = build_body("ping", &[], None).unwrap();
        match out {
            BuildBodyOutcome::Body(s) => assert_eq!(s, "{}"),
            BuildBodyOutcome::Reject(m) => panic!("unexpected reject: {}", m),
        }
    }
}
