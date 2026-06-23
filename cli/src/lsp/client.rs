//! client.rs — Godot LSP 客户端
//!
//! 【这个文件的作用】
//! 在 transport.rs 之上封装更高层次的 LSP 客户端逻辑。
//! 负责：
//!   - 与 Godot LSP 服务器建立连接并初始化
//!   - 管理文件打开状态（textDocument/didOpen）
//!   - 提供重命名、查找引用、跳转定义、获取符号列表等高层 API
//!   - 接收并缓存服务器推送的诊断信息
//!   - 实现符号路径解析（把 player.gd:Player.health 转成行列号）
//!
//! 【关于 Arc、Mutex、AtomicBool】
//! - Arc：线程安全的共享所有权，多个异步任务可以共享同一个 GodotLspClient
//! - Mutex：异步互斥锁，保护并发访问的共享数据
//! - AtomicBool：线程安全的布尔值，用于判断是否已经初始化
//!
//! 【 anyhow 错误处理】
//! Rust 中函数返回 Result<T>（这里 Result 是 anyhow 提供的别名），
//! 用 ? 运算符传播错误：如果某步出错，自动提前返回 Err。

// ==================== 导入 ====================

use crate::lsp::transport::{LspTransport, Notification};
use crate::lsp::types::{file_to_uri, Diagnostic, Location, Position, Range, WorkspaceEdit};
use anyhow::{anyhow, Result};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;

// ==================== GodotLspClient 结构体 ====================

/// 【GodotLspClient — Godot LSP 客户端】
///
/// 这是 gdcli 与 Godot 编辑器内置 LSP 服务器交互的核心。
/// 每个实例对应一个 TCP 连接。
pub struct GodotLspClient {
    /// 底层传输层，负责发送/接收 JSON-RPC 消息
    transport: Arc<LspTransport>,
    /// 是否已经完成了 LSP initialize 握手
    /// SeqCst 保证多线程下状态可见性
    initialized: AtomicBool,
    /// 缓存的诊断信息：键为文件 URI，值为该文件的诊断列表
    /// 服务器通过 textDocument/publishDiagnostics 推送，我们在后台任务中接收并存储
    diagnostics: Arc<Mutex<HashMap<String, Vec<Diagnostic>>>>,
    /// 已打开的文件集合（用 URI 作为键）
    /// LSP 要求客户端在操作文件前先发送 didOpen 通知
    opened_files: Mutex<HashSet<String>>,
    /// 服务器的能力列表（capabilities），在 initialize 响应中获得
    /// 告诉我们服务器支持哪些 LSP 功能
    server_capabilities: Mutex<Value>,
}

impl GodotLspClient {
    /// 连接到 Godot LSP 服务器并完成初始化握手。
    ///
    /// 【流程】
    /// 1. 通过 LspTransport::connect 建立 TCP 连接
    /// 2. 创建客户端实例
    /// 3. 启动后台通知监听任务（接收诊断等推送）
    /// 4. 发送 LSP initialize 请求，交换双方能力信息
    ///
    /// 【返回 Arc<Self>】
    /// 调用者通常需要把客户端传给多个命令处理函数，所以用 Arc 共享。
    pub async fn connect(host: &str, port: u16, project: Option<&Path>) -> Result<Arc<Self>> {
        let transport = LspTransport::connect(host, port).await?;
        let client = Arc::new(Self {
            transport: transport.clone(),
            initialized: AtomicBool::new(false),
            diagnostics: Arc::new(Mutex::new(HashMap::new())),
            opened_files: Mutex::new(HashSet::new()),
            server_capabilities: Mutex::new(Value::Object(serde_json::Map::new())),
        });
        client.spawn_notification_listener();
        client.initialize(project).await?;
        Ok(client)
    }

