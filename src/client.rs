use crate::transport::{LspTransport, Notification};
use crate::types::{file_to_uri, Diagnostic, Location, Range, WorkspaceEdit};
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
            server_capabilities: Mutex::new(Value::Null),
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
        let caps = result.get("capabilities").cloned().unwrap_or(Value::Null);
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

// 让 Range 可在外部模块使用
pub use crate::types::Range as ClientRange;
