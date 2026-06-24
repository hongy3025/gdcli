# exec 命令术语统一与 help 清理

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 删除未生效的 `help` 命令处理，统一术语，对用户隐藏 gdapi 内部概念

**架构：** 纯文本/逻辑清理，不涉及新功能。CLI 端删除 `help` 分支，更新注释和文档中的术语；测试从 `help` 迁移到 `commands`/`command-help`；README 同步更新。

**术语规则：**
- **用户面**（CLI help、错误信息、README）：不出现"gdapi"，用"Godot 编辑器"代替。用户视角：gdcli 直接操作 Godot。
- **开发者面**（代码注释、内部模块名）：可保留"gdapi"作为内部标识（`gdapi_meta`、`.godot/gdapi.json` 等不改）。
- "路由"/"HTTP" → "命令"（用户面）；内部注释中"HTTP"可保留但"路由"改为"命令"。

**技术栈：** Rust (clap)、GDScript、Markdown

---

## 涉及文件

| 文件 | 职责 | 操作 |
|---|---|---|
| `cli/src/exec.rs` | exec 核心逻辑 | 删除 help 分支，统一注释术语 |
| `cli/src/main.rs` | CLI 参数定义 | 更新 doc comment 和 after_help |
| `cli/tests/exec_integration.rs` | 集成测试 | 迁移 help 测试为 commands/command-help |
| `README.md` | 用户文档 | 更新 exec 章节 |
| `gdapi/addon/runtime/router.gd` | 路由注册 | 统一注释术语 |

**不修改：** `builtin_help.gd`（服务端文件，保留供未来使用或单独清理）

---

### 任务 1：cli/src/exec.rs — 删除 help 分支 + 统一术语

**文件：** `cli/src/exec.rs`

- [ ] **步骤 1：更新模块级注释（第 1-14 行）**

```rust
//! gdcli exec — 调用 Godot 编辑器命令。
//!
//! 本模块实现了 `gdcli exec` 命令，用于向运行中的 Godot 编辑器发送请求。
//! 核心流程：
//!   1. 从 `.godot/gdapi.json` 读取元数据（端口等）
//!   2. 解析用户提供的请求数据（字面 JSON、@文件路径或 stdin）
//!   3. 构造 POST 请求并发送到 Godot 编辑器
//!   4. 根据响应状态码返回对应的退出码
//!
//! 退出码约定：
//!   - 0: 成功（2xx 响应）
//!   - 1: 服务器错误（5xx 响应）
//!   - 2: 客户端错误（4xx 响应或参数错误）
//!   - 3: 网络错误、超时或元数据缺失
```

- [ ] **步骤 2：更新 run() 函数注释（第 27-39 行）**

```rust
/// 从项目元数据中获取端口，构造请求并发送，返回进程退出码。
///
/// # 参数
///
/// * `command` - 命令名（如 "ping"、"scene/create" 等）
/// * `data` - 可选的请求数据（JSON 字符串、@文件路径或 "-" 表示 stdin）
/// * `project` - Godot 项目根目录路径
/// * `timeout_secs` - 请求超时时间（秒）
/// * `json_output` - 是否以原始 JSON 格式输出（默认 TOON 格式）
```

- [ ] **步骤 3：更新 build_body() 函数注释（第 130-157 行）**

```rust
/// 构造请求体。
///
/// 调用方根据变体决定行为：Body 用作请求体；
/// Reject 输出错误信息并以退出码 2 终止。
///
/// # 参数
///
/// * `command` - 命令名
/// * `data` - 可选的用户提供的请求数据
/// * `args` - 位置参数（command-help 使用：命令路径）
///
/// # 特殊命令
///
/// * `commands` — 返回空 body，拒绝 `--data` 和位置参数
/// * `command-help <path>` — 以 `{"command": "<path>"}` 为 body，拒绝 `--data`，要求恰好 1 个位置参数
/// * 其它命令 — 使用 `--data` 或空 `{}`，拒绝位置参数
```

- [ ] **步骤 4：删除 help 命令处理块（第 200-220 行）**

