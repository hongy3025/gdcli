# gdcli exec commands/command-help clap 风格输出 — 设计规格

- **日期**：2026-06-27
- **状态**：Working Draft
- **作用域**：`gdcli exec commands` 和 `gdcli exec command-help` 子命令的输出层
- **相关参考**：
  - TOON 输出设计：`docs/superpowers/specs/2026-06-24-exec-toon-output-design.md`
  - clap 帮助输出格式：`gdcli --help` 和 `gdcli exec --help`

---

## 1. 背景与目标

### 1.1 现状

- `gdcli exec commands` 和 `gdcli exec command-help` 当前使用 TOON 格式输出
- TOON 格式适合数据消费，但对于命令列表和帮助信息，clap 风格的输出更直观
- 现有的 `format::render_exec_body` 函数统一处理所有 exec 命令的输出

### 1.2 目标

1. `gdcli exec commands` 以 clap 子命令列表格式输出，便于人类阅读和 AI agent 理解
2. `gdcli exec command-help <path>` 以 clap `--help` 格式输出，提供完整的命令帮助信息
3. 保持 `--json` 标志的原始 JSON 输出功能
4. 其他 exec 命令保持现有的 TOON 格式输出

### 1.3 非目标

- 不修改 gdapi addon 的响应内容或协议
- 不修改其他 exec 命令的输出格式
- 不添加新的命令行参数或标志

---

## 2. 总体架构

```
gdcli exec commands [--json]
gdcli exec command-help <path> [--json]
        │
        ▼
┌──────────────────────────┐
│  HTTP request to gdapi   │  (与现状一致)
└──────────────┬───────────┘
               ▼
        ┌──────────────┐
        │ resp body    │  (JSON)
        └──────┬───────┘
               │
        ┌──────▼──────────────┐
        │  cli.json == true ? │
        └──┬──────────────┬───┘
           │ yes          │ no
           ▼              ▼
    ┌────────────┐  ┌─────────────────────┐
    │ 原始 JSON  │  │ 命令类型判断        │
    │ 输出       │  └──┬──────────────┬───┘
    └────────────┘     │              │
                       ▼              ▼
               ┌────────────┐  ┌────────────┐
               │ commands   │  │ command-   │
               │ → clap列表 │  │ help →     │
               │            │  │ clap帮助   │
               └────────────┘  └────────────┘
```

---

## 3. 详细设计

### 3.1 新增模块

创建 `cli/src/format/clap_style.rs` 模块，包含以下函数：

```rust
/// 将 commands 响应转换为 clap 风格的子命令列表
pub fn render_commands(body: &str) -> Cow<'_, str>

/// 将 command-help 响应转换为 clap 风格的完整帮助信息
pub fn render_command_help(body: &str) -> Cow<'_, str>
```

### 3.2 commands 命令输出格式

**输入示例**（gdapi 响应）：
```json
{
  "ok": true,
  "commands": [
    {"path": "ping", "summary": "健康检查", "params": []},
    {"path": "editor/scene/save", "summary": "保存场景", "params": ["scene_path"]},
    {"path": "shared/godot/version", "summary": "获取 Godot 版本", "params": []}
  ]
}
```

**输出格式**：
```
Commands:
  ping                  健康检查
  editor/scene/save     保存场景
  shared/godot/version  获取 Godot 版本
```

**格式规则**：
1. 标题行 "Commands:" 后跟换行
2. 每个命令占一行，格式为 `  {path}  {summary}`
3. 命令名左对齐，描述信息左对齐
4. 命令名和描述之间用空格对齐（最小 2 个空格，最大列宽根据最长命令名计算）
5. 不显示 `ok` 字段和 `params` 信息
6. 如果响应格式不符合预期，回退到 TOON 格式

### 3.3 command-help 命令输出格式

**输入示例**（gdapi 响应）：
```json
{
  "ok": true,
  "doc": {
    "path": "editor/scene/save",
    "summary": "保存场景",
    "params": [
      {"name": "scene_path", "type": "string", "required": true, "desc": "场景文件路径"},
      {"name": "new_path", "type": "string", "required": false, "desc": "另存为路径"}
    ],
    "returns": "bool",
    "example": "gdcli exec editor/scene/save --data '{\"scene_path\":\"new.tscn\"}'"
  }
}
```

**输出格式**：
```
保存场景

Usage: gdcli exec editor/scene/save [OPTIONS]

Arguments:
  <scene_path>   场景文件路径 [required]
  [new_path]     另存为路径

Returns:
  bool

Example:
  gdcli exec editor/scene/save --data '{"scene_path":"new.tscn"}'
```