    /// 启动后台任务，持续监听服务器推送的通知。
    ///
    /// 【tokio::spawn】
    /// 创建一个后台异步任务，它会在独立的协程中运行，不会阻塞当前函数。
    ///
    /// 【while let Ok(...) = rx.recv().await】
    /// 循环接收通知，直到通道关闭或出错。
    /// 这里只处理 textDocument/publishDiagnostics（诊断推送），
    /// 其他通知被忽略。
    fn spawn_notification_listener(self: &Arc<Self>) {
        let mut rx = self.transport.subscribe();
        let diags = self.diagnostics.clone();
        tokio::spawn(async move {
            while let Ok(Notification { method, params }) = rx.recv().await {
                if method == "textDocument/publishDiagnostics" {
                    if let (Some(uri), Some(arr)) = (
                        params.get("uri").and_then(|v| v.as_str()),
                        params.get("diagnostics").and_then(|v| v.as_array()),
                    ) {
                        let parsed: Vec<Diagnostic> = arr
                            .iter()
                            .filter_map(|d| serde_json::from_value(d.clone()).ok())
                            .collect();
                        diags.lock().await.insert(uri.to_string(), parsed);
                    }
                }
            }
        });
    }

    /// LSP 初始化握手。
    ///
    /// 【initialize 请求】
    /// LSP 协议规定，客户端连接后必须先发送 initialize 请求，
    /// 双方交换名字、版本、支持的功能（capabilities）等信息。
    /// 在收到 initialize 响应前，不能发送其他请求。
    ///
    /// 【rootUri / rootPath】
    /// 告诉服务器项目根目录在哪里，服务器据此解析相对路径、加载项目配置。
    async fn initialize(&self, project: Option<&Path>) -> Result<()> {
        let root_uri = project.map(|p| file_to_uri(p));
        let root_path = project.map(|p| p.to_string_lossy().to_string());
        let params = json!({
            "processId": std::process::id(),
            "capabilities": {
                "textDocument": {
                    "synchronization": {
                        "didSave": true,
                        "willSave": false,
                        "willSaveWaitUntil": false,
                    },
                    "rename": { "prepareSupport": true },
                    "references": {},
                    "definition": {},
                    "documentSymbol": { "hierarchicalDocumentSymbolSupport": true },
                    "publishDiagnostics": {},
                    "hover": { "contentFormat": ["plaintext", "markdown"] },
                },
                "workspace": {
                    "workspaceEdit": { "documentChanges": true },
                    "symbol": {},
                },
            },
            "rootUri": root_uri,
            "rootPath": root_path,
        });

        let result = self.transport.request("initialize", params).await?;
        let caps = result
            .get("capabilities")
            .cloned()
            .unwrap_or_else(|| Value::Object(serde_json::Map::new()));
        *self.server_capabilities.lock().await = caps;
        self.transport.notify("initialized", json!({})).await?;
        self.initialized.store(true, Ordering::SeqCst);
        Ok(())
    }

    /// 获取服务器的能力列表（capabilities）。
    pub async fn server_capabilities(&self) -> Value {
        self.server_capabilities.lock().await.clone()
    }

    /// 断开与 LSP 服务器的连接。
    ///
    /// 如果已经完成初始化，先发送 shutdown 通知，再关闭 TCP 连接。
    pub async fn disconnect(&self) {
        if self.initialized.load(Ordering::SeqCst) {
            let _ = self.transport.notify("shutdown", json!(null)).await;
        }
        self.transport.shutdown().await;
    }

