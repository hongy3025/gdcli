# Task 1: 创建 clap_style 模块基础结构

**Files:**
- Create: `cli/src/format/clap_style.rs`
- Modify: `cli/src/format/mod.rs`

**Interfaces:**
- Consumes: `serde_json::Value` (JSON 响应体)
- Produces: `Cow<'_, str>` (渲染后的字符串)

- [ ] **Step 1: 创建 clap_style.rs 文件并添加基础结构**

```rust
//! clap 风格输出渲染模块。
//!
//! 提供 `render_commands` 和 `render_command_help` 函数，
//! 将 gdapi 响应转换为类似 clap 的帮助输出格式。

use std::borrow::Cow;
use serde_json::Value;

/// 将 commands 响应转换为 clap 风格的子命令列表。
///
/// # Arguments
/// * `body` - JSON 响应体字符串
///
/// # Returns
/// clap 风格的命令列表字符串，如果解析失败则回退到 TOON 格式
pub fn render_commands(body: &str) -> Cow<'_, str> {
    // TODO: 实现渲染逻辑
    Cow::Borrowed(body)
}

/// 将 command-help 响应转换为 clap 风格的完整帮助信息。
///
/// # Arguments
/// * `body` - JSON 响应体字符串
///
/// # Returns
/// clap 风格的帮助信息字符串，如果解析失败则回退到 TOON 格式
pub fn render_command_help(body: &str) -> Cow<'_, str> {
    // TODO: 实现渲染逻辑
    Cow::Borrowed(body)
}
```

- [ ] **Step 2: 修改 format/mod.rs 添加模块声明**

在 `cli/src/format/mod.rs` 文件的第 9 行后添加：

```rust
pub mod clap_style;
```

- [ ] **Step 3: 验证模块编译通过**

Run: `cargo build -p gdcli`
Expected: 编译成功，无错误

- [ ] **Step 4: Commit**

```bash
git add cli/src/format/clap_style.rs cli/src/format/mod.rs
git commit -m "feat(format): add clap_style module skeleton"
```
