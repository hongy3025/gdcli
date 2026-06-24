//! main.rs — gdcli 命令行工具入口
//!
//! 【这个文件的作用】
//! gdcli 是一个与 Godot 内置 LSP 服务器交互的命令行工具。
//! 本文件负责：
//!   - 解析命令行参数（clap）
//!   - 建立 LSP 连接
//!   - 根据子命令分发到对应的处理函数
//!   - 格式化并输出结果（人类可读或 JSON 模式）
//!
//! 【运行方式示例】
//!   gdcli --port 6005 rename player.gd:10:5 new_name
//!   gdcli --port 6005 --json references player.gd:Player.health
//!   gdcli --port 6005 diagnostics
//!
//! 【async fn main 说明】
//! Rust 标准库的 main 不能是 async 的。
//! #[tokio::main] 宏会把 main 包装成同步入口，内部启动 tokio 运行时来执行 async 代码。

// ==================== 版本号常量（由 build.rs 自动生成） ====================

include!(concat!(env!("OUT_DIR"), "/version.rs"));

// ==================== 模块声明与导入 ====================

mod commands;
mod embedded_addon;
mod exec;
mod format;
mod gdapi_meta;
mod install;
mod lsp;
mod project;

use anyhow::Result;
use clap::{Parser, Subcommand};
use lsp::client::GodotLspClient;
use std::path::{Path, PathBuf};

// ==================== 命令行参数定义 ====================

/// 【Cli — 命令行参数结构体】
///
/// 【#[derive(Parser)] 说明】
/// clap 宏：根据结构体定义自动生成命令行解析逻辑。
/// 字段上的属性（如 #[arg(long)]）控制参数名称、默认值、作用域等。
///
/// 【#[command(...)] 说明】
/// 设置命令行程序的名称、版本、描述信息。
/// version 会自动从 Cargo.toml 读取。
#[derive(Parser)]
#[command(name = "gdcli", version, about = "CLI for Godot's built-in LSP")]
struct Cli {
    /// LSP 服务器主机地址，默认本地回环
    #[arg(long, default_value = "127.0.0.1", global = true)]
    host: String,
    /// LSP 服务器端口（默认从 .godot/gdapi.json 读取，或 6005）
    #[arg(long, global = true)]
    port: Option<u16>,
    /// Godot 项目根目录路径（用于解析相对路径和初始化 LSP）
    #[arg(long, global = true)]
    project: Option<PathBuf>,
    /// 以 JSON 格式输出结果（便于脚本处理）
    #[arg(long, global = true)]
    json: bool,
    /// 子命令（枚举类型，见下方 Cmd）
    #[command(subcommand)]
    cmd: Cmd,
}

/// 【LspCmd — LSP 子命令枚举】
///
/// 通过 `gdcli lsp <subcommand>` 访问。
/// 这些命令需要连接 Godot LSP 服务器。
#[derive(Subcommand)]
enum LspCmd {
    /// 重命名符号：gdcli lsp rename <target> <new_name>
    Rename { target: String, new_name: String },
    /// 查找引用：gdcli lsp references <target>
    References { target: String },
    /// 跳转到定义：gdcli lsp definition <target>
    Definition { target: String },
    /// 跳转到声明：gdcli lsp declaration <target>
    Declaration { target: String },
    /// 列出文件中的符号：gdcli lsp symbols <file>
    Symbols { file: PathBuf },
    /// 获取悬浮提示：gdcli lsp hover <target>
    Hover { target: String },
    /// 查询 Godot 原生类文档（Godot LSP 扩展）
    #[command(name = "native-symbol")]
    NativeSymbol {
        #[arg(long, conflicts_with = "full")]
        members: bool,
        #[arg(long, conflicts_with = "members")]
        full: bool,
        class: String,
        member: Option<String>,
    },
    /// 获取诊断信息（编译错误/警告）
    Diagnostics { file: Option<PathBuf> },
    /// 查询服务器能力列表
    Capabilities,
}

