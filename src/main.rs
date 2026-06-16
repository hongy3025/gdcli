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

// ==================== 模块声明与导入 ====================

/// 声明 client 模块（对应 src/client.rs）
/// mod 语句告诉 Rust 编译器去加载同名的 .rs 文件
mod client;
mod symbol_path;
mod transport;
mod types;

/// 从 client 模块导入类型
/// Arc 是共享所有权指针，DiagnosticsResult 和 GodotLspClient 是核心类型
use crate::client::{DiagnosticsResult, GodotLspClient};
/// 从 types 模块导入工具函数和类型
use crate::types::{uri_to_file, symbol_kind_name, Diagnostic, Location, Range, WorkspaceEdit};
/// anyhow 提供简洁的错误处理，Result<T> 是 anyhow::Result<T> 的别名
use anyhow::Result;
/// clap 是 Rust 最流行的命令行参数解析库
/// Parser trait 给结构体添加命令行解析能力；Subcommand 把枚举变体变成子命令
use clap::{Parser, Subcommand};
/// serde_json 的 json! 宏用于快速构造 JSON Value
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

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
    /// LSP 服务器端口，默认 6005（Godot 默认 LSP 端口）
    #[arg(long, default_value_t = 6005, global = true)]
    port: u16,
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

/// 【Cmd — 支持的子命令枚举】
///
/// 【#[derive(Subcommand)] 说明】
/// clap 宏：把枚举的每个变体变成一个 CLI 子命令。
/// 变体上的属性控制命令名称、参数等。
#[derive(Subcommand)]
enum Cmd {
    /// 重命名符号：gdcli rename <target> <new_name>
    Rename { target: String, new_name: String },
    /// 查找引用：gdcli references <target>
    References { target: String },
    /// 跳转到定义：gdcli definition <target>
    Definition { target: String },
    /// 跳转到声明：gdcli declaration <target>
    Declaration { target: String },
    /// 列出文件中的符号：gdcli symbols <file>
    Symbols { file: PathBuf },
    /// 获取悬浮提示：gdcli hover <target>
    Hover { target: String },
    /// 查询 Godot 原生类文档（Godot LSP 扩展）
    #[command(name = "native-symbol")]
    NativeSymbol { class: String, member: Option<String> },
    /// 获取诊断信息（编译错误/警告）
    Diagnostics { file: Option<PathBuf> },
    /// 查询服务器能力列表
    Capabilities,
    /// 检查与 LSP 服务器的连接状态
    Status,
}

// ==================== 路径解析工具 ====================

