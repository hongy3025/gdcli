# 阶段 1：gdapi 端到端最小联通 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 跑通 `gdcli exec ping` → Rust HTTP server (gdapi) → GDScript router → 内置 `/ping` 路由 → 响应回 stdout 的完整链路。

**架构：** 把现有 gdcli 仓库改造成 Cargo workspace（`cli/` + `gdapi/rust/`），新增极薄的 Rust GDExtension（tokio HTTP server + 跨线程队列），GDScript 侧实现 plugin 入口与路由器，新增 `gdcli exec` 子命令通过 ureq 同步 HTTP 调用。**本阶段不实现 install 命令、不实现项目根自动检测、不重构现有 LSP 命令、不迁移 godot-mcp 路由。** 验证标准：在一个手动安装了 addon 的 fixture 项目中启动 Godot，跑 `gdcli exec ping --project <fixture>` 拿到 `{"ok":true,...}`。

**技术栈：** Rust 2021 / godot-rust 0.5 (api-4-3) / tokio 1 / httparse 1 / ureq 2 / clap 4 / serde_json 1 / GDScript（Godot 4.3+）。

---

## 文件结构

**新建：**
- `Cargo.toml`（workspace 根，替换现有 package 配置）
- `cli/Cargo.toml`
- `cli/src/main.rs`（迁入现有 `src/main.rs`，新增 `exec` 子命令）
- `cli/src/lsp/mod.rs`、`cli/src/lsp/client.rs` 等（现有 `src/*.rs` 迁入）
- `cli/src/exec.rs`（新：exec 子命令实现）
- `cli/src/gdapi_meta.rs`（新：`.godot/gdapi.json` 读取）
- `gdapi/rust/Cargo.toml`
- `gdapi/rust/src/lib.rs`（GodotClass `GdApiServer` 入口）
- `gdapi/rust/src/server.rs`（tokio runtime + accept loop）
- `gdapi/rust/src/http.rs`（httparse 封装 + 响应写出）
- `gdapi/rust/src/queue.rs`（PendingRequest + 响应路由数据结构）
- `gdapi/addon/plugin.cfg`
- `gdapi/addon/plugin.gd`（EditorPlugin 入口）
- `gdapi/addon/gdapi.gdextension`
- `gdapi/addon/runtime/router.gd`
- `gdapi/addon/runtime/route_handler.gd`
- `gdapi/addon/runtime/builtin_ping.gd`（内置 `/ping` 处理）
- `gdapi/addon/runtime/builtin_routes.gd`（内置 `/routes` 处理）
- `gdapi/addon/routes/.gitkeep`（保留目录但本阶段无用户路由）
- `tests/fixture_project/project.godot`（fixture）
- `tests/fixture_project/addons/`（拷贝/链接 addon 用于 e2e）
- `scripts/e2e-ping.sh`（本地端到端验证脚本）

**迁移（git mv）：**
- `src/main.rs` → `cli/src/main.rs`
- `src/client.rs` → `cli/src/lsp/client.rs`
- `src/transport.rs` → `cli/src/lsp/transport.rs`
- `src/types.rs` → `cli/src/lsp/types.rs`
- `src/symbol_path.rs` → `cli/src/lsp/symbol_path.rs`
- `tests/` 现有内容 → `cli/tests/`

**修改：**
- 现有 `Cargo.toml` → 改为 workspace 根（package 字段下沉到 `cli/Cargo.toml`）
- `.gitignore`：新增 `gdapi/rust/target/`、`gdapi/addon/bin/`

**职责边界：**
- `gdapi/rust/src/lib.rs`：只声明 GodotClass + `#[gdextension]` 入口，不放业务
- `gdapi/rust/src/server.rs`：tokio runtime 管理 + accept loop，不解析 HTTP
- `gdapi/rust/src/http.rs`：HTTP 请求解析（httparse 封装）+ 响应字节序列化
- `gdapi/rust/src/queue.rs`：定义 `PendingRequest`、`HttpResponse` 类型 + pending map 管理
- `cli/src/exec.rs`：只负责发 HTTP 与处理退出码，不解析 `.godot/gdapi.json`
- `cli/src/gdapi_meta.rs`：只负责读 `.godot/gdapi.json`

---

## 关键技术约定

**workspace 顶层版本：** `[workspace.package] version = "0.2.0"`，子 crate 用 `version.workspace = true`。

**GdApiServer 暴露给 GDScript 的最终签名（其他任务以此为契约）：**
```rust
fn create() -> Gd<Self>
fn start(&mut self, port_hint: u16) -> i32       // 成功:实际端口；失败:-1
fn stop(&mut self)
fn is_running(&self) -> bool
fn port(&self) -> i32                            // -1 表示未启动
fn poll_request(&mut self) -> Variant            // null 或 Dictionary
fn send_response(&mut self, id: i64, status: i64, headers: Dictionary, body: PackedByteArray)
```

**poll_request 返回的 Dictionary 字段（契约）：**
```
{
  "id":      int,            // 请求标识，必须传回给 send_response
  "method":  String,
  "path":    String,
  "headers": Dictionary,     // key/value 均 String，header name 全小写
  "body":    PackedByteArray
}
```

**`.godot/gdapi.json` 本阶段写入字段：**（lsp_port 字段本阶段先写入但不被使用）
```json
{
  "http_port": 7891,
  "lsp_port": 6005,
  "pid": 12345,
  "started_at": "2026-06-23T10:00:00",
  "gdapi_version": "0.2.0"
}
```

**Godot 版本约束：** 设计目标 4.3+，开发与 e2e 用 4.3。

---

## 任务 1：Workspace 改造与 gdcli 子 crate 化

**文件：**
- 修改：`Cargo.toml`（根）
- 创建：`cli/Cargo.toml`
- 移动：`src/` → `cli/src/`（含子目录重组）
- 移动：`tests/` → `cli/tests/`

- [ ] **步骤 1：备份并查看现有 Cargo.toml**

运行：`Get-Content Cargo.toml`
确认包含 `[package] name = "gdcli"` 等现有内容。

- [ ] **步骤 2：移动源码到 cli/ 子目录**

运行：
```powershell
git mv src cli/src-tmp
New-Item -ItemType Directory -Path cli/src
Move-Item cli/src-tmp/main.rs cli/src/main.rs
New-Item -ItemType Directory -Path cli/src/lsp
Move-Item cli/src-tmp/client.rs cli/src/lsp/client.rs
Move-Item cli/src-tmp/transport.rs cli/src/lsp/transport.rs
Move-Item cli/src-tmp/types.rs cli/src/lsp/types.rs
Move-Item cli/src-tmp/symbol_path.rs cli/src/lsp/symbol_path.rs
Remove-Item cli/src-tmp
git mv tests cli/tests
```

**注意：** 本阶段**不**修改 `cli/src/main.rs` 内部逻辑（即所有现有顶层 LSP 命令仍然顶层）。CLI 重构在阶段 3 完成。本阶段只是把 `main.rs` 物理迁入 `cli/`，并新增一个并列的 `exec` 子命令。

- [ ] **步骤 3：调整 main.rs 的 mod 声明**

修改 `cli/src/main.rs`，把：
```rust
mod client;
mod symbol_path;
mod transport;
mod types;
```
改为：
```rust
mod lsp;
mod exec;
mod gdapi_meta;

use lsp::client::{DiagnosticsResult, GodotLspClient};
use lsp::types::{uri_to_file, symbol_kind_name, Diagnostic, Location, Range, WorkspaceEdit};
```
并搜索文件内所有 `crate::client::` / `crate::types::` / `crate::symbol_path::` 引用，改为 `crate::lsp::client::` 等。

新建 `cli/src/lsp/mod.rs`：
```rust
pub mod client;
pub mod symbol_path;
pub mod transport;
pub mod types;
```

注意 `cli/src/lsp/client.rs` 内部对 `crate::transport`、`crate::types`、`crate::symbol_path` 的引用要全部改为 `crate::lsp::transport` 等。同理 `transport.rs`、`symbol_path.rs`、`types.rs` 内的 cross-module 引用。

- [ ] **步骤 4：创建 workspace 根 Cargo.toml**

完整内容：
```toml
[workspace]
resolver = "2"
members = ["cli", "gdapi/rust"]

[workspace.package]
version = "0.2.0"
edition = "2021"
license = "MIT"

[profile.release]
lto = true
strip = true
opt-level = "z"
codegen-units = 1
```

注：edition 从原来的 "2024" 降为 "2021"，因为 godot-rust 0.5 与 2024 edition 暂未完整兼容。

- [ ] **步骤 5：创建 cli/Cargo.toml**

完整内容：
```toml
[package]
name = "gdcli"
version.workspace = true
edition.workspace = true
license.workspace = true
description = "CLI for Godot editor: LSP client + HTTP exec via gdapi addon"

[[bin]]
name = "gdcli"
path = "src/main.rs"

[dependencies]
tokio = { version = "1", features = ["macros", "rt-multi-thread", "net", "io-util", "sync", "time", "fs"] }
clap = { version = "4", features = ["derive"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
anyhow = "1"
percent-encoding = "2"
bytes = "1"
ureq = { version = "2", default-features = false, features = ["json"] }

[dev-dependencies]
assert_cmd = "2"
predicates = "3"
tempfile = "3"
tokio = { version = "1", features = ["macros", "rt-multi-thread", "net", "io-util", "sync", "time"] }
httpmock = "0.7"
```

