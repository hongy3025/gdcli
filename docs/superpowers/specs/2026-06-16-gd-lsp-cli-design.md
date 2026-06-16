# gd-lsp-cli 设计规格

**状态：** 设计已批准，待实现
**日期：** 2026-06-16
**参考实现：** `D:\txcombo\git\game-dev\godot-ws\godot-lsp-cli.ts`（TypeScript 版，~600 行）

## 目标

在当前 Rust 项目中复刻 `godot-lsp-cli.ts` 的全部能力：通过 TCP 连接到 Godot 内置 LSP 服务器，支持跨项目重命名、查找引用、跳转定义/声明、文件符号、悬停信息、原生类文档、诊断、能力查询共 9 个命令。最终二进制 `gd-lsp-cli` 在命令、参数、输出格式、退出码上与 TS 版完全一致，使现有 AI agent 脚本可零改动迁移。

## 非目标

- 不实现 LSP 客户端的全部能力（仅复刻 TS 版支持的 9 个命令）
- 不直接写文件（rename 仅返回 edit 集合，由调用方应用）
- 不支持 workspace symbols（Godot LSP 不支持）
- 不支持 1-based 行列号（保持 LSP 0-based 约定）

## 架构

```
┌──────────────────────────────────────────────────────────┐
│  main.rs                                                 │
│  ─ clap 解析参数 → 分发到 GodotLspClient                 │
│  ─ 输出格式化（人类 / --json）                           │
└────────────┬─────────────────────────────────────────────┘
             │
┌────────────▼─────────────────────────────────────────────┐
│  client.rs · GodotLspClient                              │
│  ─ initialize / initialized 握手                         │
│  ─ ensureOpen（懒 didOpen + 500ms 等待）                 │
│  ─ rename/references/definition/declaration/symbols/...  │
│  ─ 订阅 publishDiagnostics 通知 → 缓存                   │
└────────────┬─────────────────────────────────────────────┘
             │
┌────────────▼─────────────────────────────────────────────┐
│  transport.rs · LspTransport                             │
│  ─ TCP 连接（5s 超时）                                   │
│  ─ Content-Length 帧化 / 解帧（后台读循环）              │
│  ─ JSON-RPC 请求/响应（id 配对，oneshot）                │
│  ─ 服务器通知（broadcast）                                │
└──────────────────────────────────────────────────────────┘

types.rs · LSP 数据结构 + URI/SymbolKind 工具函数
```

### 模块边界

| 模块 | 职责 | 不做 |
|---|---|---|
| `transport` | 字节流 ↔ JSON-RPC 消息；不感知具体 method 语义 | 不解析 LSP 数据结构 |
| `client` | LSP 协议层：状态机（initialized/openedFiles/diagnostics） | 不感知 CLI 参数与输出格式 |
| `main` | CLI 解析 + 输出格式化 + 调用 client | 不直接读写 socket |
| `types` | LSP 数据结构（Position/Range/Location 等）+ URI/SymbolKind | 无业务逻辑 |

## 依赖

| crate | 版本 | 用途 |
|---|---|---|
| `tokio` | 1, features=`["macros","rt-multi-thread","net","io-util","sync","time","fs"]` | 异步运行时 + TCP + 超时 + 文件读 |
| `clap` | 4, features=`["derive"]` | CLI 参数解析 |
| `serde` | 1, features=`["derive"]` | LSP 类型派生 |
| `serde_json` | 1 | JSON 编解码 |
| `anyhow` | 1 | 统一错误 |
| `percent-encoding` | 2 | URI 编解码 |
| `bytes` | 1 | 读循环缓冲 |

dev-dependencies：`assert_cmd = "2"`、`predicates = "3"`、`tempfile = "3"`

## CLI 接口

可执行文件：`gd-lsp-cli`

### 全局选项（与 TS 版一致）

| Flag | 默认 | 说明 |
|---|---|---|
| `--host <host>` | `127.0.0.1` | LSP 服务器主机 |
| `--port <port>` | `6005` | LSP 服务器端口 |
| `--project <path>` | — | Godot 项目根目录（启用相对路径） |
| `--json` | — | 输出 JSON |

### 子命令