/// 把用户输入的文件路径解析为绝对路径。
///
/// 优先级：
///   1. 如果已经是绝对路径，直接返回
///   2. 如果提供了 --project，基于项目目录拼接
///   3. 否则基于当前工作目录拼接
fn resolve_file(file: &Path, project: Option<&Path>) -> PathBuf {
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
enum TargetMode {
    Position { file: PathBuf, line: u32, col: u32 },
    SymbolPath { symbol_path: crate::symbol_path::SymbolPath },
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
fn parse_target(target: &str, _project: Option<&Path>) -> Result<TargetMode> {
    let parts: Vec<&str> = target.split(':').collect();

    // 至少要有 3 段才可能是 file:line:col（因为 line 和 col 各一段）
    if parts.len() >= 3 {
        let last_two = &parts[parts.len() - 2..];
        // 尝试把最后两段解析为 u32
        if let (Ok(line), Ok(col)) = (last_two[0].parse::<u32>(), last_two[1].parse::<u32>()) {
            // 前面的所有段用 : 重新拼起来作为文件路径
            let file = parts[..parts.len() - 2].join(":");
            return Ok(TargetMode::Position {
                file: PathBuf::from(file),
                line,
                col,
            });
        }
    }

    // 不是行列号格式，尝试符号路径
    if crate::symbol_path::SymbolPath::is_symbol_path(target) {
        let sp = crate::symbol_path::SymbolPath::parse(target)
            .map_err(|e| anyhow::anyhow!(e))?;
        Ok(TargetMode::SymbolPath { symbol_path: sp })
    } else {
        Err(anyhow::anyhow!(
            "Invalid target format. Expected 'file:line:col' or 'file:SymbolPath'"
        ))
    }
}

// ==================== 格式化输出工具 ====================

/// 把 LSP Range 格式化为人类可读的字符串：start_line:start_col-end_line:end_col
fn format_range(r: &Range) -> String {
    format!(
        "{}:{}-{}:{}",
        r.start.line, r.start.character, r.end.line, r.end.character
    )
}

/// 从 JSON Location 中提取并格式化位置信息。
///
/// 【?. 链式调用说明】
/// `a?.b?.c` 是 JSON 取值的安全写法：
/// 如果某一步返回 None，整个表达式返回 None，不会 panic。
fn format_location_value(loc: &Value) -> Option<String> {
    let uri = loc.get("uri")?.as_str()?;
    let line = loc.get("range")?.get("start")?.get("line")?.as_u64()?;
    let col = loc.get("range")?.get("start")?.get("character")?.as_u64()?;
    Some(format!("{}:{}:{}", uri_to_file(uri), line, col))
}

/// 把 LSP severity 数字转为人可读的名称。
///
/// LSP 规范：1=Error, 2=Warning, 3=Info, 4=Hint
fn severity_name(s: Option<u32>) -> &'static str {
    match s.unwrap_or(1) {
        1 => "error",
        2 => "warning",
        3 => "info",
        4 => "hint",
        _ => "",
    }
}

/// 格式化单条诊断信息为人类可读字符串。
fn format_diagnostic(d: &Diagnostic) -> String {
    format!(
        "  [{}] {}: {}",
        severity_name(d.severity),
        format_range(&d.range),
        d.message
    )
}

/// 递归解码 JSON 中的 file:/// URI。
///
/// 【作用】
/// LSP 服务器返回的 JSON 中经常包含 file:/// URI（如文件路径、键名）。
/// 这个函数遍历整个 JSON 树，把所有 file:/// 开头的字符串转为本地路径，
/// 使 JSON 输出对人类更友好。
///
/// 【match 匹配 Value】
/// serde_json::Value 是一个枚举，可以表示任意 JSON：
///   - String：JSON 字符串
///   - Array：JSON 数组
///   - Object：JSON 对象（键值对映射）
///   - 其他：Number, Bool, Null
fn decode_uris(v: Value) -> Value {
    match v {
        Value::String(s) if s.starts_with("file:///") => Value::String(uri_to_file(&s)),
        Value::Array(arr) => Value::Array(arr.into_iter().map(decode_uris).collect()),
        Value::Object(map) => {
            let mut out = serde_json::Map::new();
            for (k, val) in map {
                let new_k = if k.starts_with("file:///") {
                    uri_to_file(&k)
                } else {
                    k
                };
                out.insert(new_k, decode_uris(val));
            }
            Value::Object(out)
        }
        other => other,
    }
}

/// 递归打印符号树（DocumentSymbol 层级结构）。
///
/// LSP 的 documentSymbol 返回树形结构，每个节点可能有 children。
/// indent 控制缩进层级，使输出呈树状。
fn print_symbols(symbols: &[Value], indent: usize) {
    for sym in symbols {
        let prefix = "  ".repeat(indent);
        let kind = sym.get("kind").and_then(|x| x.as_u64()).unwrap_or(0) as u32;
        let name = sym.get("name").and_then(|x| x.as_str()).unwrap_or("?");
        // DocumentSymbol 同时有 range 和 selectionRange
        if sym.get("range").is_some() && sym.get("selectionRange").is_some() {
            let r = sym.get("range").cloned().unwrap_or(Value::Null);
            let r_parsed: Range = serde_json::from_value(r).unwrap_or(Range {
                start: crate::types::Position { line: 0, character: 0 },
                end: crate::types::Position { line: 0, character: 0 },
            });
            println!(
                "{}{} {} [{}]",
                prefix,
                symbol_kind_name(kind),
                name,
                format_range(&r_parsed)
            );
            if let Some(children) = sym.get("children").and_then(|x| x.as_array()) {
                print_symbols(children, indent + 1);
            }
        } else if let Some(loc) = sym.get("location") {
            let loc_str = format_location_value(loc).unwrap_or_else(|| "?".to_string());
            println!("{}{} {} {}", prefix, symbol_kind_name(kind), name, loc_str);
        }
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

    // Status 命令单独处理：即使连接失败也要友好输出
    if matches!(cli.cmd, Cmd::Status) {
        return handle_status_command(&cli.host, cli.port, project, cli.json).await;
    }

    let client = match GodotLspClient::connect(&cli.host, cli.port, project).await {
        Ok(c) => c,
        Err(_) => {
            eprintln!("Failed to connect to Godot LSP at {}:{}", cli.host, cli.port);
            eprintln!(
                "Make sure Godot is running with: godot --editor --headless --lsp-port {} --path /your/project",
                cli.port
            );
            std::process::exit(1);
        }
    };

    let result: Result<()> = async {
        match cli.cmd {
            Cmd::Capabilities => {
                let caps = client.server_capabilities().await;
                println!("{}", serde_json::to_string_pretty(&caps)?);
            }
            Cmd::Rename { target, new_name } => {
                handle_rename_command(&client, &target, &new_name, project, cli.json).await?;
            }
            Cmd::References { target } => {
                handle_references_command(&client, &target, project, cli.json).await?;
            }
            Cmd::Definition { target } => {
                handle_definition_command(&client, &target, project, cli.json).await?;
            }
            Cmd::Declaration { target } => {
                handle_declaration_command(&client, &target, project, cli.json).await?;
            }
            Cmd::Symbols { file } => {
                handle_symbols_command(&client, &file, project, cli.json).await?;
            }
            Cmd::Hover { target } => {
                handle_hover_command(&client, &target, project, cli.json).await?;
            }
            Cmd::NativeSymbol { class, member } => {
                handle_native_symbol_command(&client, &class, member.as_deref(), cli.json).await?;
            }
            Cmd::Diagnostics { file } => {
                handle_diagnostics_command(&client, file.as_deref(), project, cli.json).await?;
            }
            Cmd::Status => {
                // Status 在前面已经处理，这里不可能到达
                unreachable!()
            }
        }
        Ok(())
    }
    .await;

    client.disconnect().await;
    result
}

// ==================== 命令处理器 ====================

/// 处理 status 子命令。
///
/// 尝试连接服务器，根据结果输出连接状态。
/// 与其他命令不同：连接失败时不会直接 panic，而是输出友好的错误信息。
async fn handle_status_command(
    host: &str,
    port: u16,
    project: Option<&Path>,
    json_mode: bool,
) -> Result<()> {
    match GodotLspClient::connect(host, port, project).await {
        Ok(client) => {
            if json_mode {
                let status = json!({
                    "connected": true,
                    "host": host,
                    "port": port,
                    "project": project.map(|p| p.to_string_lossy().to_string()),
                });
                println!("{}", serde_json::to_string_pretty(&status)?);
            } else {
                println!("Connected to Godot LSP at {}:{}", host, port);
                if let Some(p) = project {
                    println!("Project: {}", p.display());
                }
            }
            client.disconnect().await;
            Ok(())
        }
        Err(e) => {
            if json_mode {
                let status = json!({
                    "connected": false,
                    "host": host,
                    "port": port,
                    "error": e.to_string(),
                });
                println!("{}", serde_json::to_string_pretty(&status)?);
            } else {
                eprintln!("Failed to connect to Godot LSP at {}:{}", host, port);
                eprintln!("Error: {}", e);
                eprintln!(
                    "Make sure Godot is running with: godot --editor --headless --lsp-port {} --path /your/project",
                    port
                );
            }
            std::process::exit(1);
        }
    }
}

/// 处理 rename 子命令。
///
/// 支持两种 target 格式：
///   - 行列号：file.gd:10:5
///   - 符号路径：file.gd:Player.health
async fn handle_rename_command(
    client: &Arc<GodotLspClient>,
    target: &str,
    new_name: &str,
    project: Option<&Path>,
    json_mode: bool,
) -> Result<()> {
    let mode = parse_target(target, project)?;
    match mode {
        TargetMode::Position { file, line, col } => {
            let f = resolve_file(&file, project);
            let result = client.rename(&f, line, col, new_name).await?;
            print_rename_result(result, json_mode)?;
        }
        TargetMode::SymbolPath { symbol_path } => {
            let f = resolve_file(&symbol_path.file, project);
            let (pos, name) = client.resolve_symbol_path(&f, &symbol_path.segments).await?;
            let result = client.rename(&f, pos.line, pos.character, new_name).await?;
            if json_mode {
                let v = json!({
                    "symbol": name,
                    "position": { "line": pos.line, "character": pos.character },
                    "result": result
                });
                println!("{}", serde_json::to_string_pretty(&decode_uris(v))?);
            } else {
                println!("Renaming symbol '{}' at {}:{}", name, pos.line, pos.character);
                print_rename_result(result, false)?;
            }
        }
    }
    Ok(())
}

/// 处理 references 子命令。
async fn handle_references_command(
    client: &Arc<GodotLspClient>,
    target: &str,
    project: Option<&Path>,
    json_mode: bool,
) -> Result<()> {
    let mode = parse_target(target, project)?;
    match mode {
        TargetMode::Position { file, line, col } => {
            let f = resolve_file(&file, project);
            let result = client.references(&f, line, col).await?;
            print_references_result(&result, json_mode)?;
        }
        TargetMode::SymbolPath { symbol_path } => {
            let f = resolve_file(&symbol_path.file, project);
            let (pos, name) = client.resolve_symbol_path(&f, &symbol_path.segments).await?;
            let result = client.references(&f, pos.line, pos.character).await?;
            if json_mode {
                let v = json!({
                    "symbol": name,
                    "position": { "line": pos.line, "character": pos.character },
                    "references": result
                });
                println!("{}", serde_json::to_string_pretty(&decode_uris(v))?);
            } else {
                println!("References for symbol '{}' at {}:{}", name, pos.line, pos.character);
                print_references_result(&result, false)?;
            }
        }
    }
    Ok(())
}

/// 处理 definition 子命令。
async fn handle_definition_command(
    client: &Arc<GodotLspClient>,
    target: &str,
    project: Option<&Path>,
    json_mode: bool,
) -> Result<()> {
    let mode = parse_target(target, project)?;
    match mode {
        TargetMode::Position { file, line, col } => {
            let f = resolve_file(&file, project);
            let v = client.definition(&f, line, col).await?;
            handle_locations(&v, json_mode, "No definition found.")?;
        }
        TargetMode::SymbolPath { symbol_path } => {
            let f = resolve_file(&symbol_path.file, project);
            let (pos, name) = client.resolve_symbol_path(&f, &symbol_path.segments).await?;
            let v = client.definition(&f, pos.line, pos.character).await?;
            if json_mode {
                let result = json!({
                    "symbol": name,
                    "position": { "line": pos.line, "character": pos.character },
                    "definition": v
                });
                println!("{}", serde_json::to_string_pretty(&decode_uris(result))?);
            } else {
                println!("Definition for symbol '{}' at {}:{}", name, pos.line, pos.character);
                handle_locations(&v, false, "No definition found.")?;
            }
        }
    }
    Ok(())
}

/// 处理 declaration 子命令。
async fn handle_declaration_command(
    client: &Arc<GodotLspClient>,
    target: &str,
    project: Option<&Path>,
    json_mode: bool,
) -> Result<()> {
    let mode = parse_target(target, project)?;
    match mode {
        TargetMode::Position { file, line, col } => {
            let f = resolve_file(&file, project);
            let v = client.declaration(&f, line, col).await?;
            handle_locations(&v, json_mode, "No declaration found.")?;
        }
        TargetMode::SymbolPath { symbol_path } => {
            let f = resolve_file(&symbol_path.file, project);
            let (pos, name) = client.resolve_symbol_path(&f, &symbol_path.segments).await?;
            let v = client.declaration(&f, pos.line, pos.character).await?;
            if json_mode {
                let result = json!({
                    "symbol": name,
                    "position": { "line": pos.line, "character": pos.character },
                    "declaration": v
                });
                println!("{}", serde_json::to_string_pretty(&decode_uris(result))?);
            } else {
                println!("Declaration for symbol '{}' at {}:{}", name, pos.line, pos.character);
                handle_locations(&v, false, "No declaration found.")?;
            }
        }
    }
    Ok(())
}

/// 处理 symbols 子命令。
async fn handle_symbols_command(
    client: &Arc<GodotLspClient>,
    file: &Path,
    project: Option<&Path>,
    json_mode: bool,
) -> Result<()> {
    let f = resolve_file(file, project);
    let v = client.document_symbols(&f).await?;
    if json_mode {
        println!("{}", serde_json::to_string_pretty(&decode_uris(v))?);
    } else {
        let arr = v.as_array().cloned().unwrap_or_default();
        if arr.is_empty() {
            println!("No symbols found.");
        } else {
            print_symbols(&arr, 0);
        }
    }
    Ok(())
}

/// 处理 hover 子命令。
async fn handle_hover_command(
    client: &Arc<GodotLspClient>,
    target: &str,
    project: Option<&Path>,
    json_mode: bool,
) -> Result<()> {
    let mode = parse_target(target, project)?;
    match mode {
        TargetMode::Position { file, line, col } => {
            let f = resolve_file(&file, project);
            let result = client.hover(&f, line, col).await?;
            if json_mode {
                let v = json!({ "hover": result });
                println!("{}", serde_json::to_string_pretty(&decode_uris(v))?);
            } else {
                println!("{}", result.unwrap_or_else(|| "No hover info available.".into()));
            }
        }
        TargetMode::SymbolPath { symbol_path } => {
            let f = resolve_file(&symbol_path.file, project);
            let (pos, name) = client.resolve_symbol_path(&f, &symbol_path.segments).await?;
            let result = client.hover(&f, pos.line, pos.character).await?;
            if json_mode {
                let v = json!({
                    "symbol": name,
                    "position": { "line": pos.line, "character": pos.character },
                    "hover": result
                });
                println!("{}", serde_json::to_string_pretty(&decode_uris(v))?);
            } else {
                println!("Hover info for symbol '{}' at {}:{}", name, pos.line, pos.character);
                println!("{}", result.unwrap_or_else(|| "No hover info available.".into()));
            }
        }
    }
    Ok(())
}

/// 处理 native-symbol 子命令。
async fn handle_native_symbol_command(
    client: &Arc<GodotLspClient>,
    class: &str,
    member: Option<&str>,
    json_mode: bool,
) -> Result<()> {
    let v = client.native_symbol(class, member).await?;
    if json_mode {
        println!("{}", serde_json::to_string_pretty(&decode_uris(v))?);
    } else if v.is_null() {
        println!("No documentation found.");
    } else {
        let name = v.get("name").and_then(|x| x.as_str()).unwrap_or("?");
        let detail = v.get("detail").and_then(|x| x.as_str());
        let docs = v.get("documentation").and_then(|x| x.as_str());
        let children = v.get("children").and_then(|x| x.as_array());
        if let Some(d) = detail {
            println!("{} — {}", name, d);
        } else {
            println!("{}", name);
        }
        if let Some(d) = docs {
            println!();
            println!("{}", d);
        }
        if let (Some(c), None) = (children, member) {
            println!();
            println!("Members: {}", c.len());
        }
    }
    Ok(())
}

/// 处理 diagnostics 子命令。
///
/// 等待 2 秒让服务器有时间推送诊断信息，然后查询并输出。
async fn handle_diagnostics_command(
    client: &Arc<GodotLspClient>,
    file: Option<&Path>,
    project: Option<&Path>,
    json_mode: bool,
) -> Result<()> {
    tokio::time::sleep(Duration::from_secs(2)).await;
    let f = file.map(|p| resolve_file(p, project));
    let result = client.diagnostics_for(f.as_deref()).await;
    handle_diagnostics(result, json_mode)
}

// ==================== 结果输出辅助函数 ====================

/// 统一处理返回 Location（或 Location 数组）的命令输出。
///
/// json_mode 为 true 时直接输出 JSON；
/// 否则把每个 Location 转为 file:line:col 格式输出。
fn handle_locations(v: &Value, json_mode: bool, empty_msg: &str) -> Result<()> {
    if json_mode {
        println!("{}", serde_json::to_string_pretty(&decode_uris(v.clone()))?);
        return Ok(());
    }
    if v.is_null() {
        println!("{}", empty_msg);
        return Ok(());
    }
    let arr = if v.is_array() {
        v.as_array().cloned().unwrap_or_default()
    } else {
        vec![v.clone()]
    };
    if arr.is_empty() {
        println!("{}", empty_msg);
        return Ok(());
    }
    for loc in &arr {
        if let Some(s) = format_location_value(loc) {
            println!("{}", s);
        }
    }
    Ok(())
}

/// 统一处理诊断结果输出。
fn handle_diagnostics(result: DiagnosticsResult, json_mode: bool) -> Result<()> {
    match result {
        DiagnosticsResult::Single(diags) => {
            if json_mode {
                let v = serde_json::to_value(&diags)?;
                println!("{}", serde_json::to_string_pretty(&decode_uris(v))?);
            } else if diags.is_empty() {
                println!("No diagnostics for this file.");
            } else {
                for d in &diags {
                    println!("{}", format_diagnostic(d));
                }
            }
        }
        DiagnosticsResult::All(map) => {
            if json_mode {
                let mut obj = serde_json::Map::new();
                for (k, v) in map {
                    obj.insert(k, serde_json::to_value(v)?);
                }
                let v = decode_uris(Value::Object(obj));
                println!("{}", serde_json::to_string_pretty(&v)?);
            } else if map.is_empty() {
                println!("No diagnostics.");
            } else {
                for (uri, diags) in map {
                    println!("{}:", uri_to_file(&uri));
                    for d in &diags {
                        println!("{}", format_diagnostic(d));
                    }
                }
            }
        }
    }
    Ok(())
}

/// 输出重命名结果。
fn print_rename_result(result: Option<WorkspaceEdit>, json_mode: bool) -> Result<()> {
    if json_mode {
        let v = serde_json::to_value(&result)?;
        println!("{}", serde_json::to_string_pretty(&decode_uris(v))?);
    } else {
        match result {
            Some(we) if we.changes.is_some() => {
                let changes = we.changes.unwrap();
                for (uri, edits) in changes {
                    println!("{}:", uri_to_file(&uri));
                    for e in edits {
                        println!("  {} → \"{}\"", format_range(&e.range), e.new_text);
                    }
                }
            }
            Some(we) if we.document_changes.is_some() => {
                let v = decode_uris(we.document_changes.unwrap());
                println!("{}", serde_json::to_string_pretty(&v)?);
            }
            _ => println!("No changes returned. Symbol may not support rename."),
        }
    }
    Ok(())
}

/// 输出引用查找结果。
fn print_references_result(result: &[Location], json_mode: bool) -> Result<()> {
    if json_mode {
        let v = serde_json::to_value(result)?;
        println!("{}", serde_json::to_string_pretty(&decode_uris(v))?);
    } else if result.is_empty() {
        println!("No references found.");
    } else {
        println!("Found {} reference(s):", result.len());
        for loc in result {
            let v = serde_json::to_value(loc)?;
            if let Some(s) = format_location_value(&v) {
                println!("  {}", s);
            }
        }
    }
    Ok(())
}

// ==================== 单元测试 ====================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Position;

    #[test]
    fn fmt_range_basic() {
        let r = Range {
            start: Position { line: 1, character: 2 },
            end: Position { line: 3, character: 4 },
        };
        assert_eq!(format_range(&r), "1:2-3:4");
    }

    #[test]
    fn fmt_diagnostic_error() {
        let d = Diagnostic {
            range: Range {
                start: Position { line: 5, character: 0 },
                end: Position { line: 5, character: 10 },
            },
            severity: Some(1),
            code: None,
            message: "bad".into(),
            source: None,
        };
        assert_eq!(format_diagnostic(&d), "  [error] 5:0-5:10: bad");
    }

    #[test]
    fn fmt_diagnostic_default_severity() {
        let d = Diagnostic {
            range: Range {
                start: Position { line: 0, character: 0 },
                end: Position { line: 0, character: 1 },
            },
            severity: None,
            code: None,
            message: "x".into(),
            source: None,
        };
        assert_eq!(format_diagnostic(&d), "  [error] 0:0-0:1: x");
    }

    #[test]
    fn decode_uris_recursive() {
        let v = json!({
            "file:///C:/foo.gd": [{"uri": "file:///C:/bar.gd"}],
            "plain": "no-uri"
        });
        let out = decode_uris(v);
        let obj = out.as_object().unwrap();
        assert!(obj.keys().any(|k| !k.starts_with("file:///")));
        assert_eq!(obj.get("plain").unwrap(), "no-uri");
    }

    #[test]
    fn parse_target_position_mode() {
        let result = parse_target("player.gd:10:5", None).unwrap();
        match result {
            TargetMode::Position { file, line, col } => {
                assert_eq!(file, PathBuf::from("player.gd"));
                assert_eq!(line, 10);
                assert_eq!(col, 5);
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
