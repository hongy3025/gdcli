# 阶段 5：LSP 端口发现 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 让 `gdcli lsp <subcommand>` 自动从 `.godot/gdapi.json` 读取 LSP 端口，解决多 Godot 实例并存时的端口发现问题。

**架构：** 修改 `--port` 参数为可选（无默认值），在 LSP 连接前尝试从 `.godot/gdapi.json` 读取 `lsp_port` 字段。优先级：`--port` 显式值 > `.godot/gdapi.json` 的 `lsp_port` > 默认 6005。

**技术栈：** Rust 2021 / clap 4

---

## 文件结构

**修改：**
- `cli/src/main.rs` — 修改 `--port` 参数定义、添加 LSP 端口发现逻辑
- `cli/src/gdapi_meta.rs` — 已有读取逻辑（无需修改）

**新建：**
- `cli/tests/lsp_port_discovery.rs` — LSP 端口发现集成测试

---

## 任务 1：LSP 端口发现逻辑

**文件：**
- 修改：`cli/src/main.rs`
- 创建：`cli/tests/lsp_port_discovery.rs`

- [ ] **步骤 1：修改 --port 参数为可选**

修改 `cli/src/main.rs` 中的 `Cli` 结构体：

```rust
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
```

注意：`port` 从 `u16`（默认 6005）改为 `Option<u16>`（无默认值）。

- [ ] **步骤 2：添加 LSP 端口发现函数**

在 `cli/src/main.rs` 中添加：

```rust
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
```

- [ ] **步骤 3：更新 LSP 连接逻辑**

修改 `run()` 函数中的 LSP 连接部分：

```rust
    // LSP 子命令需要连接服务器
    if let Cmd::Lsp { ref sub } = cli.cmd {
        let project_root = project::resolve_project_root(project).ok();
        let lsp_port = discover_lsp_port(cli.port, project_root.as_deref());

        let client = match GodotLspClient::connect(&cli.host, lsp_port, project).await {
            Ok(c) => c,
            Err(_) => {
                eprintln!("Failed to connect to Godot LSP at {}:{}", cli.host, lsp_port);
                eprintln!(
                    "Make sure Godot is running with: godot --editor --headless --lsp-port {} --path /your/project",
                    lsp_port
                );
                std::process::exit(1);
            }
        };

        // ... 后续 match sub 逻辑不变 ...
```

注意：`project` 变量已经在 `run()` 开头定义（`let project = cli.project.as_deref();`），但这里需要 `project_root`（已解析的绝对路径）来读取 `gdapi_meta`。所以用 `project::resolve_project_root(project).ok()` 获取。

同时需要更新 Status 命令的处理：

```rust
    // Status 命令单独处理：即使连接失败也要友好输出
    if matches!(cli.cmd, Cmd::Status) {
        let project_root = project::resolve_project_root(project).ok();
        let lsp_port = discover_lsp_port(cli.port, project_root.as_deref());
        return handle_status_command(&cli.host, lsp_port, project, cli.json).await;
    }
```

- [ ] **步骤 4：更新 Status 命令中的端口显示**

修改 `handle_status_command` 函数，显示发现的端口：

```rust
async fn handle_status_command(
    host: &str,
    port: u16,  // 现在是已发现的端口
    project: Option<&Path>,
    json_mode: bool,
) -> Result<()> {
    // ... 现有逻辑不变，但使用传入的 port 参数 ...
```

- [ ] **步骤 5：编写集成测试**

创建 `cli/tests/lsp_port_discovery.rs`：

```rust
//! LSP 端口发现集成测试。

use assert_cmd::Command;
use std::fs;
use tempfile::TempDir;

fn setup_project_with_gdapi_meta(meta_json: &str) -> TempDir {
    let dir = TempDir::new().unwrap();
    fs::write(dir.path().join("project.godot"), "config_version=5\n").unwrap();
    fs::create_dir(dir.path().join(".godot")).unwrap();
    fs::write(dir.path().join(".godot").join("gdapi.json"), meta_json).unwrap();
    dir
}

#[test]
fn lsp_uses_port_from_gdapi_meta() {
    // 项目有 .godot/gdapi.json 指定 lsp_port=6006
    // gdcli lsp 应该尝试连接 6006 而非默认 6005
    let dir = setup_project_with_gdapi_meta(
        r#"{"http_port":7891,"lsp_port":6006,"pid":12345,"gdapi_version":"0.2.0"}"#,
    );

    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["lsp", "capabilities", "--project", dir.path().to_str().unwrap()])
        .assert()
        .failure()
        // 应该尝试连接 6006（会失败，因为没有 LSP 在 6006）
        .stderr(predicates::str::contains("6006"));
}

#[test]
fn lsp_explicit_port_overrides_meta() {
    // 项目有 .godot/gdapi.json 指定 lsp_port=6006
    // 但 --port 6007 显式指定
    // gdcli lsp 应该尝试连接 6007
    let dir = setup_project_with_gdapi_meta(
        r#"{"http_port":7891,"lsp_port":6006,"pid":12345,"gdapi_version":"0.2.0"}"#,
    );

    Command::cargo_bin("gdcli")
        .unwrap()
        .args([
            "lsp",
            "capabilities",
            "--project",
            dir.path().to_str().unwrap(),
            "--port",
            "6007",
        ])
        .assert()
        .failure()
        .stderr(predicates::str::contains("6007"));
}

#[test]
fn lsp_falls_back_to_default_6005() {
    // 项目没有 .godot/gdapi.json
    // gdcli lsp 应该尝试连接默认 6005
    let dir = TempDir::new().unwrap();
    fs::write(dir.path().join("project.godot"), "config_version=5\n").unwrap();

    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["lsp", "capabilities", "--project", dir.path().to_str().unwrap()])
        .assert()
        .failure()
        .stderr(predicates::str::contains("6005"));
}

#[test]
fn status_uses_port_from_gdapi_meta() {
    // gdcli status 也应该使用发现的端口
    let dir = setup_project_with_gdapi_meta(
        r#"{"http_port":7891,"lsp_port":6006,"pid":12345,"gdapi_version":"0.2.0"}"#,
    );

    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["status", "--project", dir.path().to_str().unwrap()])
        .assert()
        .failure()
        .stderr(predicates::str::contains("6006"));
}
```

- [ ] **步骤 6：运行测试验证通过**

运行：`cargo test -p gdcli --test lsp_port_discovery`
预期：4 个测试全部通过。

运行：`cargo test -p gdcli`
预期：全部通过。

- [ ] **步骤 7：Commit**

```bash
git add -A
git commit -m "feat(cli): add LSP port discovery from .godot/gdapi.json"
```

---

## 阶段 5 完成标准

执行完所有任务后应达到：

1. `cargo build --workspace` 全部成功
2. `cargo test --workspace` 全部通过
3. `gdcli lsp capabilities --project <dir>` 自动从 `.godot/gdapi.json` 读取 `lsp_port`
4. `gdcli lsp capabilities --project <dir> --port 6007` 使用显式指定的端口
5. `gdcli status --project <dir>` 也使用发现的端口
6. 没有 `.godot/gdapi.json` 时回退到默认 6005

阶段 5 验证成功后，所有 5 个阶段全部完成。