**格式规则**：
1. 第一行：命令摘要（`summary` 字段）
2. 空行后：Usage 行，格式为 `Usage: gdcli exec {path} [OPTIONS]`
3. 如果有参数，显示 "Arguments:" 部分：
   - 必选参数用 `<name>` 包裹
   - 可选参数用 `[name]` 包裹
   - 参数格式：`  <name>   {desc} [required]` 或 `  [name]   {desc}`
4. 如果有返回值，显示 "Returns:" 部分
5. 如果有示例，显示 "Example:" 部分
6. 不显示 `ok` 字段和 `path` 字段（path 已在 Usage 中使用）
7. 如果响应格式不符合预期，回退到 TOON 格式

### 3.4 exec.rs 修改

修改 `cli/src/exec.rs` 中的渲染逻辑：

```rust
// 在 run 函数中，修改渲染部分
if json_mode {
    let reordered = format::reorder_ok_json(&body);
    print!("{}", reordered);
} else {
    let rendered = match command {
        "commands" => format::clap_style::render_commands(&body),
        "command-help" => format::clap_style::render_command_help(&body),
        _ => format::render_exec_body(&body),
    };
    print!("{}", rendered);
    if !rendered.ends_with('\n') {
        println!();
    }
}
```

### 3.5 format/mod.rs 修改

在 `format/mod.rs` 中添加模块声明：

```rust
pub mod clap_style;
```

---

## 4. 错误处理

### 4.1 JSON 解析失败

如果响应体不是有效的 JSON，保持现有的回退行为（原样输出）。

### 4.2 响应格式不符合预期

如果响应体是 JSON 但不符合预期格式（如缺少 `commands` 或 `doc` 字段），回退到 TOON 格式输出。

### 4.3 错误响应

对于错误响应（`ok: false`），保持现有的错误处理逻辑，不进行 clap 风格渲染。

---

## 5. 测试策略

### 5.1 单元测试

在 `cli/src/format/clap_style.rs` 中添加单元测试：

1. `render_commands` 测试：
   - 正常的 commands 列表
   - 空的 commands 列表
   - 缺少 `commands` 字段的响应
   - 缺少 `ok` 字段的响应

2. `render_command_help` 测试：
   - 完整的 command-help 响应
   - 缺少可选字段的响应（如 `returns`、`example`）
   - 缺少 `doc` 字段的响应
   - 空的 `params` 数组

### 5.2 集成测试

在 `cli/tests/exec_integration.rs` 中添加集成测试：

1. `exec_commands_clap_style_output`：验证 commands 命令的 clap 风格输出
2. `exec_command_help_clap_style_output`：验证 command-help 命令的 clap 风格输出
3. `exec_commands_json_flag_preserves_raw`：验证 `--json` 标志仍然输出原始 JSON

---

## 6. 实现计划

### 6.1 第一阶段：创建 clap_style 模块

1. 创建 `cli/src/format/clap_style.rs` 文件
2. 实现 `render_commands` 函数
3. 实现 `render_command_help` 函数
4. 添加单元测试

### 6.2 第二阶段：集成到 exec 模块

1. 修改 `cli/src/format/mod.rs`，添加 `clap_style` 模块声明
2. 修改 `cli/src/exec.rs`，根据命令类型选择渲染函数
3. 添加集成测试

### 6.3 第三阶段：文档和验证

1. 更新 README.md，添加 clap 风格输出的示例
2. 运行所有测试，确保功能正常
3. 验证 `--json` 标志仍然正常工作

---

## 7. 兼容性

### 7.1 向后兼容

- 保持 `--json` 标志的原始 JSON 输出功能
- 其他 exec 命令的 TOON 格式输出不变
- 错误处理逻辑不变

### 7.2 未来扩展

- 可以轻松添加其他命令的 clap 风格渲染
- 可以根据需要调整输出格式（如添加颜色、对齐方式等）

---

## 8. 设计决策

### 8.1 为什么选择 clap 风格？

1. **人类可读性**：clap 风格的输出更符合 CLI 工具的习惯
2. **AI agent 友好**：结构化的输出更容易被 AI agent 解析
3. **一致性**：与 gdcli 自身的 `--help` 输出保持一致

### 8.2 为什么只处理 commands 和 command-help？

1. **这两个命令是查询命令**：主要用于获取信息，而非执行操作
2. **输出结构适合 clap 风格**：命令列表和帮助信息天然适合 clap 格式
3. **其他命令保持 TOON 格式**：数据密集型的响应更适合 TOON 格式

### 8.3 为什么在 format 模块中实现？

1. **职责单一**：format 模块负责输出格式化，clap_style 是其自然扩展
2. **代码复用**：可以在其他地方复用 clap_style 函数
3. **测试方便**：可以独立测试格式化逻辑
