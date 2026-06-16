# native-symbol 渐进式文档展示 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 为 `gdcli native-symbol` 命令添加 `--members` 和 `--full` 选项，实现渐进式披露的文档展示。

**架构：** 在现有 `handle_native_symbol_command` 基础上扩展分发逻辑，新增三个格式化函数处理四种输出形态。LSP 请求层不变，仅改动输出格式化。

**技术栈：** Rust, clap 4, serde_json

**规格文件：** `docs/superpowers/specs/2026-06-17-native-symbol-progressive-doc-design.md`

---

## 文件结构

| 文件 | 变更类型 | 职责 |
|------|----------|------|
| `src/main.rs:82-104` | 修改 | `Cmd::NativeSymbol` 增加 `--members` 和 `--full` flag |
| `src/main.rs:369-371` | 修改 | `run()` 中 dispatch 传递新参数 |
| `src/main.rs:643-675` | 修改 | `handle_native_symbol_command` 重构分发逻辑 |
| `src/main.rs` (新增) | 创建 | `first_line`, `format_native_member`, `format_native_members_table`, `format_native_full` 四个函数 |
| `tests/mock_lsp.rs` | 修改 | 新增集成测试 |

## Kind 分组映射

Godot LSP 实际使用的 SymbolKind（来自 `gdscript_workspace.cpp`）：

| 组名 | Kind 值 | SYMBOL_KINDS 名称 |
|------|---------|-------------------|
| Constants | 14 | Constant |
| Properties | 13 | Variable |
| Signals | 24 | Event |
| Methods | 6 | Method |
| Constructors | 9 | Constructor |
| Operators | 25 | Operator |
| Annotations | 10 | Enum |

---

### 任务 1：CLI 参数变更

**文件：**
- 修改：`src/main.rs:95-97`

- [ ] **步骤 1：修改 Cmd::NativeSymbol 枚举变体**

将 `src/main.rs` 第 95-97 行：

```rust
    /// 查询 Godot 原生类文档（Godot LSP 扩展）
    #[command(name = "native-symbol")]
    NativeSymbol { class: String, member: Option<String> },
```

改为：

```rust
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
```

- [ ] **步骤 2：编译验证**

运行：`cargo check`
预期：编译通过，`run()` 中 match 报错需更新（任务 2 修复）

---

### 任务 2：更新 dispatch 调用

**文件：**
- 修改：`src/main.rs:369-371`

- [ ] **步骤 1：更新 run() 中的 dispatch**

将第 369-371 行：

```rust
            Cmd::NativeSymbol { class, member } => {
                handle_native_symbol_command(&client, &class, member.as_deref(), cli.json).await?;
            }
```

改为：

```rust
            Cmd::NativeSymbol { members, full, class, member } => {
                handle_native_symbol_command(&client, &class, member.as_deref(), members, full, cli.json).await?;
            }
```

- [ ] **步骤 2：编译验证**

运行：`cargo check`
预期：编译通过（handle 函数签名还没改，会报错，任务 3 修复）

---

### 任务 3：新增格式化函数 + 重构 handler

**文件：**
- 修改：`src/main.rs:643-675`（handle_native_symbol_command）
- 创建：四个新函数放在 handle 函数之前

- [ ] **步骤 1：新增 `first_line` 辅助函数**

在 `handle_native_symbol_command` 函数之前插入：

```rust
fn first_line(doc: &str) -> &str {
    doc.lines().next().unwrap_or("").trim()
}
```

- [ ] **步骤 2：新增 `format_native_member` 函数**

```rust
fn format_native_member(v: &Value) {
    let name = v.get("name").and_then(|x| x.as_str()).unwrap_or("?");
    let detail = v.get("detail").and_then(|x| x.as_str());
    let docs = v.get("documentation").and_then(|x| x.as_str());
    println!("{}", name);
    if let Some(d) = detail {
        println!("  {}", d);
    }
    if let Some(d) = docs {
        println!();
        println!("  {}", d);
    }
}
```

- [ ] **步骤 3：新增 `format_native_members_table` 函数**

```rust
fn format_native_members_table(children: &[Value]) {
    let groups: [(u32, &str); 7] = [
        (14, "Constants"),
        (13, "Properties"),
        (24, "Signals"),
        (6, "Methods"),
        (9, "Constructors"),
        (25, "Operators"),
        (10, "Annotations"),
    ];
    for (kind, label) in &groups {
        let members: Vec<&Value> = children
            .iter()
            .filter(|c| c.get("kind").and_then(|x| x.as_u64()).unwrap_or(0) == *kind as u64)
            .collect();
        if members.is_empty() {
            continue;
        }
        println!("{}:", label);
        for m in members {
            let name = m.get("name").and_then(|x| x.as_str()).unwrap_or("?");
            let detail = m.get("detail").and_then(|x| x.as_str()).unwrap_or("");
            let docs = m.get("documentation").and_then(|x| x.as_str()).unwrap_or("");
            let brief = first_line(docs);
            if brief.is_empty() {
                println!("  {:<28} {}", name, detail);
            } else {
                println!("  {:<28} {:<40} {}", name, detail, brief);
            }
        }
        println!();
    }
    let known_kinds: [u32; 7] = [14, 13, 24, 6, 9, 25, 10];
    let others: Vec<&Value> = children
        .iter()
        .filter(|c| {
            let k = c.get("kind").and_then(|x| x.as_u64()).unwrap_or(0) as u32;
            !known_kinds.contains(&k)
        })
        .collect();
    if !others.is_empty() {
        println!("Other:");
        for m in others {
            let name = m.get("name").and_then(|x| x.as_str()).unwrap_or("?");
            let detail = m.get("detail").and_then(|x| x.as_str()).unwrap_or("");
            println!("  {:<28} {}", name, detail);
        }
        println!();
    }
}
```