| 命令 | 参数 | 行为 |
|---|---|---|
| `rename` | `<file> <line> <col> <new_name>` | 跨项目重命名，返回 WorkspaceEdit |
| `references` | `<file> <line> <col>` | 查找全部引用 |
| `definition` | `<file> <line> <col>` | 跳转定义 |
| `declaration` | `<file> <line> <col>` | 跳转声明 |
| `symbols` | `<file>` | 列出文件符号（层级） |
| `hover` | `<file> <line> <col>` | 悬停信息 |
| `native-symbol` | `<class> [member]` | Godot 内置类文档 |
| `diagnostics` | `[file]` | 显示诊断（无 file 显示全项目） |
| `capabilities` | — | 显示 LSP 服务器能力 |

行列号 0-based（LSP 约定）。

## 数据流

### 启动流程
1. `clap` 解析参数。
2. 构造 `GodotLspClient`，调用 `connect(host, port, project)`：
   - 建立 TCP 连接（`tokio::time::timeout(5s)`）。
   - 启动后台读循环。
   - 发送 `initialize` 请求（参数与 TS 版严格一致：含 `rename.prepareSupport`、`hierarchicalDocumentSymbolSupport`、`hover.contentFormat=["plaintext","markdown"]`、`workspaceEdit.documentChanges=true`、`processId=std::process::id()`、`rootUri`/`rootPath` 来自 `--project`）。
   - 缓存 `serverCapabilities`。
   - 发送 `initialized` 通知。
3. 连接失败：stderr 打印两行（与 TS 版一致）：
   ```
   Failed to connect to Godot LSP at <host>:<port>
   Make sure Godot is running with: godot --editor --headless --lsp-port <port> --path /your/project
   ```
   退出码 1。

### 命令执行流程
1. `resolve_file(file, project)` 解析文件路径：
   - 绝对路径 → 直接用
   - 有 `--project` → `project.join(file)`
   - 否则 → `std::env::current_dir().join(file)`
2. `ensure_open(file)`：若该 uri 未打开过，读取文件内容 → 发送 `textDocument/didOpen`（`languageId="gdscript"`, `version=1`） → `tokio::time::sleep(500ms)`。
3. 发送对应 LSP 请求，await 结果。
4. 按 `--json` 或人类可读格式输出。
5. `client.disconnect()`：若已 initialized，发 `shutdown` 通知 + 关 socket。

### 诊断特例
`diagnostics` 命令进入后先 `tokio::time::sleep(2s)` 等待服务器推送，再读取缓存。读取范围：
- 有 file 参数 → 仅该文件的诊断
- 无 file 参数 → 全部缓存

### URI 处理

`file_to_uri(path)`：
1. 取绝对路径 → 反斜杠转正斜杠。
2. 用 `percent_encoding` 对路径进行编码（保留 `:`、`/` 不编码，与 JS `encodeURI` 行为对齐）。
3. 拼接 `file:///` 前缀（Windows 形如 `file:///C:/foo/bar.gd`，POSIX 形如 `file:///foo/bar.gd`）。

`uri_to_file(uri)`：
1. 去 `file:///` 前缀。
2. `percent_decode_str` 解码。

`--json` 输出前的递归 URI 解码（对应 TS 版 `decodeUris`）：
- 字符串若以 `file:///` 开头 → 解码为本地路径
- 对象 key 若以 `file:///` 开头 → 同样解码（rename 的 `changes` map 用 uri 当 key）
- 数组/对象递归处理

## 输出格式（与 TS 版逐字节对齐）

### 人类可读

| 命令 | 格式 |
|---|---|
| rename | 每个文件一段，文件路径行 + 缩进的 `  <range> → "<newText>"` |
| references | `Found N reference(s):` 后每行 `  <file>:<line>:<col>`；空时 `No references found.` |
| definition / declaration | 每行 `<file>:<line>:<col>`；空时 `No definition found.` / `No declaration found.` |
| symbols | 递归 2 空格缩进；DocumentSymbol 输出 `<Kind> <name> [<range>]`，SymbolInformation 输出 `<Kind> <name> <file:line:col>` |
| hover | 直接打印 hover 文本；空时 `No hover info available.` |
| native-symbol | `<name> — <detail>` + 空行 + `documentation`；无 member 时追加 `Members: <count>` |
| diagnostics | 按文件分组：文件路径 + 缩进的 `  [<severity>] <range>: <message>`；空时 `No diagnostics.` 或 `No diagnostics for this file.` |
| capabilities | `serde_json::to_string_pretty(&caps)` |