删除以下代码：
```rust
    // help 命令（向后兼容）
    if command == "help" {
        if data.is_some() {
            return Ok(BuildBodyOutcome::Reject(
                "'help' command does not accept --data; use positional path argument instead"
                    .to_string(),
            ));
        }
        if args.len() > 1 {
            return Ok(BuildBodyOutcome::Reject(format!(
                "'help' accepts at most one positional path argument, got {}: {:?}",
                args.len(),
                args
            )));
        }
        let body = match args.first() {
            Some(path) => serde_json::json!({ "path": path }).to_string(),
            None => "{}".to_string(),
        };
        return Ok(BuildBodyOutcome::Body(body));
    }
```

- [ ] **步骤 5：更新用户面文本（错误信息等）**

- `exec.rs` 第 55 行错误信息：`"gdapi not running: {}\nHint: open the project in Godot editor with gdapi plugin enabled, or run 'gdcli install' first."` → `"Godot 编辑器未响应: {}\n提示：请在 Godot 编辑器中打开项目并启用 gdapi 插件，或先运行 'gdcli install'"`
- `commands/lsp.rs` 第 312 行：`"gdapi (HTTP):  {} connected ({}:{})"` → `"gdapi:  {} 已连接 ({}:{})"`（此为内部诊断输出，保留 gdapi 但去掉 HTTP）
- `commands/lsp.rs` 第 323 行：`"gdapi error:   {}"` → `"gdapi 错误:   {}"`
- `commands/lsp.rs` 第 277 行：`"no gdapi meta: {}"` → `"未找到 gdapi 元数据: {}"`

- [ ] **步骤 6：运行单元测试验证**

```bash
cargo test -p gdcli -- exec
```

预期：所有测试通过（help 相关单元测试需同步删除，见下方）

- [ ] **步骤 7：删除 help 相关单元测试**

在 `exec.rs` 底部的 `#[cfg(test)]` 模块中，删除所有 `help` 相关的测试用例（搜索 `"help"` 关键字）。

- [ ] **步骤 8：再次运行单元测试**

```bash
cargo test -p gdcli -- exec
```

预期：全部通过

---

### 任务 2：cli/src/main.rs — 更新 CLI 参数文档

**文件：** `cli/src/main.rs`

- [ ] **步骤 1：更新 Exec variant 的注释和 after_help（第 122-134 行）**

```rust
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
```

同时更新 `main.rs` 第 113 行 install 的 doc comment：
```rust
    /// 在目标项目安装 Godot 编辑器插件
```

- [ ] **步骤 2：运行编译验证**

```bash
cargo build -p gdcli
```

预期：编译通过，`gdcli exec --help` 输出术语统一

---

### 任务 3：cli/tests/exec_integration.rs — 迁移 help 测试

**文件：** `cli/tests/exec_integration.rs`

- [ ] **步骤 1：迁移 `exec_help_list_passes_through_server_json` 测试（第 204 行附近）**

将 `exec help` 改为 `exec commands`，mock 路径从 `/help` 改为 `/commands`，响应 body 中的 `routes` 改为 `commands`。

```rust
#[test]
fn exec_commands_list_passes_through_server_json() {
    let dir = setup_fixture_project();
    let mut server = mockito::Server::new();
    let mock = server.mock("POST", "/commands")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"ok":true,"commands":[{"path":"ping","summary":"健康检查"}]}"#)
        .create();

    let output = Command::new(cargo_bin("gdcli"))
        .args(["exec", "commands", "--project", dir.path().to_str().unwrap()])
        .env("GDAPI_PORT", server.port().to_string())
        .output()
        .unwrap();

    mock.assert();
    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("ping"));
}
```

- [ ] **步骤 2：迁移 `exec_help_with_path_sends_path_body` 测试（第 234 行附近）**

将 `exec help` 改为 `exec command-help`，mock 路径从 `/help` 改为 `/command-help`。

- [ ] **步骤 3：迁移 `exec_help_nonexistent_path_returns_exit_code_2` 测试（第 265 行附近）**

将 `exec help` 改为 `exec command-help`，mock 路径从 `/help` 改为 `/command-help`。

- [ ] **步骤 4：迁移 `exec_help_with_data_flag_is_rejected` 测试（第 284 行附近）**

将 `exec help` 改为 `exec command-help`，更新错误消息匹配。

- [ ] **步骤 5：更新 TOON 输出测试中的 mock 数据（第 409、448 行附近）**