/// 【Cmd — 支持的子命令枚举】
///
/// 【#[derive(Subcommand)] 说明】
/// clap 宏：把枚举的每个变体变成一个 CLI 子命令。
/// 变体上的属性控制命令名称、参数等。
#[derive(Subcommand)]
enum Cmd {
    /// 与 Godot LSP 服务器交互：gdcli lsp <subcommand>
    Lsp {
        #[command(subcommand)]
        sub: LspCmd,
    },
    /// 检查与 LSP 服务器的连接状态
    Status,
    /// 在目标项目安装编辑器插件
    Install {
        /// 覆盖已有安装
        #[arg(long)]
        force: bool,
        /// 不修改 project.godot 启用插件
        #[arg(long)]
        no_enable: bool,
    },
    /// 调用 Godot 编辑器命令
    #[command(after_help = "示例:\n  gdcli exec ping                         # 健康检查\n  gdcli exec commands                     # 列出所有命令\n  gdcli exec command-help godot/version   # 查看命令详情\n  gdcli exec scene/create --data '{\"scene_path\":\"new.tscn\"}'  # 创建场景")]
    Exec {
        /// 命令名
        command: String,
        /// 位置参数（command-help 使用：命令路径）
        args: Vec<String>,
        /// 请求 JSON 数据（字面 JSON、@file 或 - 表示 stdin）
        #[arg(long)]
        data: Option<String>,
        /// 请求超时秒数
        #[arg(long, default_value_t = 30)]
        timeout: u64,
    },
}

// ==================== 路径解析工具 ====================

/// 把用户输入的文件路径解析为绝对路径。
///
/// 优先级：
///   1. 如果已经是绝对路径，直接返回
///   2. 如果提供了 --project，基于项目目录拼接
///   3. 否则基于当前工作目录拼接
pub(crate) fn resolve_file(file: &Path, project: Option<&Path>) -> PathBuf {
    // 剥离 res:// 前缀（Godot 资源协议）
    let file = match file.to_str() {
        Some(s) if s.starts_with("res://") => Path::new(&s[6..]),
        _ => file,
    };
    if file.is_absolute() {
        return file.to_path_buf();
    }
    if let Some(p) = project {
        return p.join(file);
    }
    std::env::current_dir()
        .map(|c| c.join(file))
        .unwrap_or_else(|_| file.to_path_buf())
}

// ==================== 目标解析 ====================

/// 【TargetMode — 用户输入的目标定位方式】
///
/// gdcli 支持两种方式来指定"操作哪个符号"：
///   - Position：file:line:col（传统的行列号格式）
///   - SymbolPath：file:Class.member（符号路径格式，更直观）
pub(crate) enum TargetMode {
    Position {
        file: PathBuf,
        line: u32,
        col: u32,
    },
    SymbolPath {
        symbol_path: lsp::symbol_path::SymbolPath,
    },
}