`format_range`：`<sl>:<sc>-<el>:<ec>`（4 个 0-based 数字，连字符分隔）
`format_location`：`<file>:<line>:<col>`（uri 已解码）
severity 文本：`["", "error", "warning", "info", "hint"]`，索引取 `severity.unwrap_or(1)`

### JSON 模式
所有命令统一 `serde_json::to_string_pretty`，输出前递归 URI 解码（见上）。

## 状态管理

`GodotLspClient` 字段：
- `initialized: AtomicBool` — 控制 disconnect 时是否发 shutdown
- `opened_files: Mutex<HashSet<String>>` — uri 集合，避免重复 didOpen
- `diagnostics: Arc<Mutex<HashMap<String, Vec<Diagnostic>>>>` — uri → 诊断列表，由通知订阅线程写入
- `server_capabilities: Mutex<Value>` — initialize 返回值

通知订阅：`new()` 中订阅 `transport.notif_tx` 并 spawn 任务，在收到 `textDocument/publishDiagnostics` 时写入 `diagnostics`。

## 错误处理

- 全局 `anyhow::Result`，`main` 返回 Result；失败打印到 stderr，退出码 1。
- 连接失败时打印额外提示（见上文「启动流程」）。
- 参数缺失：clap 自动处理，退出码 2（clap 默认）。
  - 注：TS 版手动 `process.exit(1)`，Rust 用 clap 时退出码 2 是更标准的行为。这是唯一允许的差异，文档中说明。
- LSP 错误（带 `error` 字段的响应）→ 转为 `anyhow::Error`，消息格式 `LSP error <code>: <message>`。

## 测试策略

### 单元测试
- `transport::tests::message_buffer_*` — 单包/跨包/粘包/无 Content-Length（4 条）
- `types::tests::uri_roundtrip` — Windows 路径、POSIX 路径、含中文、含空格各 1 条
- `types::tests::symbol_kind_name` — 已知值 + 未知值
- `main::tests::format_*` — `format_range` / `format_location` / `format_diagnostic` 各 1 条

### 集成测试 `tests/mock_lsp.rs`
启 `tokio::net::TcpListener` 假扮 LSP，按脚本响应。覆盖：
1. `rename` 命令的人类输出格式
2. `--json` 模式下 URI 已解码（含对象 key）
3. `diagnostics` 命令在 2s 等待内能读到推送
4. 连接失败时的两行 stderr 提示

依赖：`assert_cmd`、`predicates`、`tempfile`。

## 项目结构

```
gd-lsp-cli/
├── Cargo.toml
├── README.md                         # 中文用法（参照 TS 版 README）
├── docs/superpowers/specs/2026-06-16-gd-lsp-cli-design.md
└── src/
    ├── main.rs
    ├── transport.rs
    ├── client.rs
    └── types.rs
└── tests/
    └── mock_lsp.rs
```

## 风险与权衡

| 风险 | 缓解 |
|---|---|
| Godot LSP 实际行为与文档不符 | 严格对齐 TS 版的请求参数（已在源码中验证），mock LSP 集成测试覆盖关键路径 |
| URI 编码与 JS `encodeURI` 不严格一致 | 用 `percent-encoding` 保留 `:` `/`；测试中包含中文/空格/Windows 盘符 |
| `tokio::time::sleep` 硬编码（500ms / 2000ms） | 与 TS 版一致，不破坏现有 agent 脚本预期；后续优化为可配置（非本次范围） |
| clap 缺参退出码 2 vs TS 版 1 | 已在错误处理章节说明，README 注明 |

## 验收标准

- [ ] `cargo build --release` 成功，产出 `gd-lsp-cli` 可执行文件
- [ ] `cargo test` 全部通过（单元 + 集成）
- [ ] 9 个子命令均可执行（mock LSP 集成测试覆盖至少 4 个）
- [ ] `--json` 模式输出的字符串/对象 key 中不再含 `file:///` 前缀
- [ ] 连接失败时 stderr 输出与 TS 版一致的两行提示
- [ ] README 包含中文用法、与 TS 版差异说明