- [ ] **步骤 4：新增 `format_native_full` 函数**

```rust
fn format_native_full(children: &[Value]) {
    let groups: [(u32, &str); 7] = [
        (14, "Constants"),
        (13, "Properties"),
        (24, "Signals"),
        (6, "Methods"),
        (9, "Constructors"),
        (25, "Operators"),
        (10, "Annotations"),
    ];
    for (kind, label) in &groups {
        let members: Vec<&Value> = children
            .iter()
            .filter(|c| c.get("kind").and_then(|x| x.as_u64()).unwrap_or(0) == *kind as u64)
            .collect();
        if members.is_empty() {
            continue;
        }
        println!("── {} ──", label);
        println!();
        for m in members {
            format_native_member(m);
            println!();
        }
    }
    let known_kinds: [u32; 7] = [14, 13, 24, 6, 9, 25, 10];
    let others: Vec<&Value> = children
        .iter()
        .filter(|c| {
            let k = c.get("kind").and_then(|x| x.as_u64()).unwrap_or(0) as u32;
            !known_kinds.contains(&k)
        })
        .collect();
    if !others.is_empty() {
        println!("── Other ──");
        println!();
        for m in others {
            format_native_member(m);
            println!();
        }
    }
}
```

- [ ] **步骤 5：重构 `handle_native_symbol_command`**

将函数签名改为：

```rust
async fn handle_native_symbol_command(
    client: &Arc<GodotLspClient>,
    class: &str,
    member: Option<&str>,
    members_flag: bool,
    full_flag: bool,
    json_mode: bool,
) -> Result<()> {
```

将函数体改为：

```rust
    let v = client.native_symbol(class, member).await?;
    if json_mode {
        println!("{}", serde_json::to_string_pretty(&decode_uris(v))?);
    } else if v.is_null() {
        println!("No documentation found.");
    } else if member.is_some() {
        format_native_member(&v);
    } else if full_flag {
        let name = v.get("name").and_then(|x| x.as_str()).unwrap_or("?");
        let detail = v.get("detail").and_then(|x| x.as_str());
        let docs = v.get("documentation").and_then(|x| x.as_str());
        if let Some(d) = detail {
            println!("{} — {}", name, d);
        } else {
            println!("{}", name);
        }
        if let Some(d) = docs {
            println!();
            println!("{}", d);
        }
        if let Some(children) = v.get("children").and_then(|x| x.as_array()) {
            println!();
            format_native_full(children);
        }
    } else if members_flag {
        if let Some(children) = v.get("children").and_then(|x| x.as_array()) {
            format_native_members_table(children);
        } else {
            println!("No members found.");
        }
    } else {
        let name = v.get("name").and_then(|x| x.as_str()).unwrap_or("?");
        let detail = v.get("detail").and_then(|x| x.as_str());
        let docs = v.get("documentation").and_then(|x| x.as_str());
        if let Some(d) = detail {
            println!("{} — {}", name, d);
        } else {
            println!("{}", name);
        }
        if let Some(d) = docs {
            println!();
            println!("{}", d);
        }
    }
    Ok(())
```

- [ ] **步骤 6：编译验证**

运行：`cargo check`
预期：编译通过

- [ ] **步骤 7：运行全部测试**

运行：`cargo test`
预期：全部通过（现有测试不受影响，因为默认行为不变）

---

### 任务 4：集成测试

**文件：**
- 修改：`tests/mock_lsp.rs`

- [ ] **步骤 1：新增互斥冲突测试**

```rust
#[test]
fn native_symbol_members_full_conflict() {
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["native-symbol", "--members", "--full", "Node"])
        .timeout(Duration::from_secs(5))
        .assert()
        .failure()
        .stderr(predicate::str::contains("cannot be used with"));
}
```

- [ ] **步骤 2：运行测试**

运行：`cargo test`
预期：全部通过

- [ ] **步骤 3：Commit**

```bash
git add src/main.rs tests/mock_lsp.rs
git commit -m "feat: native-symbol progressive doc display (--members/--full)"
```

---

### 任务 5：手动验证

- [ ] **步骤 1：构建 release**

运行：`cargo build --release`

- [ ] **步骤 2：默认形态验证（需 Godot 运行中）**

```bash
gdcli native-symbol Node3D
```
预期：类名 + detail + documentation 全文（与改动前一致）

- [ ] **步骤 3：--members 形态验证**

```bash
gdcli --json native-symbol Node3D
```
先看 JSON 中 children 的 kind 值确认分组正确，然后：

```bash
gdcli native-symbol --members Node3D
```
预期：按 Constants/Properties/Signals/Methods 分组的成员表

- [ ] **步骤 4：--full 形态验证**

```bash
gdcli native-symbol --full Node3D
```
预期：类信息 + 所有成员完整展开

- [ ] **步骤 5：单成员验证**

```bash
gdcli native-symbol Node3D get_parent
```
预期：get_parent 的 detail + 完整 documentation

- [ ] **步骤 6：互斥验证**

```bash
gdcli native-symbol --members --full Node3D
```
预期：clap 报错 "cannot be used with"