/// 解析用户输入的 target 字符串。
///
/// 【解析逻辑】
/// 1. 用 `:` 分割字符串
/// 2. 如果最后两段都能解析为数字，说明是 line:col 格式
///    前面的部分（可能含多个冒号，如 C:\foo）拼起来作为文件路径
/// 3. 否则尝试按 SymbolPath 解析
///
/// 【_project 前缀下划线说明】
/// 参数名以 _ 开头表示"当前未使用但保留用于未来扩展"，
/// 编译器不会报 unused 警告。
pub(crate) fn parse_target(target: &str, _project: Option<&Path>) -> Result<TargetMode> {
    let parts: Vec<&str> = target.split(':').collect();

    // 至少要有 3 段才可能是 file:line:col（因为 line 和 col 各一段）
    if parts.len() >= 3 {
        let last_two = &parts[parts.len() - 2..];
        // 尝试把最后两段解析为 u32
        if let (Ok(line), Ok(col)) = (last_two[0].parse::<u32>(), last_two[1].parse::<u32>()) {
            // 前面的所有段用 : 重新拼起来作为文件路径
            let file_raw = parts[..parts.len() - 2].join(":");
            // 剥离 res:// 前缀（Godot 资源协议），得到实际文件路径
            let file = file_raw.strip_prefix("res://").unwrap_or(&file_raw);
            // 用户输入 1-based，转为 LSP 的 0-based；行号和列号必须 >= 1
            if line == 0 || col == 0 {
                return Err(anyhow::anyhow!(
                    "Line and column numbers are 1-based and must be >= 1, got {}:{}",
                    line,
                    col
                ));
            }
            return Ok(TargetMode::Position {
                file: PathBuf::from(file),
                line: line - 1,
                col: col - 1,
            });
        }
    }

    // 不是行列号格式，尝试符号路径
    if lsp::symbol_path::SymbolPath::is_symbol_path(target) {
        let sp = lsp::symbol_path::SymbolPath::parse(target).map_err(|e| anyhow::anyhow!(e))?;
        Ok(TargetMode::SymbolPath { symbol_path: sp })
    } else {
        Err(anyhow::anyhow!(
            "Invalid target format. Expected 'file:line:col' or 'file:SymbolPath'"
        ))
    }
}

// ==================== 程序入口 ====================

#[tokio::main]
async fn main() {
    if let Err(e) = run().await {
        eprintln!("{}", e);
        std::process::exit(1);
    }
}

/// 发现 LSP 端口。
///
/// 优先级：
/// 1. --port 显式指定
/// 2. .godot/gdapi.json 的 lsp_port 字段
/// 3. 默认 6005
fn discover_lsp_port(explicit_port: Option<u16>, project_root: Option<&Path>) -> u16 {
    // 1. 显式指定
    if let Some(p) = explicit_port {
        return p;
    }

    // 2. 从 .godot/gdapi.json 读取
    if let Some(root) = project_root {
        if let Ok(meta) = gdapi_meta::read(root) {
            if let Some(lsp_port) = meta.lsp_port {
                return lsp_port;
            }
        }
    }

    // 3. 默认值
    6005
}

