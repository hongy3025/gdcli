use crate::transport::{LspTransport, Notification};
use crate::types::{file_to_uri, Diagnostic, Location, Position, Range, WorkspaceEdit};
use anyhow::{anyhow, Result};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;

pub struct GodotLspClient {
    transport: Arc<LspTransport>,
    initialized: AtomicBool,
    diagnostics: Arc<Mutex<HashMap<String, Vec<Diagnostic>>>>,
    opened_files: Mutex<HashSet<String>>,
    server_capabilities: Mutex<Value>,
}

impl GodotLspClient {
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

    pub async fn server_capabilities(&self) -> Value {
        self.server_capabilities.lock().await.clone()
    }

    pub async fn disconnect(&self) {
        if self.initialized.load(Ordering::SeqCst) {
            let _ = self.transport.notify("shutdown", json!(null)).await;
        }
        self.transport.shutdown().await;
    }

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

    pub async fn document_symbols(&self, file: &Path) -> Result<Value> {
        let uri = self.ensure_open(file).await?;
        self.transport
            .request(
                "textDocument/documentSymbol",
                json!({ "textDocument": { "uri": uri } }),
            )
            .await
    }

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

    fn resolve_single_segment_path(
        &self,
        symbols: &[Value],
        segment: &str,
    ) -> Result<(Position, String)> {
        // Try to find in top-level symbols
        if let Some(result) = find_symbol_in_list(symbols, segment) {
            return Ok(result);
        }

        // Try to find in children of top-level symbols
        for sym in symbols {
            let children = sym.get("children").and_then(|x| x.as_array()).cloned().unwrap_or_default();
            if let Some(result) = find_symbol_in_list(&children, segment) {
                return Ok(result);
            }
        }

        // If not found, provide suggestions
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

    fn resolve_multi_segment_path(
        &self,
        symbols: &[Value],
        segments: &[String],
    ) -> Result<(Position, String)> {
        let mut current_symbols = symbols.to_vec();
        let mut found_name = String::new();

        for (i, segment) in segments.iter().enumerate() {
            let (sym, name) = find_symbol_with_candidates(&current_symbols, segment, i)?;
            found_name = name;

            if i < segments.len() - 1 {
                current_symbols = sym
                    .get("children")
                    .and_then(|x| x.as_array())
                    .cloned()
                    .unwrap_or_default();
            } else {
                let selection_range = sym
                    .get("selectionRange")
                    .ok_or_else(|| anyhow!("Symbol '{}' has no selectionRange", segment))?;
                let range: Range = serde_json::from_value(selection_range.clone())?;
                return Ok((range.start, found_name));
            }
        }

        Err(anyhow!("Unexpected end of symbol path"))
    }

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

pub enum DiagnosticsResult {
    Single(Vec<Diagnostic>),
    All(HashMap<String, Vec<Diagnostic>>),
}

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
