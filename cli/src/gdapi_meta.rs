use anyhow::{anyhow, Result};
use serde::Deserialize;
use std::path::Path;

#[derive(Debug, Deserialize)]
pub struct GdApiMeta {
    pub http_port: u16,
    #[serde(default)]
    pub lsp_port: Option<u16>,
    #[allow(dead_code)]
    pub pid: Option<u32>,
    #[allow(dead_code)]
    #[serde(default)]
    pub gdapi_version: Option<String>,
}

pub fn read(project_root: &Path) -> Result<GdApiMeta> {
    let p = project_root.join(".godot").join("gdapi.json");
    let s = std::fs::read_to_string(&p)
        .map_err(|e| anyhow!("cannot read {}: {}", p.display(), e))?;
    serde_json::from_str(&s).map_err(|e| anyhow!("parse {}: {}", p.display(), e))
}