- [ ] **步骤 6：删除根 Cargo.toml 中旧的 package 配置**

打开根 `Cargo.toml`，删除 `[package]`、`[[bin]]`、`[dependencies]`、`[dev-dependencies]`、`[profile.release]` 旧条目（已迁入 cli/Cargo.toml 和 workspace 段）。验证根 Cargo.toml 现在只含步骤 4 的内容。

- [ ] **步骤 7：编写 cli/src/exec.rs 与 cli/src/gdapi_meta.rs 的占位**

`cli/src/exec.rs`：
```rust
//! gdcli exec 子命令的占位实现（阶段 1 完整实现）
use anyhow::Result;
use std::path::Path;

pub fn run(_project: &Path, _command: &str, _data: Option<&str>, _timeout_secs: u64) -> Result<()> {
    anyhow::bail!("exec not yet implemented")
}
```

`cli/src/gdapi_meta.rs`：
```rust
//! 读取 .godot/gdapi.json
use anyhow::{anyhow, Result};
use serde::Deserialize;
use std::path::Path;

#[derive(Debug, Deserialize)]
pub struct GdApiMeta {
    pub http_port: u16,
    #[serde(default)]
    pub lsp_port: Option<u16>,
    pub pid: Option<u32>,
    #[serde(default)]
    pub gdapi_version: Option<String>,
}

pub fn read(project_root: &Path) -> Result<GdApiMeta> {
    let p = project_root.join(".godot").join("gdapi.json");
    let s = std::fs::read_to_string(&p)
        .map_err(|e| anyhow!("cannot read {}: {}", p.display(), e))?;
    serde_json::from_str(&s).map_err(|e| anyhow!("parse {}: {}", p.display(), e))
}
```

- [ ] **步骤 8：验证编译通过**

运行：`cargo build -p gdcli`
预期：编译成功，输出 `Compiling gdcli v0.2.0 ...` 与 `Finished dev ...`
若有 `crate::client::` 等遗漏的旧引用，按编译错误位置改成 `crate::lsp::client::` 等。

- [ ] **步骤 9：验证现有测试仍通过**

运行：`cargo test -p gdcli`
预期：所有现有测试通过（包括 `parse_target_position_mode` 等）。

- [ ] **步骤 10：Commit**

```bash
git add -A
git commit -m "refactor: convert to cargo workspace, move gdcli into cli/ crate"
```

---

## 任务 2：gdapi Rust crate 骨架与 GodotClass 入口

**文件：**
- 创建：`gdapi/rust/Cargo.toml`
- 创建：`gdapi/rust/src/lib.rs`
- 创建：`gdapi/rust/src/queue.rs`
- 创建：`gdapi/rust/src/http.rs`（占位）
- 创建：`gdapi/rust/src/server.rs`（占位）

- [ ] **步骤 1：创建 gdapi/rust/Cargo.toml**

```toml
[package]
name = "gdapi"
version.workspace = true
edition.workspace = true
license.workspace = true

[lib]
crate-type = ["cdylib"]
name = "gdapi"

[dependencies]
godot = { version = "0.5", features = ["api-4-3"] }
tokio = { version = "1", features = ["rt-multi-thread", "net", "io-util", "sync", "macros", "time"] }
httparse = "1"
```

- [ ] **步骤 2：创建 gdapi/rust/src/queue.rs**

```rust
//! 跨线程请求 / 响应数据结构。
//!
//! `PendingRequest` 由 tokio task 创建，通过 mpsc 发到主线程；
//! 主线程处理完后用 `send_response` 找到对应的 `oneshot::Sender` 回填 `HttpResponse`。

use std::collections::HashMap;
use tokio::sync::oneshot;

#[derive(Debug)]
pub struct PendingRequest {
    pub id: u64,
    pub method: String,
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    pub resp_tx: oneshot::Sender<HttpResponse>,
}

#[derive(Debug, Clone)]
pub struct HttpResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

/// 主线程持有：id -> resp_tx 映射。
/// poll_request 返回请求时，把 resp_tx 从 PendingRequest 取出存进 map；
/// send_response 时按 id 取出并发送，自动从 map 移除。
#[derive(Default)]
pub struct PendingMap {
    inner: HashMap<u64, oneshot::Sender<HttpResponse>>,
}

impl PendingMap {
    pub fn insert(&mut self, id: u64, tx: oneshot::Sender<HttpResponse>) {
        self.inner.insert(id, tx);
    }

    pub fn take(&mut self, id: u64) -> Option<oneshot::Sender<HttpResponse>> {
        self.inner.remove(&id)
    }

    pub fn drain_503(&mut self) {
        for (_, tx) in self.inner.drain() {
            let _ = tx.send(HttpResponse {
                status: 503,
                headers: vec![("content-type".into(), "application/json".into())],
                body: br#"{"error":"server shutting down"}"#.to_vec(),
            });
        }
    }
}
```

- [ ] **步骤 3：创建 gdapi/rust/src/http.rs 占位**

```rust
//! HTTP/1.1 请求解析与响应序列化。完整实现见任务 3。

use std::io;

pub fn write_response(_status: u16, _headers: &[(String, String)], _body: &[u8]) -> Vec<u8> {
    unimplemented!("filled in task 3")
}

pub fn parse_request(_buf: &[u8]) -> io::Result<Option<crate::queue::PendingRequest>> {
    unimplemented!("filled in task 3")
}
```

- [ ] **步骤 4：创建 gdapi/rust/src/server.rs 占位**

```rust
//! tokio runtime + accept loop。完整实现见任务 4。
```

- [ ] **步骤 5：创建 gdapi/rust/src/lib.rs**

```rust
//! gdapi — Godot editor 内的 HTTP API GDExtension。
//!
//! Rust 层职责（极薄）：
//!   1. 启动 tokio runtime，绑定端口监听
//!   2. HTTP/1.1 解析（请求行 + headers + body）
//!   3. 把请求推入 mpsc 队列；主线程 poll；处理完用 oneshot 回填
//!   4. 写回 HTTP 响应
//!
//! GDScript 层职责：JSON 解析、路由匹配、业务逻辑、错误处理。

mod queue;
mod http;
mod server;

use godot::prelude::*;

struct GdApiExtension;

#[gdextension]
unsafe impl ExtensionLibrary for GdApiExtension {}

/// 暴露给 GDScript 的核心类。所有方法都是 #[func]。
#[derive(GodotClass)]
#[class(base=RefCounted, no_init)]
pub struct GdApiServer {
    // 实际字段在任务 4 填充
    _placeholder: (),
}

#[godot_api]
impl GdApiServer {
    #[func]
    fn create() -> Gd<Self> {
        Gd::from_object(Self { _placeholder: () })
    }

    #[func]
    fn start(&mut self, _port_hint: u16) -> i32 {
        godot_error!("[gdapi] start() not yet implemented");
        -1
    }

    #[func]
    fn stop(&mut self) {}

    #[func]
    fn is_running(&self) -> bool {
        false
    }

    #[func]
    fn port(&self) -> i32 {
        -1
    }

    #[func]
    fn poll_request(&mut self) -> Variant {
        Variant::nil()
    }

    #[func]
    fn send_response(
        &mut self,
        _id: i64,
        _status: i64,
        _headers: Dictionary,
        _body: PackedByteArray,
    ) {
    }
}
```

- [ ] **步骤 6：验证 gdapi 编译通过**

运行：`cargo build -p gdapi`
预期：编译成功，产物在 `target/debug/gdapi.dll`（Windows）或 `libgdapi.{dylib,so}`。
若 godot-rust 编译报错（缺 LLVM 等），按提示安装依赖；如确认环境支持但仍失败，记录到本任务的"已知问题"并 commit。

- [ ] **步骤 7：Commit**

```bash
git add -A
git commit -m "feat(gdapi): scaffold rust gdextension with godot-rust GodotClass skeleton"
```

---

## 任务 3：HTTP 协议解析与响应序列化（含单元测试）

**文件：**
- 修改：`gdapi/rust/src/http.rs`（替换占位为完整实现）
- 修改：`gdapi/rust/Cargo.toml`（添加 dev-dependencies）

- [ ] **步骤 1：编写测试先行**