将 mock body 中的 `"routes"` key 改为 `"commands"`，将 `"help"` 从 mock 数据中移除（如有）。

- [ ] **步骤 6：运行集成测试**

```bash
cargo test -p gdcli -- exec_integration
```

预期：全部通过

---

### 任务 4：README.md — 更新 exec 文档

**文件：** `README.md`

- [ ] **步骤 1：更新 exec 章节（第 151-191 行）**

```markdown
## gdcli exec

调用 Godot 编辑器命令，需要 Godot 编辑器运行中且 gdapi 插件已启用。

```bash
gdcli exec ping --project /path/to/project
# 输出：{"editor_version":"4.3.x","gdapi_version":"0.2.0","ok":true}
```

| Flag | 默认 | 说明 |
|---|---|---|
| `--data <json>` | `{}` | 请求 JSON 数据：字面 JSON、`@file` 或 `-`（stdin） |
| `--timeout <secs>` | `30` | 请求超时秒数 |

`commands` 和 `command-help` 使用位置参数而非 `--data`：

```bash
gdcli exec commands                     # 列出所有命令
gdcli exec command-help editor/scene/save  # 查看命令详情
```

### 输出格式

`gdcli exec` 默认以 **TOON** 格式输出响应，便于人类终端阅读和 LLM 消费：

- 对象 → 缩进键值对
- 字段统一的对象数组 → 紧凑表格（pipe 分隔）
- 其它结构 → 树状列表

加 `--json` 切回原始的 minified JSON（脚本场景推荐）：

```bash
# 默认 TOON 输出
gdcli exec ping
# ok: true
# gdapi_version: 0.2.0

# JSON 输出（脚本友好）
gdcli --json exec ping
# {"ok":true,"gdapi_version":"0.2.0"}
```
```

- [ ] **步骤 2：更新 README 其余 gdapi 引用**

- 第 6 行：`通过 gdapi addon 的 HTTP 接口调用编辑器功能` → `调用 Godot 编辑器功能`
- 第 29 行：`exec 命令需要在项目中安装并启用 gdapi 插件` → `exec 命令需要在项目中安装并启用编辑器插件`
- 第 36 行：`gdcli install             # 安装 gdapi addon 到目标项目` → `gdcli install             # 安装编辑器插件到目标项目`
- 第 37 行：`gdcli exec <command>      # 通过 HTTP 调用 gdapi 路由` → `gdcli exec <command>      # 调用 Godot 编辑器命令`
- 第 44 行：`将 gdapi addon 安装到目标 Godot 项目` → `将编辑器插件安装到目标 Godot 项目`
- 第 200 行：`.godot/gdapi.json` 保留（内部实现细节，但用户需要知道文件位置）

---

### 任务 5：router.gd — 统一注释术语

**文件：** `gdapi/addon/runtime/router.gd`

- [ ] **步骤 1：更新文件头注释（第 1-6 行）**

```gdscript
## 命令系统核心模块
##
## 负责扫描、注册和分发请求到对应的命令处理器。
## 支持自动扫描目录下的 GDScript 文件作为命令处理器，提供内置命令（如 ping 和命令列表）。
## 使用路径匹配机制，将请求路径映射到处理器脚本。
```

- [ ] **步骤 2：更新第 21 行注释**

```gdscript
## 命令注册表，键为路径（如 "editor/scene/save"），值为处理器脚本
```

- [ ] **步骤 3：搜索并替换其余"路由"为"命令"**

在 router.gd 中搜索 `路由`，将所有注释中的"路由"改为"命令"。

---

### 任务 6：最终验证

- [ ] **步骤 1：运行全部测试**

```bash
cargo test --workspace
```

预期：全部通过

- [ ] **步骤 2：运行 clippy**

```bash
cargo clippy --workspace
```

预期：无新增警告

- [ ] **步骤 3：检查帮助输出**

```bash
cargo run -p gdcli -- exec --help
```

预期：输出中无"路由"/"HTTP"字样，术语统一为"命令"

- [ ] **步骤 4：Commit**

```bash
git add cli/src/exec.rs cli/src/main.rs cli/tests/exec_integration.rs README.md gdapi/addon/runtime/router.gd
git commit -m "refactor(exec): 删除 help 命令，统一术语，对用户隐藏 gdapi 概念"
```