/// 主运行逻辑。
///
/// 【流程】
/// 1. 解析命令行参数
/// 2. Status 命令特殊处理（连接失败也不 panic）
/// 3. 连接 LSP 服务器
/// 4. 根据子命令分发处理
/// 5. 断开连接并返回结果
async fn run() -> Result<()> {
    let cli = Cli::parse();
    let project = cli.project.as_deref();

    match cli.cmd {
        Cmd::Install { force, no_enable } => {
            let project_root =
                project::resolve_project_root(project).map_err(|e| anyhow::anyhow!(e))?;
            install::run(install::InstallArgs {
                project_root,
                force,
                no_enable,
            })?;
        }
        Cmd::Exec {
            ref command,
            ref args,
            ref data,
            timeout,
        } => {
            let project_root =
                project::resolve_project_root(project).map_err(|e| anyhow::anyhow!(e))?;
            let code = exec::run(
                &project_root,
                command,
                args,
                data.as_deref(),
                timeout,
                cli.json,
            )?;
            std::process::exit(code);
        }
        Cmd::Status => {
            let project_root = project::resolve_project_root(project).ok();
            let lsp_port = discover_lsp_port(cli.port, project_root.as_deref());
            return commands::lsp::handle_status_command(
                &cli.host,
                lsp_port,
                project_root.as_deref(),
                cli.json,
            )
            .await;
        }
        Cmd::Lsp { ref sub } => {
            let project_root = project::resolve_project_root(project).ok();
            let lsp_port = discover_lsp_port(cli.port, project_root.as_deref());

            let client = match GodotLspClient::connect(&cli.host, lsp_port, project).await {
                Ok(c) => c,
                Err(_) => {
                    eprintln!(
                        "Failed to connect to Godot LSP at {}:{}",
                        cli.host, lsp_port
                    );
                    eprintln!(
                        "Make sure Godot is running with: godot --editor --headless --lsp-port {} --path /your/project",
                        lsp_port
                    );
                    std::process::exit(1);
                }
            };

            let result: Result<()> = async {
                match sub {
                    LspCmd::Capabilities => {
                        let caps = client.server_capabilities().await;
                        println!("{}", serde_json::to_string_pretty(&caps)?);
                    }
                    LspCmd::Rename { target, new_name } => {
                        commands::lsp::handle_rename_command(
                            &client, target, new_name, project, cli.json,
                        )
                        .await?;
                    }
                    LspCmd::References { target } => {
                        commands::lsp::handle_references_command(
                            &client, target, project, cli.json,
                        )
                        .await?;
                    }
                    LspCmd::Definition { target } => {
                        commands::lsp::handle_definition_command(
                            &client, target, project, cli.json,
                        )
                        .await?;
                    }
                    LspCmd::Declaration { target } => {
                        commands::lsp::handle_declaration_command(
                            &client, target, project, cli.json,
                        )
                        .await?;
                    }
                    LspCmd::Symbols { file } => {
                        commands::lsp::handle_symbols_command(&client, file, project, cli.json)
                            .await?;
                    }
                    LspCmd::Hover { target } => {
                        commands::lsp::handle_hover_command(&client, target, project, cli.json)
                            .await?;
                    }
                    LspCmd::NativeSymbol {
                        members,
                        full,
                        class,
                        member,
                    } => {
                        commands::lsp::handle_native_symbol_command(
                            &client,
                            class,
                            member.as_deref(),
                            *members,
                            *full,
                            cli.json,
                        )
                        .await?;
                    }
                    LspCmd::Diagnostics { file } => {
                        commands::lsp::handle_diagnostics_command(
                            &client,
                            file.as_deref(),
                            project,
                            cli.json,
                        )
                        .await?;
                    }
                }
                Ok(())
            }
            .await;

            client.disconnect().await;
            return result;
        }
    }

    Ok(())
}

// ==================== 单元测试 ====================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_target_position_mode() {
        // 用户输入 1-based: 10:5 → 内部 0-based: 9:4
        let result = parse_target("player.gd:10:5", None).unwrap();
        match result {
            TargetMode::Position { file, line, col } => {
                assert_eq!(file, PathBuf::from("player.gd"));
                assert_eq!(line, 9);
                assert_eq!(col, 4);
            }
            _ => panic!("Expected Position mode"),
        }
    }

    #[test]
    fn parse_target_symbol_path_mode() {
        let result = parse_target("player.gd:Player.health", None).unwrap();
        match result {
            TargetMode::SymbolPath { symbol_path } => {
                assert_eq!(symbol_path.file, PathBuf::from("player.gd"));
                assert_eq!(symbol_path.segments, vec!["Player", "health"]);
            }
            _ => panic!("Expected SymbolPath mode"),
        }
    }

    #[test]
    fn parse_target_symbol_path_short_form() {
        let result = parse_target("player.gd:health", None).unwrap();
        match result {
            TargetMode::SymbolPath { symbol_path } => {
                assert_eq!(symbol_path.file, PathBuf::from("player.gd"));
                assert_eq!(symbol_path.segments, vec!["health"]);
            }
            _ => panic!("Expected SymbolPath mode"),
        }
    }

    #[test]
    fn parse_target_invalid_format() {
        let result = parse_target("player.gd", None);
        assert!(result.is_err());
    }

    #[test]
    fn parse_target_invalid_format_no_colon() {
        let result = parse_target("player.gd", None);
        assert!(result.is_err());
    }

    #[test]
    fn parse_target_invalid_format_empty() {
        let result = parse_target("", None);
        assert!(result.is_err());
    }
}