替换 `gdapi/rust/src/http.rs` 末尾添加 tests 模块（占位实现保留稍后替换）：

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_minimal_get() {
        let buf = b"GET /ping HTTP/1.1\r\nHost: x\r\n\r\n";
        let parsed = parse_request(buf).unwrap().unwrap();
        assert_eq!(parsed.method, "GET");
        assert_eq!(parsed.path, "/ping");
        assert_eq!(parsed.body.len(), 0);
    }

    #[test]
    fn parse_post_with_body() {
        let mut buf: Vec<u8> = b"POST /scene/create HTTP/1.1\r\nHost: x\r\nContent-Length: 13\r\n\r\n".to_vec();
        buf.extend_from_slice(br#"{"foo":"bar"}"#);
        let parsed = parse_request(&buf).unwrap().unwrap();
        assert_eq!(parsed.method, "POST");
        assert_eq!(parsed.path, "/scene/create");
        assert_eq!(parsed.body, br#"{"foo":"bar"}"#.to_vec());
    }

    #[test]
    fn parse_incomplete_returns_none() {
        let buf = b"POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nshort";
        let result = parse_request(buf).unwrap();
        assert!(result.is_none(), "expected incomplete to return None");
    }

    #[test]
    fn parse_malformed_errors() {
        let buf = b"NOTAREQUEST\r\n\r\n";
        let result = parse_request(buf);
        assert!(result.is_err());
    }

    #[test]
    fn parse_body_too_large_errors() {
        let big_len = 17 * 1024 * 1024;
        let buf = format!("POST /x HTTP/1.1\r\nContent-Length: {}\r\n\r\n", big_len);
        let result = parse_request(buf.as_bytes());
        assert!(result.is_err(), "expected body-too-large error");
    }

    #[test]
    fn header_names_are_lowercased() {
        let buf = b"POST /x HTTP/1.1\r\nContent-Type: application/json\r\nX-Foo: Bar\r\n\r\n";
        let parsed = parse_request(buf).unwrap().unwrap();
        let names: Vec<&str> = parsed.headers.iter().map(|(k, _)| k.as_str()).collect();
        assert!(names.contains(&"content-type"));
        assert!(names.contains(&"x-foo"));
    }

    #[test]
    fn write_response_basic() {
        let bytes = write_response(200, &[("content-type".into(), "application/json".into())], b"{}");
        let s = String::from_utf8_lossy(&bytes);
        assert!(s.starts_with("HTTP/1.1 200 OK\r\n"));
        assert!(s.contains("content-type: application/json\r\n"));
        assert!(s.contains("content-length: 2\r\n"));
        assert!(s.contains("connection: close\r\n"));
        assert!(s.ends_with("\r\n\r\n{}"));
    }

    #[test]
    fn write_response_413() {
        let bytes = write_response(413, &[], b"");
        let s = String::from_utf8_lossy(&bytes);
        assert!(s.starts_with("HTTP/1.1 413 Payload Too Large\r\n"));
    }
}
```

`parse_request` 的契约：
- 返回 `Ok(None)` = 数据不完整（请求头未收齐 或 body 长度不足），调用方应继续 read
- 返回 `Ok(Some(req))` = 解析成功（但 `req` 内的 `resp_tx` 由 server 任务在调用 parse 后才设置——见下方注意）
- 返回 `Err(_)` = 不可恢复错误（请求行非法、Content-Length > 16MB、header 数量超限）

**注意：测试中的 `PendingRequest` 不包含 `resp_tx`——为了便于测试，把"纯解析结果"抽成一个内部类型 `ParsedRequest`，`parse_request` 返回它；`server.rs` 再把 `ParsedRequest` 包成 `PendingRequest`（加 id 和 resp_tx）。** 据此调整测试与 API。

修正版接口：

```rust
#[derive(Debug, PartialEq)]
pub struct ParsedRequest {
    pub method: String,
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

pub fn parse_request(buf: &[u8]) -> io::Result<Option<ParsedRequest>> { ... }
```

修改上面所有测试中 `parsed.body` / `parsed.method` 等仍正确（因为字段名同名）。

- [ ] **步骤 2：运行测试验证全部失败**

运行：`cargo test -p gdapi --lib http::tests`
预期：编译失败或全部测试 fail（占位 `unimplemented!()`）。

- [ ] **步骤 3：实现 http.rs**

完整替换 `gdapi/rust/src/http.rs`：

```rust
//! HTTP/1.1 请求解析与响应序列化（极简，仅服务 gdapi 的需求）。
//!
//! 解析特性：
//! - 仅支持 Content-Length（不支持 chunked transfer encoding）
//! - 不区分大小写：header name 全部转为小写
//! - Body 上限 16 MiB
//! - 不解析 query string（path 保留原样）

use std::io;

pub const MAX_BODY: usize = 16 * 1024 * 1024;
const MAX_HEADERS: usize = 64;

#[derive(Debug, PartialEq)]
pub struct ParsedRequest {
    pub method: String,
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

/// 解析 HTTP/1.1 请求。
///
/// 返回值：
///   Ok(None)     => 缓冲区数据不完整，调用方应继续 read 后再调
///   Ok(Some(r))  => 解析成功
///   Err(e)       => 不可恢复错误（应返回 400 并关闭连接）
pub fn parse_request(buf: &[u8]) -> io::Result<Option<ParsedRequest>> {
    let mut headers = [httparse::EMPTY_HEADER; MAX_HEADERS];
    let mut req = httparse::Request::new(&mut headers);
    let status = req.parse(buf).map_err(|e| {
        io::Error::new(io::ErrorKind::InvalidData, format!("http parse: {:?}", e))
    })?;
    let header_end = match status {
        httparse::Status::Complete(n) => n,
        httparse::Status::Partial => return Ok(None),
    };
    let method = req.method.ok_or_else(|| invalid("missing method"))?.to_string();
    let path = req.path.ok_or_else(|| invalid("missing path"))?.to_string();

    let mut hdrs: Vec<(String, String)> = Vec::with_capacity(req.headers.len());
    let mut content_length: usize = 0;
    for h in req.headers.iter() {
        let name_lc = h.name.to_ascii_lowercase();
        let value = std::str::from_utf8(h.value)
            .map_err(|_| invalid("non-utf8 header"))?
            .to_string();
        if name_lc == "content-length" {
            content_length = value
                .trim()
                .parse::<usize>()
                .map_err(|_| invalid("invalid Content-Length"))?;
        }
        hdrs.push((name_lc, value));
    }

    if content_length > MAX_BODY {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Content-Length exceeds 16 MiB",
        ));
    }

    let total_needed = header_end + content_length;
    if buf.len() < total_needed {
        return Ok(None);
    }

    let body = buf[header_end..total_needed].to_vec();
    Ok(Some(ParsedRequest {
        method,
        path,
        headers: hdrs,
        body,
    }))
}

/// 序列化为 HTTP/1.1 响应字节流。总是带 Connection: close 和 Content-Length。
pub fn write_response(status: u16, headers: &[(String, String)], body: &[u8]) -> Vec<u8> {
    let reason = reason_phrase(status);
    let mut out = Vec::with_capacity(128 + body.len());
    out.extend_from_slice(format!("HTTP/1.1 {} {}\r\n", status, reason).as_bytes());
    for (k, v) in headers {
        out.extend_from_slice(format!("{}: {}\r\n", k, v).as_bytes());
    }
    out.extend_from_slice(format!("content-length: {}\r\n", body.len()).as_bytes());
    out.extend_from_slice(b"connection: close\r\n");
    out.extend_from_slice(b"\r\n");
    out.extend_from_slice(body);
    out
}

fn invalid(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg.to_string())
}