    /// 确保指定文件已经通过 textDocument/didOpen 通知打开。
    ///
    /// 【为什么需要 ensure_open？】
    /// LSP 协议要求：在对文件执行 rename/definition/hover 等操作前，
    /// 客户端必须先发送 didOpen 通知，告诉服务器文件内容是什么。
    /// 这个函数读取磁盘上的文件内容并发送 didOpen，同时避免重复打开。
    ///
    /// 【drop(opened)】
    /// 显式 drop 掉 MutexGuard，尽早释放锁，减少锁持有时间。
    /// 然后 sleep 500ms 给服务器时间解析文件。
    async fn ensure_open(&self, file: &Path) -> Result<String> {
        let uri = file_to_uri(file);
        let mut opened = self.opened_files.lock().await;
        if !opened.contains(&uri) {
            let content = tokio::fs::read_to_string(file)
                .await
                .map_err(|e| anyhow!("read {}: {}", file.display(), e))?;
            self.transport
                .notify(
                    "textDocument/didOpen",
                    json!({
                        "textDocument": {
                            "uri": uri,
                            "languageId": "gdscript",
                            "version": 1,
                            "text": content,
                        }
                    }),
                )
                .await?;
            opened.insert(uri.clone());
            drop(opened);
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
        Ok(uri)
    }

    // ==================== LSP 请求方法 ====================

    /// 重命名符号。
    ///
    /// 发送 textDocument/rename 请求，返回 WorkspaceEdit（包含所有需要修改的位置）。
    /// 如果服务器返回 null，表示该符号不支持重命名。
    pub async fn rename(
        &self,
        file: &Path,
        line: u32,
        character: u32,
        new_name: &str,
    ) -> Result<Option<WorkspaceEdit>> {
        let uri = self.ensure_open(file).await?;
        let v = self
            .transport
            .request(
                "textDocument/rename",
                json!({
                    "textDocument": { "uri": uri },
                    "position": { "line": line, "character": character },
                    "newName": new_name,
                }),
            )
            .await?;
        if v.is_null() {
            return Ok(None);
        }
        Ok(Some(serde_json::from_value(v)?))
    }

    /// 查找符号的所有引用。
    ///
    /// 发送 textDocument/references 请求，返回 Location 列表。
    /// includeDeclaration: true 表示同时返回定义位置本身。
    pub async fn references(
        &self,
        file: &Path,
        line: u32,
        character: u32,
    ) -> Result<Vec<Location>> {
        let uri = self.ensure_open(file).await?;
        let v = self
            .transport
            .request(
                "textDocument/references",
                json!({
                    "textDocument": { "uri": uri },
                    "position": { "line": line, "character": character },
                    "context": { "includeDeclaration": true },
                }),
            )
            .await?;
        if v.is_null() {
            return Ok(vec![]);
        }
        Ok(serde_json::from_value(v)?)
    }

    /// 跳转到符号的定义。
    ///
    /// 返回 Value 而不是具体的 Location/Vec<Location>，
    /// 因为不同服务器返回的格式可能略有差异（单个对象或数组）。
    pub async fn definition(
        &self,
        file: &Path,
        line: u32,
        character: u32,
    ) -> Result<Value> {
        let uri = self.ensure_open(file).await?;
        self.transport
            .request(
                "textDocument/definition",
                json!({
                    "textDocument": { "uri": uri },
                    "position": { "line": line, "character": character },
                }),
            )
            .await
    }

    /// 跳转到符号的声明。
    ///
    /// 与 definition 的区别：declaration 是符号首次声明的位置，
    /// definition 是符号实际定义/实现的位置。某些语言中二者可能不同。
    pub async fn declaration(
        &self,
        file: &Path,
        line: u32,
        character: u32,
    ) -> Result<Value> {
        let uri = self.ensure_open(file).await?;
        self.transport
            .request(
                "textDocument/declaration",
                json!({
                    "textDocument": { "uri": uri },
                    "position": { "line": line, "character": character },
                }),
            )
            .await
    }

    /// 获取文档中的符号列表。
    ///
    /// 返回文件中的所有类、函数、变量等符号的层级结构。
    /// 结果是一个 JSON Value（DocumentSymbol 树或 SymbolInformation 数组）。
    pub async fn document_symbols(&self, file: &Path) -> Result<Value> {
        let uri = self.ensure_open(file).await?;
        self.transport
            .request(
                "textDocument/documentSymbol",
                json!({ "textDocument": { "uri": uri } }),
            )
            .await
    }

    /// 获取光标位置的悬浮提示（hover）。
    ///
    /// 返回符号的类型签名、文档注释等信息。
    /// 结果可能是纯文本或 Markdown 格式（取决于服务器支持）。
    pub async fn hover(&self, file: &Path, line: u32, character: u32) -> Result<Option<String>> {
        let uri = self.ensure_open(file).await?;
        let v = self
            .transport
            .request(
                "textDocument/hover",
                json!({
                    "textDocument": { "uri": uri },
                    "position": { "line": line, "character": character },
                }),
            )
            .await?;
        if v.is_null() {
            return Ok(None);
        }
        let contents = v.get("contents");
        let text = match contents {
            Some(Value::String(s)) => Some(s.clone()),
            Some(Value::Object(map)) => map.get("value").and_then(|x| x.as_str()).map(String::from),
            _ => None,
        };
        Ok(text)
    }

    /// 查询 Godot 原生类的文档。
    ///
    /// 这是 Godot LSP 的扩展方法（非标准 LSP），
    /// 可以查询 Node、Vector2 等内置类的成员说明。
    pub async fn native_symbol(&self, native_class: &str, member: Option<&str>) -> Result<Value> {
        self.transport
            .request(
                "textDocument/nativeSymbol",
                json!({
                    "native_class": native_class,
                    "symbol_name": member.unwrap_or(native_class),
                }),
            )
            .await
    }

    /// 解析符号路径（如 player.gd:Player.health）为行列号。
    ///
    /// 【流程】
    /// 1. 获取文件的符号列表（document_symbols）
    /// 2. 如果是单段路径（如 health），在顶层和子层中查找
    /// 3. 如果是多段路径（如 Player.health），逐层深入 children 查找
    /// 4. 返回找到的 Position 和符号名称
    pub async fn resolve_symbol_path(
        &self,
        file: &Path,
        segments: &[String],
    ) -> Result<(Position, String)> {
        let symbols = self.document_symbols(file).await?;
        let arr = symbols.as_array().cloned().unwrap_or_default();
        if arr.is_empty() {
            return Err(anyhow!("No symbols found in file"));
        }

        if segments.len() == 1 {
            self.resolve_single_segment_path(&arr, &segments[0])
        } else {
            self.resolve_multi_segment_path(&arr, segments)
        }
    }

    /// 解析单段符号路径。
    ///
    /// 先在顶层符号中查找，找不到再在子符号中查找。
    /// 如果还找不到，根据相似度给出建议（"Did you mean: ...?"）。
    fn resolve_single_segment_path(
        &self,
        symbols: &[Value],
        segment: &str,
    ) -> Result<(Position, String)> {
        // 尝试在顶层符号中查找
        if let Some(result) = find_symbol_in_list(symbols, segment) {
            return Ok(result);
        }

        // 尝试在顶层符号的子符号中查找
        for sym in symbols {
            let children = sym.get("children").and_then(|x| x.as_array()).cloned().unwrap_or_default();
            if let Some(result) = find_symbol_in_list(&children, segment) {
                return Ok(result);
            }
        }

        // 找不到，提供相似名称的建议
        let candidates = collect_all_symbol_names(symbols);
        let suggestions = find_similar(segment, &candidates);
        if suggestions.is_empty() {
            Err(anyhow!(
                "Symbol '{}' not found. Available symbols: {}",
                segment,
                candidates.join(", ")
            ))
        } else {
            Err(anyhow!(
                "Symbol '{}' not found. Did you mean: {}?",
                segment,
                suggestions.join(", ")
            ))
        }
    }

    /// 解析多段符号路径（逐层深入）。
    ///
    /// 例如 Player.stats.health：
    /// 第 1 层找 Player，第 2 层找 stats，第 3 层找 health。
    /// 每一层都在上一层符号的 children 中查找。
    fn resolve_multi_segment_path(
        &self,
        symbols: &[Value],
        segments: &[String],
    ) -> Result<(Position, String)> {
        let mut current_symbols = symbols.to_vec();

        for (i, segment) in segments.iter().enumerate() {
            let (sym, found_name) = find_symbol_with_candidates(&current_symbols, segment, i)?;

            if i < segments.len() - 1 {
                // 还没到最后一层，继续深入 children
                current_symbols = sym
                    .get("children")
                    .and_then(|x| x.as_array())
                    .cloned()
                    .unwrap_or_default();
            } else {
                // 最后一层：取 selectionRange 的起始位置作为结果
                let selection_range = sym
                    .get("selectionRange")
                    .ok_or_else(|| anyhow!("Symbol '{}' has no selectionRange", segment))?;
                let range: Range = serde_json::from_value(selection_range.clone())?;
                return Ok((range.start, found_name));
            }
        }

        Err(anyhow!("Unexpected end of symbol path"))
    }

    /// 获取诊断信息。
    ///
    /// 如果指定了文件，返回该文件的诊断列表；
    /// 如果没有指定文件，返回所有缓存的诊断信息。
    pub async fn diagnostics_for(
        &self,
        file: Option<&Path>,
    ) -> DiagnosticsResult {
        let map = self.diagnostics.lock().await.clone();
        match file {
            Some(p) => {
                let uri = file_to_uri(p);
                DiagnosticsResult::Single(map.get(&uri).cloned().unwrap_or_default())
            }
            None => DiagnosticsResult::All(map),
        }
    }
}

// ==================== 诊断结果枚举 ====================

/// 【DiagnosticsResult — 诊断查询结果】
///
/// Single：查询单个文件的结果
/// All：查询所有文件的结果（文件名 URI → 诊断列表的映射）
pub enum DiagnosticsResult {
    Single(Vec<Diagnostic>),
    All(HashMap<String, Vec<Diagnostic>>),
}

// ==================== 相似字符串匹配 ====================

/// 在候选列表中查找与目标字符串相似的项。
///
/// 【匹配规则】（按优先级）
/// 1. 子串匹配：候选包含目标，或目标包含候选
/// 2. 编辑距离（Levenshtein distance）≤ 40% 长度
///
/// 结果按字母序排序，最多返回 3 个建议。
fn find_similar(target: &str, candidates: &[String]) -> Vec<String> {
    let target_lower = target.to_lowercase();
    let mut suggestions = Vec::new();

    for candidate in candidates {
        let candidate_lower = candidate.to_lowercase();

        if candidate_lower.contains(&target_lower) || target_lower.contains(&candidate_lower) {
            suggestions.push(candidate.clone());
            continue;
        }

        let distance = levenshtein_distance(&target_lower, &candidate_lower);
        let max_len = target.len().max(candidate.len());
        if max_len > 0 && distance as f64 / max_len as f64 <= 0.4 {
            suggestions.push(candidate.clone());
        }
    }

    suggestions.sort();
    suggestions.truncate(3);
    suggestions
}

/// 计算两个字符串的莱文斯坦编辑距离。
///
/// 【编辑距离】
/// 指把一个字符串变成另一个字符串所需的最少单字符编辑次数
///（插入、删除、替换）。
///
/// 【动态规划算法】
/// 用一个 (len1+1) × (len2+1) 的矩阵 dp[i][j] 表示
/// s1 前 i 个字符变成 s2 前 j 个字符的最小编辑次数。
/// 递推公式：
///   dp[i][j] = min(
///       dp[i-1][j]   + 1,   // 删除 s1[i-1]
///       dp[i][j-1]   + 1,   // 插入 s2[j-1]
///       dp[i-1][j-1] + cost // 替换（如果相同则 cost=0）
///   )
fn levenshtein_distance(s1: &str, s2: &str) -> usize {
    let len1 = s1.len();
    let len2 = s2.len();
    let mut matrix = vec![vec![0; len2 + 1]; len1 + 1];

    for i in 0..=len1 {
        matrix[i][0] = i;
    }
    for j in 0..=len2 {
        matrix[0][j] = j;
    }

    for (i, c1) in s1.chars().enumerate() {
        for (j, c2) in s2.chars().enumerate() {
            let cost = if c1 == c2 { 0 } else { 1 };
            matrix[i + 1][j + 1] = (matrix[i][j + 1] + 1)
                .min(matrix[i + 1][j] + 1)
                .min(matrix[i][j] + cost);
        }
    }

    matrix[len1][len2]
}

// ==================== 符号查找辅助函数 ====================

/// 在符号列表中按名称查找。
///
/// 返回该符号的 selectionRange.start（位置）和名称。
fn find_symbol_in_list(symbols: &[Value], name: &str) -> Option<(Position, String)> {
    for sym in symbols {
        let sym_name = sym.get("name").and_then(|x| x.as_str()).unwrap_or("");
        if sym_name == name {
            let selection_range = sym.get("selectionRange")?;
            let range: Range = serde_json::from_value(selection_range.clone()).ok()?;
            return Some((range.start, sym_name.to_string()));
        }
    }
    None
}

/// 在符号列表中查找指定名称，找不到时返回相似建议和错误。
///
/// level 参数用于错误消息，表示当前在符号路径的第几层。
fn find_symbol_with_candidates(
    symbols: &[Value],
    segment: &str,
    level: usize,
) -> Result<(Value, String)> {
    let mut candidates = Vec::new();

    for sym in symbols {
        let name = sym.get("name").and_then(|x| x.as_str()).unwrap_or("");
        candidates.push(name.to_string());
        if name == segment {
            let name = name.to_string();
            return Ok((sym.clone(), name));
        }
    }

    if candidates.is_empty() {
        return Err(anyhow!("No symbols found at level {}", level));
    }

    let suggestions = find_similar(segment, &candidates);
    if suggestions.is_empty() {
        Err(anyhow!(
            "Symbol '{}' not found. Available symbols: {}",
            segment,
            candidates.join(", ")
        ))
    } else {
        Err(anyhow!(
            "Symbol '{}' not found. Did you mean: {}?",
            segment,
            suggestions.join(", ")
        ))
    }
}

/// 收集符号列表中所有顶层和子层的符号名称。
fn collect_all_symbol_names(symbols: &[Value]) -> Vec<String> {
    let mut candidates = Vec::new();
    for sym in symbols {
        let name = sym.get("name").and_then(|x| x.as_str()).unwrap_or("");
        candidates.push(name.to_string());
        let children = sym.get("children").and_then(|x| x.as_array()).cloned().unwrap_or_default();
        for child in &children {
            let name = child.get("name").and_then(|x| x.as_str()).unwrap_or("");
            candidates.push(name.to_string());
        }
    }
    candidates
}

// ==================== 单元测试 ====================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_levenshtein_distance() {
        assert_eq!(levenshtein_distance("kitten", "sitting"), 3);
        assert_eq!(levenshtein_distance("hello", "hello"), 0);
        assert_eq!(levenshtein_distance("", "abc"), 3);
        assert_eq!(levenshtein_distance("abc", ""), 3);
    }

    #[test]
    fn test_find_similar_exact_match() {
        let candidates = vec![
            "health".to_string(),
            "damage".to_string(),
            "speed".to_string(),
        ];
        let suggestions = find_similar("health", &candidates);
        assert!(suggestions.contains(&"health".to_string()));
    }

    #[test]
    fn test_find_similar_partial_match() {
        let candidates = vec![
            "health".to_string(),
            "damage".to_string(),
            "speed".to_string(),
        ];
        let suggestions = find_similar("heal", &candidates);
        assert!(suggestions.contains(&"health".to_string()));
    }

    #[test]
    fn test_find_similar_typo() {
        let candidates = vec![
            "health".to_string(),
            "damage".to_string(),
            "speed".to_string(),
        ];
        let suggestions = find_similar("healht", &candidates);
        assert!(suggestions.contains(&"health".to_string()));
    }

    #[test]
    fn test_find_similar_no_match() {
        let candidates = vec![
            "health".to_string(),
            "damage".to_string(),
            "speed".to_string(),
        ];
        let suggestions = find_similar("xyz", &candidates);
        assert!(suggestions.is_empty());
    }

    #[test]
    fn test_find_similar_limits_to_three() {
        let candidates = vec![
            "health".to_string(),
            "healthy".to_string(),
            "heal".to_string(),
            "healer".to_string(),
            "healing".to_string(),
        ];
        let suggestions = find_similar("heal", &candidates);
        assert!(suggestions.len() <= 3);
    }
}
