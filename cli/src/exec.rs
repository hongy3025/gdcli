//! gdcli exec — 调用 Godot 编辑器命令。
//!
//! 本模块实现了 `gdcli exec` 命令，用于向运行中的 Godot 编辑器发送请求。
//! 核心流程：
//!   1. 从 `.godot/gdapi.json` 读取元数据（端口等）
//!   2. 解析用户提供的请求数据（字面 JSON、@文件路径或 stdin）
//!   3. 构造 POST 请求并发送到 Godot 编辑器
//!   4. 根据响应状态码返回对应的退出码
//!
//! 退出码约定：
//!   - 0: 成功（2xx 响应）
//!   - 1: 服务器错误（5xx 响应）
//!   - 2: 客户端错误（4xx 响应或参数错误）
//!   - 3: 网络错误、超时或元数据缺失

use anyhow::{anyhow, Result};
use std::borrow::Cow;
use std::io::Read;
use std::path::Path;
use std::time::Duration;

use crate::format;
use crate::gdapi_meta;

/// 从项目元数据中获取端口，构造请求并发送，返回进程退出码。
///
/// # 参数
///
/// * `project` - Godot 项目根目录路径
/// * `command` - 命令名（如 "gdapi/health/ping"、"scene/create" 等）
/// * `args` - 位置参数（`command/doc <route>` 使用：待查询路由路径）
/// * `data` - 可选的请求数据（JSON 字符串、@文件路径或 "-" 表示 stdin）
/// * `timeout_secs` - 请求超时时间（秒）
/// * `json_mode` - 是否以原始 JSON 格式输出（默认 TOON 格式）
pub fn run(
    project: &Path,
    command: &str,
    args: &[String],
    data: Option<&str>,
    timeout_secs: u64,
    json_mode: bool,
) -> Result<i32> {
    // 1. 读 .godot/gdapi.json
    let meta = match gdapi_meta::read(project) {
        Ok(m) => m,
        Err(e) => {
            eprintln!(
                "Godot 编辑器未响应: {}\n提示：请在 Godot 编辑器中打开项目并启用 gdapi 插件，或先运行 'gdcli install'",
                e
            );
            return Ok(3);
        }
    };

    // 2. 准备请求 body（含 `command/doc` 命令的位置参数处理）
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

    let mut request = agent.post(&url).set("content-type", "application/json");

    // 添加 token header
    if let Some(ref token) = meta.token {
        if !token.is_empty() {
            request = request.set("Authorization", &format!("Bearer {}", token));
        }
    }

    let resp = request.send_string(&body_text);

    match resp {
        Ok(r) => {
            let status = r.status();
            let body = read_body(r)?;
            if json_mode {
                let reordered = format::reorder_ok_json(&body);
                print!("{}", reordered);
            } else {
                let rendered = match command {
                    "command/list" => format::clap_style::render_commands(&body),
                    "command/doc" => format::clap_style::render_command_help(&body),
                    _ => format::render_exec_body(&body),
                };
                print!("{}", rendered);
                if !rendered.ends_with('\n') {
                    println!();
                }
            }
            Ok(map_status_to_exit(status, false))
        }
        Err(ureq::Error::Status(code, r)) => {
            let body = read_body(r)?;
            let rendered: Cow<'_, str> = if json_mode {
                format::reorder_ok_json(&body)
            } else {
                format::render_exec_body(&body)
            };
            eprintln!("Error ({}): {}", code, rendered.trim_end());
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
/// 调用方根据变体决定行为：Body 用作请求体；
/// Reject 输出错误信息并以退出码 2 终止。
pub(crate) enum BuildBodyOutcome {
    /// 构造好的 JSON 字符串，可直接发送
    Body(String),
    /// 构造前置校验失败，msg 已包含给用户的解释
    Reject(String),
}

/// 构造请求体。
///
/// 调用方根据变体决定行为：Body 用作请求体；
/// Reject 输出错误信息并以退出码 2 终止。
///
/// # 参数
///
/// * `command` - 命令名
/// * `args` - 位置参数（`command/doc <route>` 使用：待查询路由路径）
/// * `data` - 可选的用户提供的请求数据
///
/// # 特殊命令
///
/// * `command/list` — 返回空 body，拒绝 `--data` 和位置参数
/// * `command/doc <path>` — 以 `{"command": "<path>"}` 为 body，拒绝 `--data`，要求恰好 1 个位置参数
/// * 其它命令（如 `gdapi/health/ping`、`scene/create`） — 使用 `--data` 或空 `{}`，拒绝位置参数
pub(crate) fn build_body(
    command: &str,
    args: &[String],
    data: Option<&str>,
) -> Result<BuildBodyOutcome> {
    // command/list 命令：无参数，返回所有命令列表
    if command == "command/list" {
        if !args.is_empty() {
            return Ok(BuildBodyOutcome::Reject(format!(
                "'command/list' does not accept arguments, got {:?}",
                args
            )));
        }
        if data.is_some() {
            return Ok(BuildBodyOutcome::Reject(
                "'command/list' does not accept --data".to_string(),
            ));
        }
        return Ok(BuildBodyOutcome::Body("{}".to_string()));
    }

    // command/doc 命令：需要一个位置参数作为命令路径
    if command == "command/doc" {
        if data.is_some() {
            return Ok(BuildBodyOutcome::Reject(
                "'command/doc' does not accept --data; use positional argument instead".to_string(),
            ));
        }
        if args.len() != 1 {
            return Ok(BuildBodyOutcome::Reject(format!(
                "'command/doc' requires exactly one argument (command path), got {}: {:?}",
                args.len(),
                args
            )));
        }
        let body = serde_json::json!({ "command": &args[0] }).to_string();
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

/// 响应体最大读取字节数（16MB）。
///
/// 防止服务器返回过大响应导致内存溢出。
const MAX_RESPONSE_BYTES: u64 = 16 * 1024 * 1024;

/// 读取响应体内容。
///
/// 限制最大读取字节数为 MAX_RESPONSE_BYTES，防止内存溢出。
///
/// # Arguments
/// * `resp` - 响应对象
///
/// # Returns
/// 响应体字符串
///
/// # Errors
/// IO 错误或响应体超过大小限制
fn read_body(resp: ureq::Response) -> Result<String> {
    let mut s = String::new();
    resp.into_reader()
        .take(MAX_RESPONSE_BYTES)
        .read_to_string(&mut s)?;
    Ok(s)
}

/// 根据状态码映射到进程退出码。
///
/// 退出码约定：
/// - 0: 成功（2xx 且非错误）
/// - 2: 客户端错误（4xx）
/// - 1: 服务器错误（5xx 或其他）
///
/// # Arguments
/// * `status` - 状态码
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
    fn non_help_with_extra_positional_is_rejected() {
        let out = build_body("ping", &args(&["unexpected"]), None).unwrap();
        match out {
            BuildBodyOutcome::Reject(m) => assert!(
                m.contains("positional"),
                "msg should mention positional: {}",
                m
            ),
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

    #[test]
    fn commands_no_args_no_data_yields_empty_object() {
        let out = build_body("command/list", &[], None).unwrap();
        match out {
            BuildBodyOutcome::Body(s) => assert_eq!(s, "{}"),
            BuildBodyOutcome::Reject(m) => panic!("unexpected reject: {}", m),
        }
    }

    #[test]
    fn commands_with_args_is_rejected() {
        let out = build_body("command/list", &args(&["unexpected"]), None).unwrap();
        match out {
            BuildBodyOutcome::Reject(m) => {
                assert!(
                    m.contains("arguments"),
                    "msg should mention arguments: {}",
                    m
                )
            }
            BuildBodyOutcome::Body(_) => panic!("should reject"),
        }
    }

    #[test]
    fn commands_with_data_is_rejected() {
        let out = build_body("command/list", &[], Some("{}")).unwrap();
        match out {
            BuildBodyOutcome::Reject(m) => {
                assert!(m.contains("--data"), "msg should mention --data: {}", m)
            }
            BuildBodyOutcome::Body(_) => panic!("should reject"),
        }
    }

    #[test]
    fn command_help_with_arg_builds_command_object() {
        let out = build_body("command/doc", &args(&["godot/version"]), None).unwrap();
        match out {
            BuildBodyOutcome::Body(s) => assert_eq!(s, r#"{"command":"godot/version"}"#),
            BuildBodyOutcome::Reject(m) => panic!("unexpected reject: {}", m),
        }
    }

    #[test]
    fn command_help_without_arg_is_rejected() {
        let out = build_body("command/doc", &[], None).unwrap();
        match out {
            BuildBodyOutcome::Reject(m) => {
                assert!(m.contains("requires"), "msg should mention requires: {}", m)
            }
            BuildBodyOutcome::Body(_) => panic!("should reject"),
        }
    }

    #[test]
    fn command_help_with_multiple_args_is_rejected() {
        let out = build_body("command/doc", &args(&["a", "b"]), None).unwrap();
        match out {
            BuildBodyOutcome::Reject(m) => {
                assert!(
                    m.contains("exactly one"),
                    "msg should mention exactly one: {}",
                    m
                )
            }
            BuildBodyOutcome::Body(_) => panic!("should reject"),
        }
    }

    #[test]
    fn command_help_with_data_is_rejected() {
        let out = build_body("command/doc", &args(&["godot/version"]), Some("{}")).unwrap();
        match out {
            BuildBodyOutcome::Reject(m) => {
                assert!(m.contains("--data"), "msg should mention --data: {}", m)
            }
            BuildBodyOutcome::Body(_) => panic!("should reject"),
        }
    }
}