fn reason_phrase(s: u16) -> &'static str {
    match s {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        _ => "",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_minimal_get() {
        let buf = b"GET /ping HTTP/1.1\r\nHost: x\r\n\r\n";
        let parsed = parse_request(buf).unwrap().unwrap();
        assert_eq!(parsed.method, "GET");
        assert_eq!(parsed.path, "/ping");
        assert!(parsed.body.is_empty());
    }

    #[test]
    fn parse_post_with_body() {
        let mut buf: Vec<u8> = b"POST /scene/create HTTP/1.1\r\nHost: x\r\nContent-Length: 13\r\n\r\n".to_vec();
        buf.extend_from_slice(br#"{"foo":"bar"}"#);
        let parsed = parse_request(&buf).unwrap().unwrap();
        assert_eq!(parsed.method, "POST");
        assert_eq!(parsed.path, "/scene/create");
        assert_eq!(parsed.body, br#"{"foo":"bar"}"#.to_vec());
    }

    #[test]
    fn parse_incomplete_returns_none() {
        let buf = b"POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nshort";
        let result = parse_request(buf).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn parse_partial_headers_returns_none() {
        let buf = b"POST /x HTTP/1.1\r\nHost: x";
        let result = parse_request(buf).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn parse_malformed_errors() {
        let buf = b"NOTAREQUEST\r\n\r\n";
        assert!(parse_request(buf).is_err());
    }

    #[test]
    fn parse_body_too_large_errors() {
        let big = 17 * 1024 * 1024;
        let buf = format!("POST /x HTTP/1.1\r\nContent-Length: {}\r\n\r\n", big);
        assert!(parse_request(buf.as_bytes()).is_err());
    }

    #[test]
    fn header_names_are_lowercased() {
        let buf = b"POST /x HTTP/1.1\r\nContent-Type: application/json\r\nX-Foo: Bar\r\n\r\n";
        let parsed = parse_request(buf).unwrap().unwrap();
        let names: Vec<&str> = parsed.headers.iter().map(|(k, _)| k.as_str()).collect();
        assert!(names.contains(&"content-type"));
        assert!(names.contains(&"x-foo"));
    }

    #[test]
    fn write_response_basic() {
        let bytes = write_response(200, &[("content-type".into(), "application/json".into())], b"{}");
        let s = String::from_utf8_lossy(&bytes);
        assert!(s.starts_with("HTTP/1.1 200 OK\r\n"));
        assert!(s.contains("content-type: application/json\r\n"));
        assert!(s.contains("content-length: 2\r\n"));
        assert!(s.contains("connection: close\r\n"));
        assert!(s.ends_with("\r\n\r\n{}"));
    }

    #[test]
    fn write_response_413() {
        let bytes = write_response(413, &[], b"");
        let s = String::from_utf8_lossy(&bytes);
        assert!(s.starts_with("HTTP/1.1 413 Payload Too Large\r\n"));
    }
}
```

- [ ] **步骤 4：运行测试验证全部通过**

运行：`cargo test -p gdapi --lib http::tests`
预期：8 个测试全部 PASS。

- [ ] **步骤 5：Commit**

```bash
git add -A
git commit -m "feat(gdapi): implement http/1.1 parser and response serializer"
```

---

## 任务 4：tokio HTTP server + GodotClass 完整实现（含集成测试）

**文件：**
- 修改：`gdapi/rust/src/server.rs`
- 修改：`gdapi/rust/src/lib.rs`
- 创建：`gdapi/rust/tests/server_e2e.rs`

- [ ] **步骤 1：编写集成测试（无 Godot 依赖）**

`gdapi/rust/Cargo.toml` 添加：
```toml
[dev-dependencies]
ureq = { version = "2", default-features = false }
tokio = { version = "1", features = ["macros", "rt-multi-thread", "time", "sync"] }
```

创建 `gdapi/rust/tests/server_e2e.rs`：

**测试目标：** 验证 server 内核——不通过 GDScript，直接用 Rust 调用 `start/poll_request/send_response/stop`，从外部用 `ureq` 发 HTTP 请求验证响应。

```rust
//! gdapi server 集成测试——不依赖 Godot。
//!
//! 由于 GdApiServer 内部用 godot::prelude::Gd 包裹，集成测试无法直接 new。
//! 解决：把 server 核心逻辑抽到 `gdapi::server::ServerCore`（非 GodotClass 的普通结构体），
//! GdApiServer 只是它的 Gd 包装。集成测试直接用 ServerCore。

use gdapi::server::ServerCore;
use std::thread;
use std::time::Duration;

#[test]
fn server_accepts_request_and_routes_to_poll_send() {
    let mut server = ServerCore::new();
    let port = server.start(17890).expect("start should succeed");
    assert!(port >= 17890 && port < 17890 + 64);

    // 在另一个线程模拟主线程的 poll/send 循环
    let handle = thread::spawn(move || {
        let url = format!("http://127.0.0.1:{}/ping", port);
        let resp = ureq::post(&url)
            .set("Content-Type", "application/json")
            .send_string(r#"{"hello":"world"}"#)
            .expect("http call failed");
        assert_eq!(resp.status(), 200);
        let body = resp.into_string().unwrap();
        assert!(body.contains("\"ok\":true"), "body was: {}", body);
        port
    });

    // 主线程 poll 直到拿到请求
    let mut got_request = false;
    for _ in 0..200 {
        if let Some(req) = server.poll_request_raw() {
            assert_eq!(req.method, "POST");
            assert_eq!(req.path, "/ping");
            assert!(req.body.len() > 0);
            server.send_response_raw(
                req.id,
                200,
                vec![("content-type".into(), "application/json".into())],
                br#"{"ok":true}"#.to_vec(),
            );
            got_request = true;
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }

    assert!(got_request, "did not receive request within timeout");
    handle.join().expect("client thread panicked");
    server.stop();
}

#[test]
fn server_port_probing_skips_occupied() {
    let mut a = ServerCore::new();
    let port_a = a.start(17900).expect("first start");

    let mut b = ServerCore::new();
    let port_b = b.start(17900).expect("second start should find next port");

    assert_eq!(port_a, 17900);
    assert!(port_b > port_a, "expected port probing, got {} vs {}", port_b, port_a);
    a.stop();
    b.stop();
}

#[test]
fn server_returns_413_for_oversized_body() {
    let mut server = ServerCore::new();
    let port = server.start(17910).expect("start");

    let handle = thread::spawn(move || {
        let url = format!("http://127.0.0.1:{}/big", port);
        let big = vec![b'a'; 17 * 1024 * 1024];
        let resp = ureq::post(&url)
            .set("content-type", "application/octet-stream")
            .send_bytes(&big);
        // ureq 在收到 4xx 时返回 Err(Status)
        match resp {
            Err(ureq::Error::Status(code, _)) => assert_eq!(code, 413),
            other => panic!("expected 413, got {:?}", other),
        }
    });

    // 给服务器一点时间处理拒绝
    thread::sleep(Duration::from_millis(500));
    handle.join().expect("client thread panicked");
    server.stop();
}

#[test]
fn server_504_on_handler_timeout() {
    // 缩短超时仅用于测试：通过 env var 注入
    std::env::set_var("GDAPI_HANDLER_TIMEOUT_MS", "300");
    let mut server = ServerCore::new();
    let port = server.start(17920).expect("start");

    let handle = thread::spawn(move || {
        let url = format!("http://127.0.0.1:{}/slow", port);
        let resp = ureq::post(&url).send_string("{}");
        match resp {
            Err(ureq::Error::Status(code, _)) => assert_eq!(code, 504),
            other => panic!("expected 504, got {:?}", other),
        }
    });

    // 主线程故意不调 send_response，让超时触发
    thread::sleep(Duration::from_millis(800));
    handle.join().expect("client thread panicked");
    server.stop();
    std::env::remove_var("GDAPI_HANDLER_TIMEOUT_MS");
}
```

注意：这些测试要求把 `GdApiServer` 的核心逻辑抽成可独立测试的 `ServerCore`（无 godot 类型依赖）。继续在 server.rs 中实现。

- [ ] **步骤 2：运行测试验证全部失败**

运行：`cargo test -p gdapi --test server_e2e`
预期：编译失败（`ServerCore` 等未定义）。

- [ ] **步骤 3：实现 server.rs**

完整内容：

```rust
//! tokio HTTP server + 跨线程请求队列。
//!
//! ServerCore 是与 godot 无关的核心，可独立测试；GdApiServer (lib.rs) 是其 Gd 包装。

use crate::http::{parse_request, write_response, ParsedRequest};
use crate::queue::{HttpResponse, PendingMap, PendingRequest};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::runtime::Runtime;
use tokio::sync::{mpsc, oneshot};

const PORT_PROBE_LIMIT: u16 = 64;
const DEFAULT_TIMEOUT_MS: u64 = 30_000;
const ACCEPT_READ_TIMEOUT_MS: u64 = 5_000;

pub struct ServerCore {
    runtime: Option<Runtime>,
    shutdown_tx: Option<oneshot::Sender<()>>,
    in_rx: Option<mpsc::Receiver<PendingRequest>>,
    pending: PendingMap,
    actual_port: Option<u16>,
}

impl Default for ServerCore {
    fn default() -> Self {
        Self::new()
    }
}

impl ServerCore {
    pub fn new() -> Self {
        Self {
            runtime: None,
            shutdown_tx: None,
            in_rx: None,
            pending: PendingMap::default(),
            actual_port: None,
        }
    }

    /// 从 port_hint 逐个 +1 尝试，最多 64 次。成功返回端口；失败返回 Err。
    pub fn start(&mut self, port_hint: u16) -> Result<u16, String> {
        if self.runtime.is_some() {
            return Err("already running".into());
        }
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|e| format!("tokio rt: {}", e))?;

        // bind 同步完成（在 rt.block_on 中），便于上报实际端口
        let listener = rt.block_on(async move {
            for offset in 0..PORT_PROBE_LIMIT {
                let port = port_hint + offset;
                match TcpListener::bind(("127.0.0.1", port)).await {
                    Ok(l) => return Ok((l, port)),
                    Err(_) => continue,
                }
            }
            Err("no available port in probe range".to_string())
        });
        let (listener, port) = match listener {
            Ok(x) => x,
            Err(e) => return Err(e),
        };

        let (in_tx, in_rx) = mpsc::channel::<PendingRequest>(256);
        let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();

        let timeout_ms: u64 = std::env::var("GDAPI_HANDLER_TIMEOUT_MS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(DEFAULT_TIMEOUT_MS);

        let id_counter = Arc::new(AtomicU64::new(1));
        rt.spawn(accept_loop(listener, in_tx, id_counter, timeout_ms, shutdown_rx));

        self.runtime = Some(rt);
        self.shutdown_tx = Some(shutdown_tx);
        self.in_rx = Some(in_rx);
        self.actual_port = Some(port);
        Ok(port)
    }

    pub fn stop(&mut self) {
        if let Some(tx) = self.shutdown_tx.take() {
            let _ = tx.send(());
        }
        self.pending.drain_503();
        if let Some(rt) = self.runtime.take() {
            // shutdown_background：不阻塞主线程
            rt.shutdown_background();
        }
        self.in_rx = None;
        self.actual_port = None;
    }

    pub fn is_running(&self) -> bool {
        self.runtime.is_some()
    }

    pub fn port(&self) -> i32 {
        self.actual_port.map(|p| p as i32).unwrap_or(-1)
    }

    /// 主线程 poll：非阻塞 try_recv。返回原始 PendingRequest 供测试用。
    pub fn poll_request_raw(&mut self) -> Option<PendingRequest> {
        let rx = self.in_rx.as_mut()?;
        match rx.try_recv() {
            Ok(req) => Some(req),
            Err(_) => None,
        }
    }

    pub fn send_response_raw(
        &mut self,
        id: u64,
        status: u16,
        headers: Vec<(String, String)>,
        body: Vec<u8>,
    ) {
        if let Some(tx) = self.pending.take(id) {
            let _ = tx.send(HttpResponse { status, headers, body });
        }
    }

    /// 供 GdApiServer 调用：poll 并把 resp_tx 转入 pending map，返回不含 resp_tx 的 view。
    pub fn poll_for_godot(&mut self) -> Option<RequestView> {
        let req = self.poll_request_raw()?;
        let id = req.id;
        self.pending.insert(id, req.resp_tx);
        Some(RequestView {
            id,
            method: req.method,
            path: req.path,
            headers: req.headers,
            body: req.body,
        })
    }
}

/// 给 GdApiServer 用的视图：剥离了 resp_tx，剩下纯数据。
pub struct RequestView {
    pub id: u64,
    pub method: String,
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

async fn accept_loop(
    listener: TcpListener,
    in_tx: mpsc::Sender<PendingRequest>,
    id_counter: Arc<AtomicU64>,
    timeout_ms: u64,
    mut shutdown_rx: oneshot::Receiver<()>,
) {
    loop {
        tokio::select! {
            _ = &mut shutdown_rx => break,
            accept = listener.accept() => {
                match accept {
                    Ok((stream, _)) => {
                        let tx = in_tx.clone();
                        let id_c = id_counter.clone();
                        tokio::spawn(handle_connection(stream, tx, id_c, timeout_ms));
                    }
                    Err(_) => break,
                }
            }
        }
    }
}

async fn handle_connection(
    mut stream: tokio::net::TcpStream,
    in_tx: mpsc::Sender<PendingRequest>,
    id_counter: Arc<AtomicU64>,
    timeout_ms: u64,
) {
    let mut buf = Vec::with_capacity(8192);
    let read_result = tokio::time::timeout(
        Duration::from_millis(ACCEPT_READ_TIMEOUT_MS),
        async {
            loop {
                let mut chunk = [0u8; 4096];
                let n = stream.read(&mut chunk).await?;
                if n == 0 {
                    return Ok::<(), std::io::Error>(());
                }
                buf.extend_from_slice(&chunk[..n]);
                match parse_request(&buf) {
                    Ok(Some(_)) => return Ok(()),
                    Ok(None) => continue,
                    Err(e) => return Err(e),
                }
            }
        },
    )
    .await;

    let parsed = match read_result {
        Ok(Ok(())) => parse_request(&buf),
        Ok(Err(e)) => Err(e),
        Err(_) => {
            let _ = stream
                .write_all(&write_response(400, &[], b"{\"error\":\"read timeout\"}"))
                .await;
            return;
        }
    };

    let req: ParsedRequest = match parsed {
        Ok(Some(r)) => r,
        Ok(None) => {
            let _ = stream
                .write_all(&write_response(400, &[], b"{\"error\":\"incomplete request\"}"))
                .await;
            return;
        }
        Err(e) => {
            let status = if e.to_string().contains("16 MiB") { 413 } else { 400 };
            let body = format!("{{\"error\":{:?}}}", e.to_string());
            let _ = stream.write_all(&write_response(status, &[], body.as_bytes())).await;
            return;
        }
    };

    let id = id_counter.fetch_add(1, Ordering::Relaxed);
    let (resp_tx, resp_rx) = oneshot::channel::<HttpResponse>();
    let pending = PendingRequest {
        id,
        method: req.method,
        path: req.path,
        headers: req.headers,
        body: req.body,
        resp_tx,
    };

    if in_tx.send(pending).await.is_err() {
        let _ = stream
            .write_all(&write_response(503, &[], b"{\"error\":\"server shutting down\"}"))
            .await;
        return;
    }

    let resp = match tokio::time::timeout(Duration::from_millis(timeout_ms), resp_rx).await {
        Ok(Ok(r)) => r,
        Ok(Err(_)) => HttpResponse {
            status: 503,
            headers: vec![],
            body: br#"{"error":"server dropped"}"#.to_vec(),
        },
        Err(_) => HttpResponse {
            status: 504,
            headers: vec![("content-type".into(), "application/json".into())],
            body: br#"{"error":"handler timeout"}"#.to_vec(),
        },
    };

    let bytes = write_response(resp.status, &resp.headers, &resp.body);
    let _ = stream.write_all(&bytes).await;
    let _ = stream.shutdown().await;
}
```

- [ ] **步骤 4：把 server 模块公开**

修改 `gdapi/rust/src/lib.rs`，把：
```rust
mod server;
```
改为：
```rust
pub mod server;
```
（集成测试需要 `gdapi::server::ServerCore`）

同样 `mod http;` → `pub mod http;`，`mod queue;` → `pub mod queue;`。

- [ ] **步骤 5：实现 GdApiServer 的真实方法**

完整替换 `gdapi/rust/src/lib.rs` 中 `GdApiServer` 部分：

```rust
//! gdapi — Godot editor 内的 HTTP API GDExtension。

pub mod queue;
pub mod http;
pub mod server;

use godot::prelude::*;
use server::ServerCore;

struct GdApiExtension;

#[gdextension]
unsafe impl ExtensionLibrary for GdApiExtension {}

#[derive(GodotClass)]
#[class(base=RefCounted, no_init)]
pub struct GdApiServer {
    core: ServerCore,
}

#[godot_api]
impl GdApiServer {
    #[func]
    fn create() -> Gd<Self> {
        Gd::from_object(Self { core: ServerCore::new() })
    }

    #[func]
    fn start(&mut self, port_hint: u16) -> i32 {
        match self.core.start(port_hint) {
            Ok(p) => p as i32,
            Err(e) => {
                godot_error!("[gdapi] start failed: {}", e);
                -1
            }
        }
    }

    #[func]
    fn stop(&mut self) {
        self.core.stop();
    }

    #[func]
    fn is_running(&self) -> bool {
        self.core.is_running()
    }

    #[func]
    fn port(&self) -> i32 {
        self.core.port()
    }

    #[func]
    fn poll_request(&mut self) -> Variant {
        match self.core.poll_for_godot() {
            None => Variant::nil(),
            Some(req) => {
                let mut dict = Dictionary::new();
                dict.set("id", req.id as i64);
                dict.set("method", GString::from(req.method));
                dict.set("path", GString::from(req.path));
                let mut hdrs = Dictionary::new();
                for (k, v) in req.headers {
                    hdrs.set(GString::from(k), GString::from(v));
                }
                dict.set("headers", hdrs);
                let mut body = PackedByteArray::new();
                body.resize(req.body.len());
                for (i, b) in req.body.into_iter().enumerate() {
                    body.set(i, b);
                }
                dict.set("body", body);
                dict.to_variant()
            }
        }
    }

    #[func]
    fn send_response(
        &mut self,
        id: i64,
        status: i64,
        headers: Dictionary,
        body: PackedByteArray,
    ) {
        let mut hdrs: Vec<(String, String)> = Vec::new();
        for (k, v) in headers.iter_shared() {
            let kk: GString = k.to();
            let vv: GString = v.to();
            hdrs.push((kk.to_string(), vv.to_string()));
        }
        let mut body_vec = Vec::with_capacity(body.len());
        for i in 0..body.len() {
            body_vec.push(body.get(i).unwrap_or(0));
        }
        self.core.send_response_raw(id as u64, status as u16, hdrs, body_vec);
    }
}
```

- [ ] **步骤 6：运行集成测试验证全部通过**

运行：`cargo test -p gdapi --test server_e2e -- --test-threads=1`
（`--test-threads=1` 避免多测试同时绑端口产生干扰）
预期：4 个测试全部 PASS。

如果 `server_504_on_handler_timeout` 不稳定（CI 时序），可放宽延迟到 1500ms。

- [ ] **步骤 7：运行单元测试确保未回归**

运行：`cargo test -p gdapi`
预期：所有 http + server 测试通过。

- [ ] **步骤 8：Commit**

```bash
git add -A
git commit -m "feat(gdapi): implement tokio http server with cross-thread request queue"
```

---

## 任务 5：GDScript addon 骨架（plugin.cfg + plugin.gd + router + 内置 /ping）

**文件：**
- 创建：`gdapi/addon/plugin.cfg`
- 创建：`gdapi/addon/plugin.gd`
- 创建：`gdapi/addon/gdapi.gdextension`
- 创建：`gdapi/addon/runtime/router.gd`
- 创建：`gdapi/addon/runtime/route_handler.gd`
- 创建：`gdapi/addon/runtime/builtin_ping.gd`
- 创建：`gdapi/addon/runtime/builtin_routes.gd`
- 创建：`gdapi/addon/routes/.gitkeep`

本任务无单元测试（GDScript 单元测试在 MVP 范围外），通过任务 7 的 e2e 验证。

- [ ] **步骤 1：plugin.cfg**

```ini
[plugin]

name="gdapi"
description="HTTP API for gdcli to control this Godot editor instance"
author="gdcli"
version="0.2.0"
script="plugin.gd"
```

- [ ] **步骤 2：gdapi.gdextension**

```ini
[configuration]
entry_symbol = "gdext_rust_init"
compatibility_minimum = 4.3
reloadable = true

[libraries]
windows.debug.x86_64   = "res://addons/gdapi/bin/windows/gdapi.dll"
windows.release.x86_64 = "res://addons/gdapi/bin/windows/gdapi.dll"
macos.debug.arm64      = "res://addons/gdapi/bin/macos/libgdapi.dylib"
macos.release.arm64    = "res://addons/gdapi/bin/macos/libgdapi.dylib"
macos.debug.x86_64     = "res://addons/gdapi/bin/macos/libgdapi.dylib"
macos.release.x86_64   = "res://addons/gdapi/bin/macos/libgdapi.dylib"
linux.debug.x86_64     = "res://addons/gdapi/bin/linux/libgdapi.so"
linux.release.x86_64   = "res://addons/gdapi/bin/linux/libgdapi.so"
```

注意：`entry_symbol = "gdext_rust_init"` 由 godot-rust 的 `#[gdextension]` 宏自动生成；此值是 godot-rust 0.5 的固定约定。

- [ ] **步骤 3：runtime/route_handler.gd**

```gdscript
@tool
class_name GdApiRouteHandler
extends RefCounted

## 路由处理器基类。所有 routes/**/*.gd 必须 extends 它。
##
## 子类约定：
## - 必须覆盖 handle(params: Dictionary) -> Dictionary
## - 成功时返回 {"ok": true, ...}
## - 失败时返回 {"error": "...", "code": "...", "details": {...}}
## - status_code 默认：含 error 字段 → 500，否则 200

func handle(_params: Dictionary) -> Dictionary:
    return {"error": "handler not implemented"}

func status_code(result: Dictionary) -> int:
    return 500 if result.has("error") else 200
```

- [ ] **步骤 4：runtime/builtin_ping.gd**

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(_params: Dictionary) -> Dictionary:
    return {
        "ok": true,
        "gdapi_version": "0.2.0",
        "editor_version": Engine.get_version_info().get("string", ""),
    }
```

- [ ] **步骤 5：runtime/builtin_routes.gd**

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

var _route_names: Array = []

func set_route_names(names: Array) -> void:
    _route_names = names

func handle(_params: Dictionary) -> Dictionary:
    return {"ok": true, "routes": _route_names}
```

- [ ] **步骤 6：runtime/router.gd**

```gdscript
@tool
extends RefCounted

const BuiltinPing := preload("res://addons/gdapi/runtime/builtin_ping.gd")
const BuiltinRoutes := preload("res://addons/gdapi/runtime/builtin_routes.gd")

# path (无前导 /) → Script
var _routes: Dictionary = {}
var _builtin_routes_handler: BuiltinRoutes

func scan(root_dir: String) -> void:
    _routes.clear()
    # 内置路由
    _routes["ping"] = BuiltinPing
    _builtin_routes_handler = BuiltinRoutes.new()
    # _routes_handler 在所有用户路由扫描完后注入路由名列表
    # 但作为 Script 储存时无法预绑定实例数据；改为 dispatch 时特殊分支处理（见下方）

    _scan_dir(root_dir + "/editor", "")
    _scan_dir(root_dir + "/shared", "")

    var names: Array = _routes.keys()
    names.append("routes")  # 把 routes 自身也算进去
    names.sort()
    _builtin_routes_handler.set_route_names(names)

func count() -> int:
    return _routes.size() + 1  # +1 for /routes

func _scan_dir(dir_path: String, prefix: String) -> void:
    var dir := DirAccess.open(dir_path)
    if dir == null:
        return
    dir.list_dir_begin()
    var name := dir.get_next()
    while name != "":
        if name.begins_with("."):
            name = dir.get_next()
            continue
        var full := dir_path + "/" + name
        if dir.current_is_dir():
            var sub_prefix := (prefix + "/" + name) if prefix != "" else name
            _scan_dir(full, sub_prefix)
        elif name.ends_with(".gd") and not name.begins_with("_"):
            var route_name := name.substr(0, name.length() - 3)  # strip .gd
            var key := (prefix + "/" + route_name) if prefix != "" else route_name
            var script: Script = load(full) as Script
            if script != null:
                _routes[key] = script
        name = dir.get_next()
    dir.list_dir_end()

func dispatch(req: Dictionary, server) -> void:
    var id: int = req["id"]
    var method: String = req["method"]
    var path: String = req["path"]

    if method != "POST":
        _reply(server, id, 405, {"error": "only POST is supported"})
        return

    var key: String = path.trim_prefix("/")

    # /routes 特殊处理：用预先注入了名单的实例
    if key == "routes":
        var result := _builtin_routes_handler.handle({})
        var status := _builtin_routes_handler.status_code(result)
        _reply(server, id, status, result)
        return

    if not _routes.has(key):
        _reply(server, id, 404, {
            "error": "route not found: /" + key,
            "available": _routes.keys(),
        })
        return

    var handler_script: Script = _routes[key]
    var handler = handler_script.new()

    # 解析 body
    var params: Dictionary = {}
    var body: PackedByteArray = req["body"]
    if body.size() > 0:
        var text := body.get_string_from_utf8()
        var parsed = JSON.parse_string(text)
        if typeof(parsed) != TYPE_DICTIONARY:
            _reply(server, id, 400, {"error": "body must be a JSON object"})
            return
        params = parsed

    var result = handler.handle(params)
    if typeof(result) != TYPE_DICTIONARY:
        result = {"error": "handler must return Dictionary, got " + str(typeof(result))}
    var status: int = handler.status_code(result)
    _reply(server, id, status, result)

func _reply(server, id: int, status: int, body: Dictionary) -> void:
    var json := JSON.stringify(body)
    var headers := {"Content-Type": "application/json; charset=utf-8"}
    server.send_response(id, status, headers, json.to_utf8_buffer())
```

- [ ] **步骤 7：plugin.gd**

```gdscript
@tool
extends EditorPlugin

const Router := preload("res://addons/gdapi/runtime/router.gd")
const META_PATH := "res://.godot/gdapi.json"
const PORT_HINT: int = 7890

var _server: GdApiServer
var _router: Router

func _enter_tree() -> void:
    _server = GdApiServer.create()
    var port: int = _server.start(PORT_HINT)
    if port < 0:
        push_error("[gdapi] failed to bind any port in 7890..7953")
        return
    _router = Router.new()
    _router.scan("res://addons/gdapi/routes")
    _write_meta(port)
    set_process(true)
    print("[gdapi] listening on 127.0.0.1:%d (%d routes)" % [port, _router.count()])

func _exit_tree() -> void:
    set_process(false)
    if _server and _server.is_running():
        _server.stop()
    _delete_meta()

func _process(_dt: float) -> void:
    if _server == null or not _server.is_running():
        return
    while true:
        var req: Variant = _server.poll_request()
        if req == null:
            break
        _router.dispatch(req, _server)

func _write_meta(port: int) -> void:
    var lsp_port: int = 6005
    var es := EditorInterface.get_editor_settings()
    if es and es.has_setting("network/language_server/remote_port"):
        lsp_port = int(es.get_setting("network/language_server/remote_port"))
    var meta := {
        "http_port": port,
        "lsp_port": lsp_port,
        "pid": OS.get_process_id(),
        "started_at": Time.get_datetime_string_from_system(true),
        "gdapi_version": "0.2.0",
    }
    var f := FileAccess.open(META_PATH, FileAccess.WRITE)
    if f == null:
        push_error("[gdapi] cannot write " + META_PATH)
        return
    f.store_string(JSON.stringify(meta, "  "))
    f.close()

func _delete_meta() -> void:
    if FileAccess.file_exists(META_PATH):
        DirAccess.remove_absolute(ProjectSettings.globalize_path(META_PATH))
```

- [ ] **步骤 8：routes/.gitkeep**

空文件，确保目录被 git 跟踪。

- [ ] **步骤 9：Commit**

```bash
git add -A
git commit -m "feat(gdapi): add addon scaffold (plugin.gd, router, builtin /ping route)"
```

---

## 任务 6：gdcli exec 子命令实现（含集成测试）

**文件：**
- 修改：`cli/src/exec.rs`（替换占位实现）
- 修改：`cli/src/main.rs`（注册 Exec 子命令）
- 创建：`cli/tests/exec_integration.rs`

- [ ] **步骤 1：编写集成测试（使用 httpmock 模拟 gdapi）**

`cli/tests/exec_integration.rs`：

```rust
//! gdcli exec 子命令集成测试。
//!
//! 用 httpmock 模拟 gdapi server，验证：
//! - .godot/gdapi.json 读取
//! - HTTP 调用
//! - stdout/stderr/退出码

use assert_cmd::Command;
use httpmock::prelude::*;
use std::fs;
use tempfile::TempDir;

fn setup_fake_project(meta_json: &str) -> TempDir {
    let dir = TempDir::new().unwrap();
    let project_path = dir.path();
    fs::write(project_path.join("project.godot"), "; fake\nconfig_version=5\n").unwrap();
    fs::create_dir(project_path.join(".godot")).unwrap();
    fs::write(project_path.join(".godot").join("gdapi.json"), meta_json).unwrap();
    dir
}

#[test]
fn exec_ping_success() {
    let server = MockServer::start();
    let mock = server.mock(|when, then| {
        when.method(POST).path("/ping");
        then.status(200)
            .header("content-type", "application/json")
            .body(r#"{"ok":true,"gdapi_version":"0.2.0"}"#);
    });

    let meta = format!(
        r#"{{"http_port":{},"lsp_port":6005,"pid":{},"gdapi_version":"0.2.0"}}"#,
        server.port(),
        std::process::id()
    );
    let dir = setup_fake_project(&meta);

    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["exec", "ping", "--project", dir.path().to_str().unwrap()])
        .assert()
        .success()
        .stdout(predicates::str::contains(r#""ok":true"#));

    mock.assert();
}

#[test]
fn exec_with_data_literal_json() {
    let server = MockServer::start();
    let mock = server.mock(|when, then| {
        when.method(POST)
            .path("/echo")
            .json_body_obj(&serde_json::json!({"hello":"world"}));
        then.status(200).body(r#"{"ok":true}"#);
    });

    let meta = format!(
        r#"{{"http_port":{},"pid":{},"gdapi_version":"0.2.0"}}"#,
        server.port(),
        std::process::id()
    );
    let dir = setup_fake_project(&meta);

    Command::cargo_bin("gdcli")
        .unwrap()
        .args([
            "exec",
            "echo",
            "--data",
            r#"{"hello":"world"}"#,
            "--project",
            dir.path().to_str().unwrap(),
        ])
        .assert()
        .success();

    mock.assert();
}

#[test]
fn exec_404_exits_with_code_2() {
    let server = MockServer::start();
    server.mock(|when, then| {
        when.method(POST).path("/missing");
        then.status(404).body(r#"{"error":"route not found"}"#);
    });

    let meta = format!(
        r#"{{"http_port":{},"pid":{},"gdapi_version":"0.2.0"}}"#,
        server.port(),
        std::process::id()
    );
    let dir = setup_fake_project(&meta);

    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["exec", "missing", "--project", dir.path().to_str().unwrap()])
        .assert()
        .failure()
        .code(2)
        .stderr(predicates::str::contains("HTTP 404"));
}

#[test]
fn exec_500_exits_with_code_1() {
    let server = MockServer::start();
    server.mock(|when, then| {
        when.method(POST).path("/boom");
        then.status(500).body(r#"{"error":"handler crashed"}"#);
    });

    let meta = format!(
        r#"{{"http_port":{},"pid":{},"gdapi_version":"0.2.0"}}"#,
        server.port(),
        std::process::id()
    );
    let dir = setup_fake_project(&meta);

    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["exec", "boom", "--project", dir.path().to_str().unwrap()])
        .assert()
        .failure()
        .code(1)
        .stderr(predicates::str::contains("HTTP 500"));
}

#[test]
fn exec_invalid_json_data_fails_client_side() {
    let dir = setup_fake_project(
        r#"{"http_port":1,"pid":1,"gdapi_version":"0.2.0"}"#,
    );

    Command::cargo_bin("gdcli")
        .unwrap()
        .args([
            "exec",
            "x",
            "--data",
            "not-json",
            "--project",
            dir.path().to_str().unwrap(),
        ])
        .assert()
        .failure()
        .code(2)
        .stderr(predicates::str::contains("invalid JSON"));
}

#[test]
fn exec_missing_meta_file_fails() {
    let dir = TempDir::new().unwrap();
    fs::write(dir.path().join("project.godot"), "; fake\n").unwrap();

    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["exec", "ping", "--project", dir.path().to_str().unwrap()])
        .assert()
        .failure()
        .code(3)
        .stderr(predicates::str::contains("gdapi not running"));
}
```

- [ ] **步骤 2：运行测试验证全部失败**

运行：`cargo test -p gdcli --test exec_integration`
预期：编译失败（Exec 子命令未定义）或运行 fail。

- [ ] **步骤 3：实现 cli/src/exec.rs**

```rust
//! gdcli exec — 通过 HTTP 调用 gdapi 路由。

use anyhow::{anyhow, Result};
use std::io::Read;
use std::path::Path;
use std::time::Duration;

use crate::gdapi_meta;

/// 退出码：0=成功, 1=5xx, 2=4xx/参数错, 3=网络/超时/meta 缺失
pub fn run(
    project: &Path,
    command: &str,
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

    // 2. 准备请求 body
    let body_text = match resolve_data(data)? {
        Some(t) => t,
        None => "{}".to_string(),
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
            Ok(map_status_to_exit(status, &body, /*is_error*/ false))
        }
        Err(ureq::Error::Status(code, r)) => {
            let body = read_body(r)?;
            eprintln!("Error (HTTP {}): {}", code, body.trim());
            Ok(map_status_to_exit(code, &body, /*is_error*/ true))
        }
        Err(ureq::Error::Transport(t)) => {
            eprintln!("network error: {}", t);
            Ok(3)
        }
    }
}

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

fn read_body(resp: ureq::Response) -> Result<String> {
    let mut s = String::new();
    resp.into_reader().take(64 * 1024 * 1024).read_to_string(&mut s)?;
    Ok(s)
}

fn map_status_to_exit(status: u16, _body: &str, is_error: bool) -> i32 {
    if !is_error && (200..300).contains(&status) {
        0
    } else if (400..500).contains(&status) {
        2
    } else if (500..600).contains(&status) {
        1
    } else {
        1
    }
}
```

- [ ] **步骤 4：在 main.rs 注册 Exec 子命令**

修改 `cli/src/main.rs` 的 `Cmd` 枚举，添加新变体（不修改现有变体）：

找到：
```rust
#[derive(Subcommand)]
enum Cmd {
    Rename { ... },
    ...
}
```

在 `Cmd` 末尾添加：
```rust
    /// 通过 HTTP 调用 gdapi 路由：gdcli exec <command> [--data ...]
    Exec {
        /// 路由名（不含前导 /）
        command: String,
        /// 请求 body：字面 JSON、@file、或 - 表示 stdin
        #[arg(long)]
        data: Option<String>,
        /// 总超时秒数
        #[arg(long, default_value_t = 35)]
        timeout: u64,
    },
```

并在 `run()` 函数的 match 分支末尾（在 `Cmd::Status => unreachable!()` 之前）添加：

```rust
        Cmd::Exec { command, data, timeout } => {
            let project_root = match project {
                Some(p) => p.to_path_buf(),
                None => std::env::current_dir()?,
            };
            let code = crate::exec::run(&project_root, &command, data.as_deref(), timeout)?;
            if code != 0 {
                std::process::exit(code);
            }
        }
```

**重要：** 本阶段的 `--project` 解析极简——显式给值则用之，否则用 cwd。不做向上查找（向上查找在阶段 3 引入）。

**额外：** `Exec` 分支在 LSP 客户端创建之前先 return，避免不必要的 LSP 连接。检查 `run()` 顶部：

```rust
async fn run() -> Result<()> {
    let cli = Cli::parse();
    let project = cli.project.as_deref();

    // Exec 子命令不需要 LSP 连接，提前处理
    if let Cmd::Exec { ref command, ref data, timeout } = cli.cmd {
        let project_root = match project {
            Some(p) => p.to_path_buf(),
            None => std::env::current_dir()?,
        };
        let code = crate::exec::run(&project_root, command, data.as_deref(), timeout)?;
        std::process::exit(code);
    }

    if matches!(cli.cmd, Cmd::Status) {
        return handle_status_command(&cli.host, cli.port, project, cli.json).await;
    }
    // ... 现有 LSP 连接逻辑保持不变 ...
}
```

并删除上面 match 块中临时添加的 `Cmd::Exec` 分支（已由顶部处理，match 仍是 exhaustive 因为 Exec 变体在到达 match 前已退出；但 Rust 编译器仍要求 match 覆盖所有变体——所以需要在 match 内保留一个 `unreachable!()` 分支）。

最简方案：保留两处分支，顶部的 process::exit 保证不到达 match 内的版本。改为：

```rust
        Cmd::Exec { .. } => unreachable!("Exec is handled before LSP connect"),
```

- [ ] **步骤 5：运行集成测试验证通过**

运行：`cargo test -p gdcli --test exec_integration`
预期：6 个测试全部 PASS。

- [ ] **步骤 6：运行所有 cli 测试确保未回归**

运行：`cargo test -p gdcli`
预期：全部通过。

- [ ] **步骤 7：Commit**

```bash
git add -A
git commit -m "feat(cli): implement exec subcommand for calling gdapi routes"
```

---

## 任务 7：端到端验证脚本与 fixture 项目

**文件：**
- 创建：`tests/fixture_project/project.godot`
- 创建：`tests/fixture_project/.gitignore`
- 创建：`scripts/e2e-ping.sh`
- 创建：`scripts/e2e-ping.ps1`

- [ ] **步骤 1：fixture project.godot**

```ini
config_version=5

[application]

config/name="gdapi_e2e_fixture"
config/features=PackedStringArray("4.3")

[editor_plugins]

enabled=PackedStringArray("res://addons/gdapi/plugin.cfg")
```

- [ ] **步骤 2：fixture .gitignore**

```
.godot/
addons/gdapi/bin/
```

（addons/gdapi/ 其他内容通过下面脚本符号链接/复制，不直接 commit）

- [ ] **步骤 3：scripts/e2e-ping.sh（Unix）**

```bash
#!/usr/bin/env bash
# 端到端验证：启动 Godot 编辑器，运行 gdcli exec ping，验证响应。
#
# 要求：
#   - godot 在 PATH 中（或设 GODOT_BIN 环境变量）
#   - 已运行 cargo build -p gdapi 和 cargo build -p gdcli
set -euo pipefail

GODOT_BIN="${GODOT_BIN:-godot}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$REPO_ROOT/tests/fixture_project"
ADDON_DIR="$FIXTURE/addons/gdapi"
GDCLI_BIN="$REPO_ROOT/target/debug/gdcli"

# 1. 安装 addon：复制源 + 编译产物
rm -rf "$ADDON_DIR"
mkdir -p "$ADDON_DIR"
cp -r "$REPO_ROOT/gdapi/addon/"* "$ADDON_DIR/"

mkdir -p "$ADDON_DIR/bin/linux" "$ADDON_DIR/bin/macos" "$ADDON_DIR/bin/windows"
if [[ -f "$REPO_ROOT/target/debug/libgdapi.so" ]]; then
    cp "$REPO_ROOT/target/debug/libgdapi.so" "$ADDON_DIR/bin/linux/"
fi
if [[ -f "$REPO_ROOT/target/debug/libgdapi.dylib" ]]; then
    cp "$REPO_ROOT/target/debug/libgdapi.dylib" "$ADDON_DIR/bin/macos/"
fi
if [[ -f "$REPO_ROOT/target/debug/gdapi.dll" ]]; then
    cp "$REPO_ROOT/target/debug/gdapi.dll" "$ADDON_DIR/bin/windows/"
fi

# 2. 启动 Godot 编辑器（无头）
echo "Starting Godot editor..."
"$GODOT_BIN" --editor --headless --path "$FIXTURE" &
GODOT_PID=$!

# 3. 轮询等待 .godot/gdapi.json 出现
META="$FIXTURE/.godot/gdapi.json"
for i in {1..30}; do
    if [[ -f "$META" ]]; then
        echo "gdapi meta appeared: $META"
        cat "$META"
        break
    fi
    sleep 1
done

if [[ ! -f "$META" ]]; then
    echo "ERROR: gdapi.json never appeared"
    kill $GODOT_PID 2>/dev/null || true
    exit 1
fi

# 4. 调 ping
echo "Calling: gdcli exec ping --project $FIXTURE"
OUTPUT=$("$GDCLI_BIN" exec ping --project "$FIXTURE")
echo "Response: $OUTPUT"

# 5. 验证响应
if echo "$OUTPUT" | grep -q '"ok":true'; then
    echo "PASS: e2e ping succeeded"
    RESULT=0
else
    echo "FAIL: unexpected response"
    RESULT=1
fi

# 6. 关闭 Godot
kill $GODOT_PID 2>/dev/null || true
wait $GODOT_PID 2>/dev/null || true

exit $RESULT
```

- [ ] **步骤 4：scripts/e2e-ping.ps1（Windows）**

```powershell
#!/usr/bin/env pwsh
# Windows 版端到端验证。
$ErrorActionPreference = "Stop"

$GodotBin = $env:GODOT_BIN
if (-not $GodotBin) { $GodotBin = "godot" }

$RepoRoot = Resolve-Path "$PSScriptRoot/.."
$Fixture = Join-Path $RepoRoot "tests\fixture_project"
$AddonDir = Join-Path $Fixture "addons\gdapi"
$GdcliBin = Join-Path $RepoRoot "target\debug\gdcli.exe"

# 1. 复制 addon
if (Test-Path $AddonDir) { Remove-Item -Recurse -Force $AddonDir }
New-Item -ItemType Directory -Path $AddonDir | Out-Null
Copy-Item -Recurse "$RepoRoot\gdapi\addon\*" $AddonDir

New-Item -ItemType Directory -Force -Path "$AddonDir\bin\windows" | Out-Null
$DllSrc = "$RepoRoot\target\debug\gdapi.dll"
if (Test-Path $DllSrc) {
    Copy-Item $DllSrc "$AddonDir\bin\windows\"
} else {
    Write-Error "gdapi.dll not built. Run: cargo build -p gdapi"
}

# 2. 启动 Godot
Write-Host "Starting Godot editor..."
$Godot = Start-Process -FilePath $GodotBin `
    -ArgumentList "--editor", "--headless", "--path", $Fixture `
    -PassThru

$Meta = Join-Path $Fixture ".godot\gdapi.json"
$Ready = $false
for ($i = 0; $i -lt 30; $i++) {
    if (Test-Path $Meta) {
        $Ready = $true
        Write-Host "gdapi meta appeared"
        Get-Content $Meta
        break
    }
    Start-Sleep -Seconds 1
}

if (-not $Ready) {
    Write-Host "ERROR: gdapi.json never appeared" -ForegroundColor Red
    Stop-Process -Id $Godot.Id -Force -ErrorAction SilentlyContinue
    exit 1
}

Write-Host "Calling: gdcli exec ping --project $Fixture"
$Output = & $GdcliBin exec ping --project $Fixture
Write-Host "Response: $Output"

$ExitCode = 0
if ($Output -match '"ok":true') {
    Write-Host "PASS: e2e ping succeeded" -ForegroundColor Green
} else {
    Write-Host "FAIL: unexpected response" -ForegroundColor Red
    $ExitCode = 1
}

Stop-Process -Id $Godot.Id -Force -ErrorAction SilentlyContinue
exit $ExitCode
```

- [ ] **步骤 5：手动执行 e2e 验证**

前提：本地已安装 Godot 4.3+ 且 `godot` 在 PATH。

运行（Windows）：
```powershell
cargo build -p gdapi
cargo build -p gdcli
pwsh scripts/e2e-ping.ps1
```

或（Unix）：
```bash
cargo build -p gdapi
cargo build -p gdcli
bash scripts/e2e-ping.sh
```

预期输出（最后部分）：
```
Response: {"editor_version":"4.3.x","gdapi_version":"0.2.0","ok":true}
PASS: e2e ping succeeded
```

**若 e2e 失败**，常见问题排查：
- Godot 启动失败 → 确认 `godot --version` 可用
- `.godot/gdapi.json` 未出现 → 看 Godot 输出，确认插件已启用，extension 已加载
- 连接拒绝 → 确认 port 写入文件，再用 `curl http://127.0.0.1:<port>/ping -X POST -d '{}'` 直接测试

- [ ] **步骤 6：把 e2e 脚本变成可执行（Unix）**

运行：`chmod +x scripts/e2e-ping.sh`

- [ ] **步骤 7：Commit**

```bash
git add -A
git commit -m "test(e2e): add fixture project and end-to-end ping verification scripts"
```

---

## 任务 8：阶段 1 收尾——README 与 .gitignore 更新

**文件：**
- 修改：`.gitignore`
- 修改：`README.md`（追加阶段 1 内容，不删除现有 LSP 文档）

- [ ] **步骤 1：更新 .gitignore**

追加内容：
```
# gdapi GDExtension build outputs
gdapi/rust/target/

# Addon binaries copied into fixture (not source-controlled)
tests/fixture_project/addons/gdapi/

# Per-project Godot metadata
.godot/
```

注：根级 `target/` 应该已经在 .gitignore；如未在，添加。

- [ ] **步骤 2：在 README.md 开头插入"扩展工具"段**

在 README.md 现有内容**最上方**追加一段（保留现有 LSP 文档不动）：

````markdown
## 实验性：gdcli exec（与 gdapi addon 配合）

> 阶段 1：仅支持内置 `/ping` 路由，验证端到端联通。完整命令集见 `docs/superpowers/specs/2026-06-23-gdcli-godot-editor-tool-design.md`。

### 准备

```bash
cargo build --workspace
```

把 `gdapi/addon/` 拷到目标项目的 `addons/gdapi/`，并把编译产物（如 `target/debug/gdapi.dll`）放到 `addons/gdapi/bin/<platform>/`。在 Godot 编辑器中启用 `gdapi` 插件（Project Settings → Plugins）。

### 验证

```bash
gdcli exec ping --project /path/to/your/godot/project
# 输出：{"editor_version":"4.3.x","gdapi_version":"0.2.0","ok":true}
```

后续阶段将提供 `gdcli install` 一键完成上述安装步骤。

---

````

- [ ] **步骤 3：Commit**

```bash
git add -A
git commit -m "docs: update readme and gitignore for phase 1 (gdapi minimal e2e)"
```

---

## 阶段 1 完成标准

执行完所有任务后应达到：

1. `cargo build --workspace` 全部成功
2. `cargo test --workspace` 全部通过（含 cli 单元测试 + gdapi 单元/集成测试 + cli exec 集成测试）
3. 手动执行 `scripts/e2e-ping.{sh,ps1}` 输出 `PASS: e2e ping succeeded`
4. 现有 LSP 顶层命令（`gdcli rename ...` 等）行为完全不变
5. 新增 `gdcli exec ping --project <dir>` 可工作
6. `git log --oneline` 显示 8 个干净的 commit

阶段 1 验证成功后，进入阶段 2（`gdcli install` 子命令 + addon 模板嵌入）规划。
