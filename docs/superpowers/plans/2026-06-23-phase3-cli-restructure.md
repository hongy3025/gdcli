# 阶段 3：CLI 重构（LSP 命令归入 lsp 命名空间） 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 将现有所有 LSP 子命令降级到 `gdcli lsp <subcommand>` 命名空间，为新功能腾出顶层命令空间。

**架构：** 使用 clap 的嵌套 subcommand 特性，将 `Cmd` 枚举中的 LSP 相关变体提取到独立的 `LspCmd` 枚举，`Cmd` 新增 `Lsp` 变体包含 `LspCmd`。LSP 连接逻辑和命令处理器保持不变，只是重新组织调用路径。

**技术栈：** Rust 2021 / clap 4（嵌套 subcommand）

---

## 文件结构

**修改：**
- `cli/src/main.rs` — 重构 Cmd 枚举、run() 函数、添加 LspCmd 枚举

**新建：**
- `cli/tests/lsp_subcommand.rs` — 验证 lsp 子命令仍可工作

**职责边界：**
- `LspCmd` 枚举：包含所有 LSP 子命令（Rename, References, Definition, Declaration, Symbols, Hover, NativeSymbol, Diagnostics, Capabilities）
- `Cmd` 枚举：Install, Exec, Status, Lsp
- Status 保持顶层（因为它有特殊的连接失败处理逻辑）

---

## 任务 1：提取 LspCmd 枚举并重构 Cmd

**文件：**
- 修改：`cli/src/main.rs`

- [ ] **步骤 1：添加 LspCmd 枚举**

在 `Cmd` 枚举之前添加：

```rust
/// 【LspCmd — LSP 子命令枚举】
///
/// 通过 `gdcli lsp <subcommand>` 访问。
/// 这些命令需要连接 Godot LSP 服务器。
#[derive(Subcommand)]
enum LspCmd {
    /// 重命名符号：gdcli lsp rename <target> <new_name>
    Rename { target: String, new_name: String },
    /// 查找引用：gdcli lsp references <target>
    References { target: String },
    /// 跳转到定义：gdcli lsp definition <target>
    Definition { target: String },
    /// 跳转到声明：gdcli lsp declaration <target>
    Declaration { target: String },
    /// 列出文件中的符号：gdcli lsp symbols <file>
    Symbols { file: PathBuf },
    /// 获取悬浮提示：gdcli lsp hover <target>
    Hover { target: String },
    /// 查询 Godot 原生类文档（Godot LSP 扩展）
    #[command(name = "native-symbol")]
    NativeSymbol {
        #[arg(long, conflicts_with = "full")]
        members: bool,
        #[arg(long, conflicts_with = "members")]
        full: bool,
        class: String,
        member: Option<String>,
    },
    /// 获取诊断信息（编译错误/警告）
    Diagnostics { file: Option<PathBuf> },
    /// 查询服务器能力列表
    Capabilities,
}
```

- [ ] **步骤 2：重构 Cmd 枚举**

将 `Cmd` 枚举中的 LSP 相关变体替换为 `Lsp` 变体：

```rust
#[derive(Subcommand)]
enum Cmd {
    /// 与 Godot LSP 服务器交互：gdcli lsp <subcommand>
    Lsp {
        #[command(subcommand)]
        sub: LspCmd,
    },
    /// 检查与 LSP 服务器的连接状态
    Status,
    /// 在目标项目安装 gdapi addon
    Install {
        #[arg(long)]
        force: bool,
        #[arg(long)]
        no_enable: bool,
    },
    /// 通过 HTTP 调用 gdapi 路由
    Exec {
        command: String,
        #[arg(long)]
        data: Option<String>,
        #[arg(long, default_value_t = 30)]
        timeout: u64,
    },
}
```

- [ ] **步骤 3：重构 run() 函数中的命令分发**

在 `run()` 函数中，更新命令分发逻辑：

