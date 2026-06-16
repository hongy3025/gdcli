mod client;
mod transport;
mod types;

use crate::client::{DiagnosticsResult, GodotLspClient};
use crate::types::{uri_to_file, symbol_kind_name, Diagnostic, Range};
use anyhow::Result;
use clap::{Parser, Subcommand};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Parser)]
#[command(name = "gdcli", version, about = "CLI for Godot's built-in LSP")]
struct Cli {
    #[arg(long, default_value = "127.0.0.1", global = true)]
    host: String,
    #[arg(long, default_value_t = 6005, global = true)]
    port: u16,
    #[arg(long, global = true)]
    project: Option<PathBuf>,
    #[arg(long, global = true)]
    json: bool,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    Rename { file: PathBuf, line: u32, col: u32, new_name: String },
    References { file: PathBuf, line: u32, col: u32 },
    Definition { file: PathBuf, line: u32, col: u32 },
    Declaration { file: PathBuf, line: u32, col: u32 },
    Symbols { file: PathBuf },
    Hover { file: PathBuf, line: u32, col: u32 },
    #[command(name = "native-symbol")]
    NativeSymbol { class: String, member: Option<String> },
    Diagnostics { file: Option<PathBuf> },
    Capabilities,
}

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

fn format_range(r: &Range) -> String {
    format!(
        "{}:{}-{}:{}",
        r.start.line, r.start.character, r.end.line, r.end.character
    )
}

fn format_location_value(loc: &Value) -> Option<String> {
    let uri = loc.get("uri")?.as_str()?;
    let line = loc.get("range")?.get("start")?.get("line")?.as_u64()?;
    let col = loc.get("range")?.get("start")?.get("character")?.as_u64()?;
    Some(format!("{}:{}:{}", uri_to_file(uri), line, col))
}

fn severity_name(s: Option<u32>) -> &'static str {
    match s.unwrap_or(1) {
        1 => "error",
        2 => "warning",
        3 => "info",
        4 => "hint",
        _ => "",
    }
}

fn format_diagnostic(d: &Diagnostic) -> String {
    format!(
        "  [{}] {}: {}",
        severity_name(d.severity),
        format_range(&d.range),
        d.message
    )
}

/// 递归解码 JSON 中的 file:/// URI（包括对象 key）。
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

#[tokio::main]
async fn main() {
    if let Err(e) = run().await {
        eprintln!("{}", e);
        std::process::exit(1);
    }
}

async fn run() -> Result<()> {
    let cli = Cli::parse();
    let project = cli.project.as_deref();

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
            Cmd::Rename { file, line, col, new_name } => {
                let f = resolve_file(&file, project);
                let result = client.rename(&f, line, col, &new_name).await?;
                if cli.json {
                    let v = serde_json::to_value(&result)?;
                    println!("{}", serde_json::to_string_pretty(&decode_uris(v))?);
                } else {
                    match result {
                        Some(we) if we.changes.is_some() => {
                            for (uri, edits) in we.changes.unwrap() {
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
            }
            Cmd::References { file, line, col } => {
                let f = resolve_file(&file, project);
                let result = client.references(&f, line, col).await?;
                if cli.json {
                    let v = serde_json::to_value(&result)?;
                    println!("{}", serde_json::to_string_pretty(&decode_uris(v))?);
                } else if result.is_empty() {
                    println!("No references found.");
                } else {
                    println!("Found {} reference(s):", result.len());
                    for loc in &result {
                        let v = serde_json::to_value(loc)?;
                        if let Some(s) = format_location_value(&v) {
                            println!("  {}", s);
                        }
                    }
                }
            }
            Cmd::Definition { file, line, col } => {
                let f = resolve_file(&file, project);
                let v = client.definition(&f, line, col).await?;
                handle_locations(&v, cli.json, "No definition found.")?;
            }
            Cmd::Declaration { file, line, col } => {
                let f = resolve_file(&file, project);
                let v = client.declaration(&f, line, col).await?;
                handle_locations(&v, cli.json, "No declaration found.")?;
            }
            Cmd::Symbols { file } => {
                let f = resolve_file(&file, project);
                let v = client.document_symbols(&f).await?;
                if cli.json {
                    println!("{}", serde_json::to_string_pretty(&decode_uris(v))?);
                } else {
                    let arr = v.as_array().cloned().unwrap_or_default();
                    if arr.is_empty() {
                        println!("No symbols found.");
                    } else {
                        print_symbols(&arr, 0);
                    }
                }
            }
            Cmd::Hover { file, line, col } => {
                let f = resolve_file(&file, project);
                let result = client.hover(&f, line, col).await?;
                if cli.json {
                    let v = json!({ "hover": result });
                    println!("{}", serde_json::to_string_pretty(&decode_uris(v))?);
                } else {
                    println!("{}", result.unwrap_or_else(|| "No hover info available.".into()));
                }
            }
            Cmd::NativeSymbol { class, member } => {
                let v = client.native_symbol(&class, member.as_deref()).await?;
                if cli.json {
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
                    if let (Some(c), None) = (children, member.as_ref()) {
                        println!();
                        println!("Members: {}", c.len());
                    }
                }
            }
            Cmd::Diagnostics { file } => {
                tokio::time::sleep(Duration::from_secs(2)).await;
                let f = file.as_deref().map(|p| resolve_file(p, project));
                let result = client.diagnostics_for(f.as_deref()).await;
                handle_diagnostics(result, cli.json)?;
            }
        }
        Ok(())
    }
    .await;

    client.disconnect().await;
    result
}

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
}
