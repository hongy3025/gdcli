# main.rs 拆分 + debug_output 实现实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 将 1100+ 行的 main.rs 拆分为更小的模块，并实现 debug_output 滚动缓冲区。

**架构：** 将 LSP 命令处理器和格式化工具提取到 `cli/src/commands/lsp.rs`，将 debug_output 路由从占位改为基于 GDScript 滚动缓冲区的真实实现。

**技术栈：** Rust 2021 / GDScript

---

## 任务 1：提取 LSP 命令处理器到 commands/lsp.rs

**文件：**
- 创建：`cli/src/commands/mod.rs`
- 创建：`cli/src/commands/lsp.rs`
- 修改：`cli/src/main.rs`

- [ ] **步骤 1：创建 cli/src/commands/mod.rs**

```rust
pub mod lsp;
```

- [ ] **步骤 2：创建 cli/src/commands/lsp.rs**

将以下函数从 main.rs 移动到 `cli/src/commands/lsp.rs`：

- `handle_status_command`
- `handle_rename_command`
- `handle_references_command`
- `handle_definition_command`
- `handle_declaration_command`
- `handle_symbols_command`
- `handle_hover_command`
- `handle_native_symbol_command`
- `handle_diagnostics_command`

以及相关的格式化工具函数：
- `format_range`
- `format_location_value`
- `severity_name`
- `format_diagnostic`
- `decode_uris`
- `print_symbols`
- `handle_locations`
- `handle_diagnostics`
- `print_rename_result`
- `print_references_result`
- `first_line`
- `format_native_member`
- `format_native_members_table`
- `format_native_full`
- `print_class_header`
- `NATIVE_KIND_GROUPS` 常量

文件结构：
```rust
//! LSP 命令处理器和格式化工具。

use lsp::client::{DiagnosticsResult, GodotLspClient};
use lsp::types::{uri_to_file, symbol_kind_name, Diagnostic, Location, Range, WorkspaceEdit};
use anyhow::Result;
use serde_json::{json, Value};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

// 格式化工具函数
// ... (从 main.rs 移动过来)

// 命令处理器
// ... (从 main.rs 移动过来)
```

- [ ] **步骤 3：更新 main.rs**

在 main.rs 中：
1. 添加 `mod commands;`
2. 删除移动到 commands/lsp.rs 的所有函数
3. 在 run() 函数中使用 `commands::lsp::handle_xxx_command(...)` 调用

- [ ] **步骤 4：验证编译通过**

运行：`cargo build -p gdcli`
预期：编译成功。

- [ ] **步骤 5：运行测试验证通过**

运行：`cargo test -p gdcli`
预期：全部通过。

- [ ] **步骤 6：Commit**

```bash
git add -A
git commit -m "refactor(cli): extract LSP command handlers to commands/lsp.rs"
```

---

## 任务 2：实现 debug_output 滚动缓冲区

**文件：**
- 修改：`gdapi/addon/routes/editor/project/debug_output.gd`
- 修改：`gdapi/addon/plugin.gd`

- [ ] **步骤 1：在 plugin.gd 中添加日志缓冲区**

在 `gdapi/addon/plugin.gd` 中添加缓冲区逻辑：

```gdscript
# 日志缓冲区
var _log_buffer: Array = []
var _log_seq: int = 0
const MAX_LOG_ENTRIES: int = 1000

func _ready() -> void:
    # 重定向 print 输出到缓冲区
    # Godot 4.x 没有直接的 print hook，但我们可以通过
    # EditorInterface 的日志信号来捕获
    pass

func _log_message(text: String, level: String = "info") -> void:
    _log_seq += 1
    _log_buffer.append({
        "seq": _log_seq,
        "level": level,
        "text": text,
        "ts": Time.get_unix_time_from_system(),
    })
    # 限制缓冲区大小
    if _log_buffer.size() > MAX_LOG_ENTRIES:
        _log_buffer.pop_front()
```

- [ ] **步骤 2：更新 debug_output.gd 路由**

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(params: Dictionary) -> Dictionary:
    var since: int = params.get("since", 0)
    var limit: int = params.get("limit", 100)

    # 从 plugin 获取缓冲区引用
    var plugin = Engine.get_meta("gdapi_plugin", null)
    if plugin == null:
        return {
            "ok": false,
            "error": "gdapi plugin not available",
            "code": "plugin_not_ready",
        }

    var buffer: Array = plugin._log_buffer
    var entries: Array = []

    # 过滤 since 之后的条目
    for entry in buffer:
        if entry.seq > since:
            entries.append(entry)
            if entries.size() >= limit:
                break

    var next_since: int = since
    if entries.size() > 0:
        next_since = entries[entries.size() - 1].seq

    return {
        "ok": true,
        "entries": entries,
        "next_since": next_since,
    }
```

- [ ] **步骤 3：在 plugin.gd 中注册自身到 Engine meta**

在 `plugin.gd` 的 `_enter_tree()` 中添加：
```gdscript
    Engine.set_meta("gdapi_plugin", self)
```

在 `_exit_tree()` 中添加：
```gdscript
    Engine.remove_meta("gdapi_plugin")
```

- [ ] **步骤 4：实现 print 捕获机制**

GDScript 没有直接的 print hook。替代方案：在 plugin.gd 中提供一个 `log()` 方法，gdapi 路由可以调用它来记录消息。同时，我们可以用 `@tool` 脚本中的 `print()` 重定向到我们的缓冲区。

更实际的方案：让 plugin 在 `_process` 中定期检查 EditorInterface 的日志输出。但 Godot 4.x API 不提供直接的日志访问。

**最终方案**：提供一个简单的 `gdapi_log(text, level)` 全局函数，任何需要记录日志的路由都可以调用。同时，在 plugin.gd 的 `_process` 中捕获 `print()` 和 `printerr()` 的输出。

实际上，Godot 4.x 的 `print()` 和 `printerr()` 输出会触发 `Console` 单例的信号。我们可以连接这些信号：

```gdscript
func _enter_tree() -> void:
    Engine.set_meta("gdapi_plugin", self)
    # 连接控制台输出信号
    # 注意：Godot 4.x 的 Console 类可能不可用
    # 使用替代方案：在 _process 中轮询
```

由于 Godot 4.x 的 API 限制，最简单的方案是：
1. 提供 `gdapi_log()` 方法供路由调用
2. 在 `_process` 中捕获自定义日志
3. 返回当前可用的日志条目

- [ ] **步骤 5：Commit**

```bash
git add -A
git commit -m "feat(gdapi): implement debug_output rolling buffer"
```

---

## 阶段完成标准

1. `cargo test --workspace` 全部通过
2. main.rs 从 1100+ 行减少到约 500 行
3. commands/lsp.rs 包含所有 LSP 命令处理器和格式化工具
4. debug_output 路由返回实际的日志条目（而非 not_implemented）
