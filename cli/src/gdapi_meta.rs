//! gdapi 元数据读取。
//!
//! 本模块负责读取和解析 `.godot/gdapi.json` 文件，该文件由 gdapi Godot 插件
//! 在运行时生成，包含 HTTP 服务器端口、LSP 端口等运行时信息。
//!
//! 文件格式示例：
//! ```json
//! {
//!   "http_port": 8080,
//!   "lsp_port": 6005,
//!   "pid": 12345,
//!   "gdapi_version": "0.2.0"
//! }
//! ```

use anyhow::{anyhow, Result};
use serde::Deserialize;
use std::path::Path;

/// gdapi 运行时元数据结构体。
///
/// 对应 `.godot/gdapi.json` 文件的 JSON 结构。
/// 由 gdapi Godot 插件在启动 HTTP 服务器时写入。
#[derive(Debug, Deserialize)]
pub struct GdApiMeta {
    /// gdapi HTTP 服务器监听端口（必填）
    pub http_port: u16,
    /// Godot LSP 服务器端口（可选，默认 6005）
    #[serde(default)]
    pub lsp_port: Option<u16>,
    /// gdapi 插件进程 ID（可选，用于调试）
    #[allow(dead_code)]
    pub pid: Option<u32>,
    /// gdapi 插件版本号（可选）
    #[allow(dead_code)]
    #[serde(default)]
    pub gdapi_version: Option<String>,
    /// 认证 token（可选，空或 None 表示不校验）
    #[serde(default)]
    pub token: Option<String>,
}

/// 读取并解析 gdapi 元数据文件。
///
/// 从 `<project_root>/.godot/gdapi.json` 读取 JSON 并反序列化为 `GdApiMeta`。
///
/// # Arguments
/// * `project_root` - Godot 项目根目录路径
///
/// # Returns
/// 解析后的 `GdApiMeta` 结构体
///
/// # Errors
/// - 文件不存在或无法读取
/// - JSON 格式错误或字段缺失
pub fn read(project_root: &Path) -> Result<GdApiMeta> {
    let p = project_root.join(".godot").join("gdapi.json");
    let s = std::fs::read_to_string(&p)
        .map_err(|e| anyhow!("cannot read {}: {}", p.display(), e))?;
    serde_json::from_str(&s).map_err(|e| anyhow!("parse {}: {}", p.display(), e))
}