```rust
async fn run() -> Result<()> {
    let cli = Cli::parse();
    let project = cli.project.as_deref();

    // Install 子命令不需要 LSP 连接，提前处理
    if let Cmd::Install { force, no_enable } = cli.cmd {
        let project_root = project::resolve_project_root(project)
            .map_err(|e| anyhow::anyhow!(e))?;
        install::run(install::InstallArgs {
            project_root,
            force,
            no_enable,
        })?;
        return Ok(());
    }

    // Exec 子命令不需要 LSP 连接，提前处理
    if let Cmd::Exec { ref command, ref data, timeout } = cli.cmd {
        let project_root = project::resolve_project_root(project)
            .map_err(|e| anyhow::anyhow!(e))?;
        let code = exec::run(&project_root, command, data.as_deref(), timeout)?;
        std::process::exit(code);
    }

    // Status 命令单独处理：即使连接失败也要友好输出
    if matches!(cli.cmd, Cmd::Status) {
        return handle_status_command(&cli.host, cli.port, project, cli.json).await;
    }

    // LSP 子命令需要连接服务器
    if let Cmd::Lsp { ref sub } = cli.cmd {
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
            match sub {
                LspCmd::Capabilities => {
                    let caps = client.server_capabilities().await;
                    println!("{}", serde_json::to_string_pretty(&caps)?);
                }
                LspCmd::Rename { target, new_name } => {
                    handle_rename_command(&client, target, new_name, project, cli.json).await?;
                }
                LspCmd::References { target } => {
                    handle_references_command(&client, target, project, cli.json).await?;
                }
                LspCmd::Definition { target } => {
                    handle_definition_command(&client, target, project, cli.json).await?;
                }
                LspCmd::Declaration { target } => {
                    handle_declaration_command(&client, target, project, cli.json).await?;
                }
                LspCmd::Symbols { file } => {
                    handle_symbols_command(&client, file, project, cli.json).await?;
                }
                LspCmd::Hover { target } => {
                    handle_hover_command(&client, target, project, cli.json).await?;
                }
                LspCmd::NativeSymbol { members, full, class, member } => {
                    handle_native_symbol_command(&client, class, member.as_deref(), *members, *full, cli.json).await?;
                }
                LspCmd::Diagnostics { file } => {
                    handle_diagnostics_command(&client, file.as_deref(), project, cli.json).await?;
                }
            }
            Ok(())
        }
        .await;

        client.disconnect().await;
        return result;
    }

    // 不应该到达这里
    unreachable!()
}
```

注意：原来的 `match cli.cmd` 变成了 `if let Cmd::Lsp { ref sub } = cli.cmd`，因为 LSP 命令现在是嵌套的。

- [ ] **步骤 4：验证编译通过**

运行：`cargo build -p gdcli`
预期：编译成功。可能有一些 dead_code 警告（如果某些函数不再被调用）。

- [ ] **步骤 5：运行测试验证通过**

运行：`cargo test -p gdcli`
预期：所有现有测试通过。注意：一些测试可能需要更新命令格式（从 `gdcli rename` 改为 `gdcli lsp rename`）。

如果测试失败，检查测试代码中的命令调用格式并更新。

- [ ] **步骤 6：编写 lsp 子命令集成测试**

创建 `cli/tests/lsp_subcommand.rs`：

```rust
//! gdcli lsp 子命令集成测试。
//!
//! 验证 lsp 子命令的命令行解析是否正确。

use assert_cmd::Command;

#[test]
fn lsp_rename_parses_correctly() {
    // 验证 lsp rename 命令可以被解析（不需要实际连接 LSP）
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["lsp", "rename", "player.gd:10:5", "new_name"])
        .assert()
        .failure() // 会因为连接失败而失败，但不是参数错误
        .stderr(predicates::str::contains("Failed to connect"));
}

#[test]
fn lsp_references_parses_correctly() {
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["lsp", "references", "player.gd:10:5"])
        .assert()
        .failure()
        .stderr(predicates::str::contains("Failed to connect"));
}

#[test]
fn lsp_definition_parses_correctly() {
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["lsp", "definition", "player.gd:10:5"])
        .assert()
        .failure()
        .stderr(predicates::str::contains("Failed to connect"));
}

#[test]
fn lsp_symbols_parses_correctly() {
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["lsp", "symbols", "player.gd"])
        .assert()
        .failure()
        .stderr(predicates::str::contains("Failed to connect"));
}

#[test]
fn lsp_native_symbol_parses_correctly() {
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["lsp", "native-symbol", "Node3D"])
        .assert()
        .failure()
        .stderr(predicates::str::contains("Failed to connect"));
}

#[test]
fn lsp_diagnostics_parses_correctly() {
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["lsp", "diagnostics"])
        .assert()
        .failure()
        .stderr(predicates::str::contains("Failed to connect"));
}

#[test]
fn lsp_capabilities_parses_correctly() {
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["lsp", "capabilities"])
        .assert()
        .failure()
        .stderr(predicates::str::contains("Failed to connect"));
}

#[test]
fn old_top_level_rename_fails() {
    // 验证旧的顶层命令不再有效
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["rename", "player.gd:10:5", "new_name"])
        .assert()
        .failure()
        .stderr(predicates::str::contains("error"));
}
```

- [ ] **步骤 7：运行所有测试验证通过**

运行：`cargo test -p gdcli`
预期：全部通过。

- [ ] **步骤 8：Commit**

```bash
git add -A
git commit -m "refactor(cli): move LSP commands under 'gdcli lsp' subcommand"
```

---

## 阶段 3 完成标准

执行完所有任务后应达到：

1. `cargo build --workspace` 全部成功
2. `cargo test --workspace` 全部通过
3. `gdcli lsp rename player.gd:10:5 new_name` 等命令格式正确解析
4. 旧的 `gdcli rename player.gd:10:5 new_name` 格式不再有效（返回错误）
5. `gdcli exec`、`gdcli install`、`gdcli status` 保持不变
6. 现有 LSP 测试（mock_lsp）仍通过

阶段 3 验证成功后，进入阶段 4（路由批量迁移）规划。
