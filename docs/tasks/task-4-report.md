# Task 4 Report: 集成到 exec 模块

## 实现内容

将 `format::clap_style::render_commands` 和 `format::clap_style::render_command_help` 集成到 `exec.rs` 的渲染逻辑中。

### 核心改动

**`cli/src/exec.rs:96-101`** — 非 JSON 模式下的渲染分发：

```rust
// Before:
let rendered = format::render_exec_body(&body);

// After:
let rendered = match command {
    "commands" => format::clap_style::render_commands(&body),
    "command-help" => format::clap_style::render_command_help(&body),
    _ => format::render_exec_body(&body),
};
```

**`cli/tests/exec_integration.rs`** — 新增 3 个测试 + 更新 4 个现有测试：

新增：
- `exec_commands_clap_style_output` — 验证 `commands` 输出 clap 风格（含 "Commands:" header、命令名、摘要）
- `exec_command_help_clap_style_output` — 验证 `command-help` 输出 clap 风格（含 "Usage:"、参数格式）
- `exec_commands_json_flag_preserves_raw` — 验证 `--json` 模式下 `commands` 仍输出原始 JSON

更新（因 `commands` 现在走 clap 风格而非 TOON）：
- `exec_commands_list_passes_through_server_json` — 断言从 TOON 改为 clap 风格
- `exec_toon_tabular_uniform_array` → 重命名为 `exec_commands_clap_style_two_commands`
- `exec_toon_with_r1_empty_array` → 重命名为 `exec_commands_clap_style_with_params`
- `exec_command_help_with_path_sends_command_body` — 断言从 "doc" 改为 "保存场景" + "Usage:"

## 测试结果

- **20/20 exec_integration 测试通过**
- **189/189 全 workspace 测试通过**
- `cargo fmt --check` 干净
- `cargo clippy --workspace` 无新增警告

## TDD 证据

### RED（实现前）
```
running 3 tests
test exec_commands_clap_style_output ... FAILED
test exec_commands_clap_style_two_commands ... FAILED
test exec_commands_clap_style_with_params ... FAILED
```
失败原因：exec.rs 仍使用 `render_exec_body`（TOON 格式），输出为 `ok: true\ncommands[1|]{path|summary|params}:...`，不含 "Commands:" header。

### GREEN（实现后）
```
running 20 tests
test exec_commands_clap_style_output ... ok
test exec_command_help_clap_style_output ... ok
test exec_commands_json_flag_preserves_raw ... ok
... (all 20 passed)
```

## 更改的文件

- `cli/src/exec.rs` — 渲染分发逻辑（1 处改动）
- `cli/tests/exec_integration.rs` — 新增 3 个测试 + 更新 4 个现有测试断言

## 自我发现

1. **现有测试需要更新**：`commands` 和 `command-help` 从 TOON 切换到 clap 风格后，4 个现有测试的断言失效。已更新为匹配新行为。
2. **重命名了 2 个测试**：`exec_toon_tabular_uniform_array` 和 `exec_toon_with_r1_empty_array` 原本测试 TOON 的 tabular 输出，现在改为测试 clap 风格，名称已相应更新。
3. **错误路径未改动**：`exec.rs` 中 `Err(ureq::Error::Status(...))` 分支仍使用 `render_exec_body`，这是正确的 — 错误响应不需要 clap 风格渲染。
