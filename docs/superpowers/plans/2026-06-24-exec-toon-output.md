# gdcli exec 默认 TOON 输出 — 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 让 `gdcli exec` 默认以 TOON 格式输出 HTTP 响应；加 `--json` 恢复旧的 minified JSON 透传。

**架构：** 新增 `cli/src/format/` 模块（`normalize.rs` 做 R1/R2/R3/R4 启发式预处理 + `toon.rs` 包装 `toon-format` crate + `mod.rs` 暴露单个 `render_exec_body` API）。修改 `cli/src/exec.rs::run` 签名加 `json_mode: bool` 参数；修改 `cli/src/main.rs` exec 分发把 `cli.json` 透传进去。

**技术栈：**
- `toon-format = "0.5.0"`（spec 作者 Johann Schopplich 本人维护，`default-features = false` 后仅依赖 serde / serde_json / indexmap / thiserror）
- `serde_json::Value`（已有依赖）做 R1/R2/R3/R4 变换
- `assert_cmd` / `httpmock`（已有 dev-dependencies）做集成测试

**设计文档：** `docs/superpowers/specs/2026-06-24-exec-toon-output-design.md`

**Break change 提醒：** 不加 `--json` 的脚本会收到新的 TOON 输出；任务 9 会在 CHANGELOG / README 中显式标注。

---

## 文件结构

| 文件 | 角色 | 状态 |
|---|---|---|
| `cli/Cargo.toml` | 添加 `toon-format` 依赖 | 修改 |
| `cli/src/format/mod.rs` | 暴露 `render_exec_body(body: &str) -> Cow<'_, str>` | 新建 |
| `cli/src/format/normalize.rs` | R1/R2/R3/R4 启发式预处理，纯 `serde_json::Value` 变换 | 新建 |
| `cli/src/format/toon.rs` | 包装 `toon_format::encode`，固定 `Delimiter::Pipe + 2 spaces` | 新建 |
| `cli/src/main.rs` | exec 分发把 `cli.json` 透传给 `exec::run` | 修改 |
| `cli/src/exec.rs` | `run` 签名加 `json_mode: bool`；输出环节调用 `format::render_exec_body` | 修改 |
| `cli/tests/exec_integration.rs` | 默认断言走 TOON；新增 `--json` 路径断言 | 修改 |
| `README.md` | exec 章节说明默认输出格式 + `--json` | 修改 |
| `CHANGELOG.md` 或 release notes | 标注 break change | 修改/新建 |

---

## 任务 1：添加 `toon-format` 依赖并验证编译

**文件：**
- 修改：`cli/Cargo.toml`

- [ ] **步骤 1：在 `[dependencies]` 末尾添加 `toon-format`**

修改 `cli/Cargo.toml`，在第 21 行 `include_dir = "0.7"` 之后添加：

```toml
toon-format = { version = "0.5", default-features = false }
```

> 关键：`default-features = false` 必须设置——`toon-format` 0.5.0 的默认 features 是 `["cli"]`，会引入 clap、ratatui、syntect、tiktoken-rs 等一大堆 TUI 依赖。我们只要核心库。

- [ ] **步骤 2：验证 workspace 编译通过**

运行：`cargo build -p gdcli`
预期：编译通过，无新增 warning。

> 如果 build 失败，最可能的原因是 `toon-format` 的最小 feature set 隐含了 `cli`。验证办法：`cargo tree -p gdcli | Select-String "ratatui\|clap"` 应该只看到 gdcli 自己依赖的 clap，没有 ratatui。

- [ ] **步骤 3：写一个临时 smoke test 验证 API**

在 `cli/src/lib.rs` 不存在的情况下，直接在 `cli/src/exec.rs` 末尾的 `#[cfg(test)] mod build_body_tests` 内（第 263 行附近）临时加一个测试，验证 toon-format 能编译：

```rust
#[test]
fn toon_format_crate_smoke() {
    use toon_format::{encode, EncodeOptions, Delimiter};
    let v = serde_json::json!({"a":1,"b":[1,2,3]});
    let opts = EncodeOptions::new().with_delimiter(Delimiter::Pipe).with_spaces(2);
    let s = encode(&v, &opts).expect("toon-format encode should succeed");
    assert!(s.contains("a: 1"), "got: {s}");
}
```

运行：`cargo test -p gdcli toon_format_crate_smoke -- --nocapture`
预期：PASS，stdout 显示形如 `a: 1\nb[3|]: 1|2|3` 的内容。

> 如果测试输出与预期形态不符（比如 delimiter 不是 `|`），在继续之前先排查。这一步是为了**锁定 crate 的实际行为**，避免后续任务中遇到非预期编码结果。

- [ ] **步骤 4：删除 smoke test**

把刚才加的 `toon_format_crate_smoke` 测试函数删除（任务 5 会把它换成 `format/toon.rs` 的正式单元测试）。

- [ ] **步骤 5：Commit**

```bash
git add cli/Cargo.toml Cargo.lock
git commit -m "feat(cli): add toon-format dependency"
```

---

## 任务 2：创建 `format/` 模块骨架（占位实现）

**文件：**
- 创建：`cli/src/format/mod.rs`
- 创建：`cli/src/format/normalize.rs`
- 创建：`cli/src/format/toon.rs`
- 修改：`cli/src/main.rs`（添加 `mod format;` 声明）

- [ ] **步骤 1：创建 `cli/src/format/mod.rs`（占位 API）**

```rust
//! 输出格式化层。
//!
//! 提供 `render_exec_body`，把 gdapi HTTP 响应的 JSON body 渲染为 TOON 字符串。
//! 当 body 不是合法 JSON、或编码失败时，原样透传（zero-copy）。

use std::borrow::Cow;

pub mod normalize;
pub mod toon;

/// 把 HTTP 响应 body 渲染为 TOON 字符串。
///
/// - 若 body 是合法 JSON → 应用 R1/R2/R3/R4 启发式预处理 → TOON 编码
/// - 若 body 不是合法 JSON 或 TOON 编码失败 → 原样透传（`Cow::Borrowed`）
pub fn render_exec_body(body: &str) -> Cow<'_, str> {
    match serde_json::from_str::<serde_json::Value>(body) {
        Ok(value) => {
            let normalized = normalize::normalize(value);
            match toon::encode(&normalized) {
                Ok(s) => Cow::Owned(s),
                Err(_) => Cow::Borrowed(body),
            }
        }
        Err(_) => Cow::Borrowed(body),
    }
}
```

- [ ] **步骤 2：创建 `cli/src/format/normalize.rs`（占位实现）**

```rust
//! R1/R2/R3/R4 启发式预处理：在 TOON 编码前调整 `serde_json::Value` 结构，
//! 使更多数据落入紧凑的 tabular 形态。
//!
//! 详见 docs/superpowers/specs/2026-06-24-exec-toon-output-design.md §4。

use serde_json::Value;

/// 递归后序遍历 JSON 值并应用 R1/R2/R3/R4 变换。
pub fn normalize(v: Value) -> Value {
    // 占位：当前直接返回原值。任务 6 将填入完整规则。
    v
}
```

- [ ] **步骤 3：创建 `cli/src/format/toon.rs`（占位实现）**

```rust
//! 包装 `toon-format` crate 的薄层。
//!
//! 固定使用 `Delimiter::Pipe` + 2 spaces indent，
//! 这与 docs/superpowers/specs/2026-06-24-exec-toon-output-design.md §3.4 的决策对应。

use serde_json::Value;
use toon_format::{encode as toon_encode, Delimiter, EncodeOptions};

/// 把 `serde_json::Value` 编码为 TOON 字符串。
///
/// 失败时返回 `Err(String)`（错误信息，调用方决定是否透传原 body）。
pub fn encode(value: &Value) -> Result<String, String> {
    let opts = EncodeOptions::new()
        .with_delimiter(Delimiter::Pipe)
        .with_spaces(2);
    toon_encode(value, &opts).map_err(|e| format!("toon encode failed: {e}"))
}
```

- [ ] **步骤 4：在 `cli/src/main.rs` 声明 `mod format;`**

`cli/src/main.rs` 顶部的 module 声明区（其它 `mod exec;` `mod gdapi_meta;` 等附近）加一行：

```rust
mod format;
```

需要先 read 文件确定具体行号；插入位置应紧邻其它顶层 mod 声明。

- [ ] **步骤 5：验证整体编译通过**

运行：`cargo build -p gdcli`
预期：编译通过。

- [ ] **步骤 6：Commit**

```bash
git add cli/src/format/ cli/src/main.rs
git commit -m "feat(cli): scaffold format module with placeholder API"
```

---

## 任务 3：透传 `cli.json` 到 `exec::run`

**文件：**
- 修改：`cli/src/main.rs:288-293`
- 修改：`cli/src/exec.rs:39-45`（`run` 函数签名）

- [ ] **步骤 1：修改 `exec::run` 签名添加 `json_mode` 参数（先不使用）**

修改 `cli/src/exec.rs:39-45`：

```rust
pub fn run(
    project: &Path,
    command: &str,
    args: &[String],
    data: Option<&str>,
    timeout_secs: u64,
    json_mode: bool,
) -> Result<i32> {
    let _ = json_mode; // 任务 4 中接入；先标记 unused 防止 warning
```

> 注意：`let _ = json_mode;` 这一行**只是临时占位**，任务 4 第 1 步会把它删除并真正接入。

- [ ] **步骤 2：修改 `main.rs:291` 把 `cli.json` 传过去**

修改 `cli/src/main.rs:288-293`：

```rust
Cmd::Exec { ref command, ref args, ref data, timeout } => {
    let project_root = project::resolve_project_root(project)
        .map_err(|e| anyhow::anyhow!(e))?;
    let code = exec::run(
        &project_root, command, args, data.as_deref(), timeout,
        cli.json,
    )?;
    std::process::exit(code);
}
```

- [ ] **步骤 3：验证编译并跑现有测试**

运行：`cargo build -p gdcli && cargo test -p gdcli`
预期：所有现有测试 PASS（行为没变，只是签名扩展）。

- [ ] **步骤 4：Commit**

```bash
git add cli/src/exec.rs cli/src/main.rs
git commit -m "refactor(cli): plumb --json flag into exec::run"
```

---

## 任务 4：在 `exec::run` 输出环节接入 `format::render_exec_body`

**文件：**
- 修改：`cli/src/exec.rs:1-20`（imports）
- 修改：`cli/src/exec.rs:39-110`（`run` 函数 stdout/stderr 输出环节）

- [ ] **步骤 1：编写失败的集成测试覆盖默认 TOON 输出**

在 `cli/tests/exec_integration.rs` 末尾添加测试（具体行号需先 read 文件确定，但应放在文件末尾、最后一个 `}` 之前）：

```rust
#[test]
fn exec_default_outputs_toon() {
    use httpmock::prelude::*;
    let server = MockServer::start();
    server.mock(|when, then| {
        when.method(POST).path("/ping");
        then.status(200)
            .header("content-type", "application/json")
            .body(r#"{"ok":true,"gdapi_version":"0.2.0"}"#);
    });

    let temp = setup_fixture(&server);  // 复用已有 helper

    let output = assert_cmd::Command::cargo_bin("gdcli")
        .unwrap()
        .args(&["--project", temp.path().to_str().unwrap(), "exec", "ping"])
        .output()
        .unwrap();

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "exit code should be 0; stderr={}", String::from_utf8_lossy(&output.stderr));
    assert!(stdout.contains("ok: true"), "expected TOON KV form, got: {stdout}");
    assert!(stdout.contains("gdapi_version: 0.2.0"), "got: {stdout}");
    assert!(!stdout.contains(r#""ok":true"#), "should NOT contain raw JSON, got: {stdout}");
}

#[test]
fn exec_json_flag_outputs_raw_json() {
    use httpmock::prelude::*;
    let server = MockServer::start();
    server.mock(|when, then| {
        when.method(POST).path("/ping");
        then.status(200)
            .header("content-type", "application/json")
            .body(r#"{"ok":true,"gdapi_version":"0.2.0"}"#);
    });

    let temp = setup_fixture(&server);

    let output = assert_cmd::Command::cargo_bin("gdcli")
        .unwrap()
        .args(&["--json", "--project", temp.path().to_str().unwrap(), "exec", "ping"])
        .output()
        .unwrap();

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success());
    assert_eq!(stdout.trim(), r#"{"ok":true,"gdapi_version":"0.2.0"}"#);
}
```

> ⚠️ `setup_fixture(&server)` 是一个**假设存在**的 helper。如果 `cli/tests/exec_integration.rs` 没有这个函数，需要先看现有测试是怎么搭建 fixture 的（参见集成测试用 `cli/tests/exec_integration.rs:1-316`，应该有类似的 setup 模式），照着写一个。如果现有测试已经把 fixture 搭建嵌入到每个测试函数里，**就把那段代码 inline 进这两个测试**，不要新增 helper。

- [ ] **步骤 2：运行测试验证失败**

运行：`cargo test -p gdcli --test exec_integration exec_default_outputs_toon -- --nocapture`
预期：FAIL（当前 `exec::run` 还是原样透传，stdout 包含 `"ok":true` 而不包含 `ok: true`）。

- [ ] **步骤 3：修改 `exec::run` 接入 `format::render_exec_body`**

修改 `cli/src/exec.rs` 顶部 imports（第 16-21 行附近），添加：

```rust
use std::borrow::Cow;

use crate::format;
```

把 `cli/src/exec.rs:39-45` 签名中 `let _ = json_mode;` **删掉**。

把 `cli/src/exec.rs:94-110` 替换为：

```rust
    match resp {
        Ok(r) => {
            let status = r.status();
            let body = read_body(r)?;
            if json_mode {
                print!("{}", body);
            } else {
                let rendered = format::render_exec_body(&body);
                print!("{}", rendered);
                if !rendered.ends_with('\n') {
                    println!();
                }
            }
            Ok(map_status_to_exit(status, false))
        }
        Err(ureq::Error::Status(code, r)) => {
            let body = read_body(r)?;
            let rendered: Cow<'_, str> = if json_mode {
                Cow::Borrowed(body.as_str())
            } else {
                format::render_exec_body(&body)
            };
            eprintln!("Error (HTTP {}): {}", code, rendered.trim_end());
            Ok(map_status_to_exit(code, true))
        }
        Err(ureq::Error::Transport(t)) => {
            eprintln!("network error: {}", t);
            Ok(3)
        }
    }
```

- [ ] **步骤 4：运行测试验证通过**

运行：`cargo test -p gdcli --test exec_integration exec_default_outputs_toon exec_json_flag_outputs_raw_json -- --nocapture`
预期：两个测试都 PASS。stdout 包含 `ok: true\ngdapi_version: 0.2.0`（来自 toon-format 默认行为）。

- [ ] **步骤 5：跑全部测试确认不破坏现有行为**

运行：`cargo test -p gdcli`
预期：所有测试 PASS。

> 注意：如果有原本断言 stdout 是原始 JSON 字符串的旧测试现在失败了，**不要修改它们**——保留失败状态作为证据，任务 7 会专门改造它们。如果旧测试因为这个原因全失败了（>3 个），停下来在本任务 commit 之前先评估。

- [ ] **步骤 6：Commit**

```bash
git add cli/src/exec.rs cli/tests/exec_integration.rs
git commit -m "feat(cli): default to TOON output, --json restores raw JSON"
```

---

## 任务 5：完善 `format/toon.rs` 单元测试

**文件：**
- 修改：`cli/src/format/toon.rs`

- [ ] **步骤 1：在 `format/toon.rs` 末尾添加单元测试模块**

在 `cli/src/format/toon.rs` 末尾追加：

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn primitive_kv_object() {
        let v = json!({"ok": true, "version": "0.2.0"});
        let s = encode(&v).unwrap();
        assert!(s.contains("ok: true"), "got: {s}");
        assert!(s.contains("version: 0.2.0"), "got: {s}");
    }

    #[test]
    fn tabular_uniform_array() {
        let v = json!({
            "rows": [
                {"id": 1, "name": "alpha"},
                {"id": 2, "name": "beta"},
            ]
        });
        let s = encode(&v).unwrap();
        assert!(s.contains("rows[2|]{id|name}:"), "expected pipe-delim tabular header, got: {s}");
        assert!(s.contains("1|alpha"), "got: {s}");
        assert!(s.contains("2|beta"), "got: {s}");
    }

    #[test]
    fn primitive_array_inline() {
        let v = json!({"tags": ["a", "b", "c"]});
        let s = encode(&v).unwrap();
        assert!(s.contains("tags[3|]: a|b|c"), "expected pipe-delim inline array, got: {s}");
    }

    #[test]
    fn nested_object_indented() {
        let v = json!({"server": {"host": "localhost", "port": 8080}});
        let s = encode(&v).unwrap();
        assert!(s.contains("server:"), "got: {s}");
        assert!(s.contains("  host: localhost"), "got: {s}");
        assert!(s.contains("  port: 8080"), "got: {s}");
    }

    #[test]
    fn empty_object_encodes() {
        let v = json!({});
        let s = encode(&v).unwrap();
        // Per spec §5: empty object yields empty document.
        assert_eq!(s, "");
    }

    #[test]
    fn null_value() {
        let v = json!({"x": null});
        let s = encode(&v).unwrap();
        assert!(s.contains("x: null"), "got: {s}");
    }
}
```

- [ ] **步骤 2：运行 toon.rs 单元测试**

运行：`cargo test -p gdcli format::toon::tests -- --nocapture`
预期：6 个测试全部 PASS。

> 如果某个测试失败，**先不要改测试**——先确认 toon-format crate 的实际行为。预期的 `tags[3|]: a|b|c` 格式来自 spec §6 的 header 语法 + Pipe delimiter；如果 crate 的实际输出不同，说明 spec 解读有误，需要更新测试预期。

- [ ] **步骤 3：Commit**

```bash
git add cli/src/format/toon.rs
git commit -m "test(cli): cover toon encoder wrapper with unit tests"
```

---

## 任务 6：实现 `format/normalize.rs` 启发式规则

**文件：**
- 修改：`cli/src/format/normalize.rs`

- [ ] **步骤 1：编写 R3 失败测试（uniform 表格基础）**

把 `cli/src/format/normalize.rs` 整体替换为：

```rust
//! R1/R2/R3/R4 启发式预处理。详见设计文档 §4。

use serde_json::{Map, Value};

/// 递归应用 R1/R2/R3/R4 变换。
pub fn normalize(v: Value) -> Value {
    match v {
        Value::Array(arr) => {
            let arr: Vec<Value> = arr.into_iter().map(normalize).collect();
            // 当前占位：先什么都不做，让任务后续步骤填入。
            Value::Array(arr)
        }
        Value::Object(map) => {
            let mut out = Map::new();
            for (k, v) in map {
                out.insert(k, normalize(v));
            }
            Value::Object(out)
        }
        primitive => primitive,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn n(v: Value) -> Value { normalize(v) }

    #[test]
    fn r3_uniform_array_passes_through_for_encoder() {
        // R3：uniform + primitive-only 的 array of object 由 toon-format 直接 tabular 编码，
        // normalize 不需要改结构，只要保证递归正确即可。
        let v = json!([{"a":1,"b":2},{"a":3,"b":4}]);
        let out = n(v.clone());
        assert_eq!(out, v, "uniform primitive-only array should be unchanged");
    }

    #[test]
    fn r1_empty_array_becomes_empty_string() {
        // R1：含空数组的 element 应该被改写，使整个 array 满足 primitive-only。
        let v = json!([{"path":"ping","params":[]},{"path":"help","params":["x"]}]);
        let out = n(v);
        // 预期：params=[] → "", params=["x"] → "x"
        assert_eq!(
            out,
            json!([{"path":"ping","params":""},{"path":"help","params":"x"}])
        );
    }

    #[test]
    fn r1_null_unchanged_in_uniform_array() {
        // R1：null 也是等效 primitive 占位，但 null 本身就是 primitive，不需要改写。
        let v = json!([{"a":1,"b":null},{"a":2,"b":3}]);
        let out = n(v.clone());
        assert_eq!(out, v);
    }

    #[test]
    fn r2_kv_array_unchanged() {
        // R2：{item, value} 形态本来就是 uniform primitive-only，
        // normalize 不需要变换；它只确保 toon-format 走 tabular 而非 list。
        let v = json!([{"item":"代码","value":"600519"},{"item":"最新价","value":"1326.0"}]);
        let out = n(v.clone());
        assert_eq!(out, v);
    }

    #[test]
    fn nested_object_recurses() {
        let v = json!({"outer": [{"inner": []}, {"inner": ["x"]}]});
        let out = n(v);
        assert_eq!(out, json!({"outer": [{"inner": ""}, {"inner": "x"}]}));
    }

    #[test]
    fn non_uniform_array_unchanged() {
        // 不符合 R1/R2/R3 的 array 应原样保留，交给 toon-format 走 expanded list。
        let v = json!([{"a":1}, {"b":2}]);  // 不同 keys
        let out = n(v.clone());
        assert_eq!(out, v);
    }

    #[test]
    fn array_with_nested_objects_unchanged() {
        // element 含嵌套 object → 不属于 primitive-only，不变换。
        let v = json!([{"a":1,"sub":{"x":2}}, {"a":2,"sub":{"x":3}}]);
        let out = n(v.clone());
        assert_eq!(out, v);
    }
}
```

- [ ] **步骤 2：运行测试验证失败**

运行：`cargo test -p gdcli format::normalize::tests -- --nocapture`
预期：`r1_empty_array_becomes_empty_string` 和 `nested_object_recurses` FAIL（其它 PASS，因为占位实现对它们恰好是 no-op）。

- [ ] **步骤 3：实现 R1 变换逻辑**

把 `cli/src/format/normalize.rs` 中 `normalize` 函数的 `Value::Array` 分支替换为：

```rust
        Value::Array(arr) => {
            let arr: Vec<Value> = arr.into_iter().map(normalize).collect();
            // R1：检查整个 array 是否能通过空数组占位扳成 "uniform primitive-only"。
            // 若所有 element 都是 object，且 keys 一致，且 value 全是
            // "primitive 或可降级为 primitive 的复合值"，则把 [] / [single]
            // 改写为字符串占位。
            if let Some(coerced) = try_coerce_with_r1(&arr) {
                Value::Array(coerced)
            } else {
                Value::Array(arr)
            }
        }
```

并在文件末尾（`#[cfg(test)]` 之前）添加辅助函数：

```rust
/// 尝试将 array 中所有 object element 的 value 做 R1 占位变换。
///
/// 触发条件（全部满足）：
/// 1. arr 非空；
/// 2. 每个 element 都是 Object；
/// 3. 所有 object 的 key 集合完全一致；
/// 4. 每个 value 满足：is_primitive(v) || is_empty_array(v) || is_single_primitive_array(v)。
///
/// 变换：`[]` → `Value::String("")`；`[x]` 其中 x 为 primitive → `x` 本身（保留类型）。
fn try_coerce_with_r1(arr: &[Value]) -> Option<Vec<Value>> {
    if arr.is_empty() {
        return None;
    }
    let first = arr.first()?.as_object()?;
    let keys: Vec<&String> = first.keys().collect();

    // 检查所有 element 都是 object，且 keys 一致
    let all_match = arr.iter().all(|v| {
        v.as_object()
            .map(|o| o.len() == keys.len() && keys.iter().all(|k| o.contains_key(k.as_str())))
            .unwrap_or(false)
    });
    if !all_match {
        return None;
    }

    // 检查每个 value 都是 primitive 或可降级
    let all_coercible = arr.iter().all(|v| {
        v.as_object()
            .map(|o| o.values().all(is_primitive_or_coercible))
            .unwrap_or(false)
    });
    if !all_coercible {
        return None;
    }

    // 实际变换
    let coerced: Vec<Value> = arr
        .iter()
        .map(|v| {
            let obj = v.as_object().expect("checked above");
            let new_map: Map<String, Value> = obj
                .iter()
                .map(|(k, val)| (k.clone(), coerce_value(val)))
                .collect();
            Value::Object(new_map)
        })
        .collect();
    Some(coerced)
}

fn is_primitive(v: &Value) -> bool {
    !v.is_object() && !v.is_array()
}

fn is_primitive_or_coercible(v: &Value) -> bool {
    if is_primitive(v) {
        return true;
    }
    if let Value::Array(inner) = v {
        // 空数组 OK；单元素 primitive 数组 OK
        if inner.is_empty() {
            return true;
        }
        if inner.len() == 1 && is_primitive(&inner[0]) {
            return true;
        }
    }
    false
}

fn coerce_value(v: &Value) -> Value {
    match v {
        Value::Array(inner) if inner.is_empty() => Value::String(String::new()),
        Value::Array(inner) if inner.len() == 1 && is_primitive(&inner[0]) => inner[0].clone(),
        other => other.clone(),
    }
}
```

- [ ] **步骤 4：运行测试验证 R1 通过**

运行：`cargo test -p gdcli format::normalize::tests -- --nocapture`
预期：所有 7 个测试 PASS。

> R2 和 R3 在 normalize 层都是 no-op（spec 编码器已经自动处理），R1 是唯一需要主动变换的规则。R4（primitive array inline）也由 toon-format 自动处理。这与设计文档 §4.1-§4.4 一致。

- [ ] **步骤 5：再跑一次集成测试确保没破坏**

运行：`cargo test -p gdcli`
预期：所有测试 PASS（除任务 7 还没改造的旧 exec 测试外）。

- [ ] **步骤 6：Commit**

```bash
git add cli/src/format/normalize.rs
git commit -m "feat(cli): implement R1 empty-array coercion in normalize"
```

---

## 任务 7：改造旧集成测试 + 新增 TOON 形态覆盖

**文件：**
- 修改：`cli/tests/exec_integration.rs`

- [ ] **步骤 1：定位需要改造的旧测试**

运行：`cargo test -p gdcli --test exec_integration 2>&1`

记下所有 FAIL 的测试。预期它们的失败原因都是断言 stdout 是原始 JSON 字符串。

读 `cli/tests/exec_integration.rs` 全文，确定每个 FAIL 测试的位置与断言形式。

- [ ] **步骤 2：对每个失败的旧测试，添加 `--json` 标志**

对每个 FAIL 的测试，把 `args(&["--project", ..., "exec", ...])` 修改为 `args(&["--json", "--project", ..., "exec", ...])`。

这样做的语义：**保留原测试用例的契约**（断言原始 JSON 输出），只是现在需要显式声明走 JSON 通道。

> 如果某个旧测试的断言已经是"包含某 JSON 子串"，且子串恰好在 TOON 输出中也存在（极少见但可能），可以保留不动并加注释说明。

- [ ] **步骤 3：运行确认所有旧测试 + 任务 4 的两个新测试都 PASS**

运行：`cargo test -p gdcli --test exec_integration`
预期：全部 PASS。

- [ ] **步骤 4：添加 TOON 形态覆盖测试**

在 `cli/tests/exec_integration.rs` 末尾追加（如果 `setup_fixture` helper 不存在，复制现有 fixture 搭建代码 inline 到每个测试中）：

```rust
#[test]
fn exec_toon_tabular_uniform_array() {
    use httpmock::prelude::*;
    let server = MockServer::start();
    server.mock(|when, then| {
        when.method(POST).path("/help");
        then.status(200)
            .header("content-type", "application/json")
            .body(r#"{"ok":true,"routes":[{"path":"ping","summary":"健康检查"},{"path":"help","summary":"路由列表"}]}"#);
    });
    let temp = setup_fixture(&server);

    let output = assert_cmd::Command::cargo_bin("gdcli")
        .unwrap()
        .args(&["--project", temp.path().to_str().unwrap(), "exec", "help"])
        .output()
        .unwrap();

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "stderr={}", String::from_utf8_lossy(&output.stderr));
    assert!(stdout.contains("ok: true"), "got: {stdout}");
    assert!(stdout.contains("routes[2|]{path|summary}:"), "expected pipe tabular header, got: {stdout}");
    assert!(stdout.contains("ping|健康检查"), "got: {stdout}");
}

#[test]
fn exec_toon_with_r1_empty_array() {
    use httpmock::prelude::*;
    let server = MockServer::start();
    server.mock(|when, then| {
        when.method(POST).path("/help");
        then.status(200)
            .header("content-type", "application/json")
            .body(r#"{"ok":true,"routes":[{"path":"ping","params":[]},{"path":"help","params":["x"]}]}"#);
    });
    let temp = setup_fixture(&server);

    let output = assert_cmd::Command::cargo_bin("gdcli")
        .unwrap()
        .args(&["--project", temp.path().to_str().unwrap(), "exec", "help"])
        .output()
        .unwrap();

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success());
    assert!(stdout.contains("routes[2|]{path|params}:"), "R1 should coerce to tabular, got: {stdout}");
    assert!(stdout.contains("ping|"), "empty array should become empty cell, got: {stdout}");
    assert!(stdout.contains("help|x"), "got: {stdout}");
}

#[test]
fn exec_toon_4xx_error_renders_in_stderr() {
    use httpmock::prelude::*;
    let server = MockServer::start();
    server.mock(|when, then| {
        when.method(POST).path("/unknown");
        then.status(404)
            .header("content-type", "application/json")
            .body(r#"{"ok":false,"code":"not_found","msg":"route not found: unknown"}"#);
    });
    let temp = setup_fixture(&server);

    let output = assert_cmd::Command::cargo_bin("gdcli")
        .unwrap()
        .args(&["--project", temp.path().to_str().unwrap(), "exec", "unknown"])
        .output()
        .unwrap();

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(output.status.code(), Some(2), "4xx should exit 2; stderr={stderr}");
    assert!(stderr.starts_with("Error (HTTP 404): "), "got: {stderr}");
    assert!(stderr.contains("code: not_found"), "stderr should contain TOON-rendered error, got: {stderr}");
    assert!(stderr.contains("msg:"), "got: {stderr}");
}

#[test]
fn exec_non_json_body_passes_through() {
    use httpmock::prelude::*;
    let server = MockServer::start();
    server.mock(|when, then| {
        when.method(POST).path("/raw");
        then.status(200)
            .header("content-type", "text/plain")
            .body("hello world");
    });
    let temp = setup_fixture(&server);

    let output = assert_cmd::Command::cargo_bin("gdcli")
        .unwrap()
        .args(&["--project", temp.path().to_str().unwrap(), "exec", "raw"])
        .output()
        .unwrap();

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success());
    assert_eq!(stdout.trim_end(), "hello world", "non-JSON body should pass through");
}
```

- [ ] **步骤 5：运行所有新增集成测试**

运行：`cargo test -p gdcli --test exec_integration`
预期：所有测试 PASS。

> 如果 `exec_non_json_body_passes_through` 失败，注意 stdout 末尾换行：默认 TOON 路径会追加 `\n`，但**非 JSON 透传路径不应追加**（应保持与今日 `print!("{}", body)` 一致）。但 `render_exec_body` 对非 JSON 返回 `Cow::Borrowed`，外层 `exec.rs` 的 `if !rendered.ends_with('\n') { println!(); }` 会给它补一个换行——这是预期行为，因为输入 "hello world" 不以 \n 结尾。`trim_end()` 断言能容忍这个换行。

- [ ] **步骤 6：Commit**

```bash
git add cli/tests/exec_integration.rs
git commit -m "test(cli): cover TOON output for exec integration cases"
```

---

## 任务 8：把任务 4 引入的 `let _ = json_mode;` 痕迹和注释清理掉

**文件：**
- 修改：`cli/src/exec.rs`（清理 doc comment + 命名一致性检查）

- [ ] **步骤 1：更新 `cli/src/exec.rs:23-38` 的 doc comment**

read `cli/src/exec.rs` 顶部的函数级 doc comment，确认提到了所有 6 个参数。在 `# Arguments` 段（第 27-35 行附近）末尾添加：

```rust
/// * `json_mode` - true 时原样透传 minified JSON；false 时渲染为 TOON
```

- [ ] **步骤 2：确认任务 3 步骤 1 的 `let _ = json_mode;` 已被任务 4 步骤 3 删除**

运行：`Select-String -Path cli/src/exec.rs -Pattern "let _ = json_mode"`
预期：无输出（如果有，删掉那一行）。

- [ ] **步骤 3：跑 clippy 确认无新增 warning**

运行：`cargo clippy -p gdcli -- -D warnings`
预期：通过，无 warning。

> 如果 clippy 报 `dead_code` 等问题（比如 `format/normalize.rs` 中的辅助函数没被外部调用），检查它们是否确实只在本模块用——是的话保留 `fn` 不带 `pub`，clippy 不会报警；否则按提示修复。

- [ ] **步骤 4：Commit（如有改动）**

```bash
git add cli/src/exec.rs
git commit -m "docs(cli): document json_mode parameter in exec::run"
```

若无改动则跳过此步。

---

## 任务 9：更新 README 与 CHANGELOG

**文件：**
- 修改：`README.md`
- 创建或修改：`CHANGELOG.md`

- [ ] **步骤 1：读 README.md 确定 exec 章节位置**

运行：`Select-String -Path README.md -Pattern "exec" -Context 0,5 | Select-Object -First 30`

记下 exec 命令的描述段落位置。

- [ ] **步骤 2：在 README.md 的 exec 章节添加输出格式说明**

在 exec 用法示例附近插入（具体行号取决于 README 结构）：

````markdown
### 输出格式

`gdcli exec` 默认以 **TOON** 格式输出 HTTP 响应，便于人类终端阅读和 LLM 消费：

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
````

具体插入位置由 README 现有结构决定；如果 README 没有 exec 专门章节，添加一个。

- [ ] **步骤 3：检查 CHANGELOG.md 是否存在**

运行：`Test-Path -LiteralPath CHANGELOG.md`

- [ ] **步骤 4a：若 CHANGELOG.md 不存在，创建一个**

```markdown
# Changelog

## Unreleased

### Breaking Changes
- `gdcli exec` 默认输出格式从原始 minified JSON 改为 **TOON**。脚本场景请添加 `--json` 标志恢复旧行为。

### Features
- `gdcli exec` 支持 TOON 输出，自动根据响应数据结构选择表格/键值/树状形态
- 新增 `cli/src/format/` 模块，对外暴露 `render_exec_body` API
```

- [ ] **步骤 4b：若 CHANGELOG.md 已存在，把上面的条目加到 "Unreleased" 章节顶部**

- [ ] **步骤 5：Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs: announce TOON default output for gdcli exec"
```

---

## 任务 10：最终验证

**文件：** 无（运行验证命令）

- [ ] **步骤 1：跑 workspace 全部测试**

运行：`cargo test --workspace`
预期：所有测试 PASS。

- [ ] **步骤 2：跑 clippy（包含 gdapi）**

运行：`cargo clippy --workspace -- -D warnings`
预期：无 warning。

- [ ] **步骤 3：检查 fmt**

运行：`cargo fmt --check`
预期：无 diff。

> 如果有 diff，运行 `cargo fmt` 修复，然后用 `git add -u && git commit -m "style: cargo fmt"` 提交。

- [ ] **步骤 4：手动 smoke test（如本机有 Godot 项目）**

```bash
# 启动 Godot 编辑器加载 fixture_project（参考 AGENTS.md 流程）
# 然后：
cd tests/fixture_project
cargo run -p gdcli -- exec ping
# 预期输出 TOON 格式：
#   ok: true
#   gdapi_version: 0.2.0

cargo run -p gdcli -- --json exec ping
# 预期输出原始 JSON：
#   {"ok":true,"gdapi_version":"0.2.0"}
```

> 如果 Godot 没运行，会得到 `gdapi not running: ...` 错误。这是预期行为，跳过手动测试即可——集成测试已经覆盖了 mock 路径。

- [ ] **步骤 5：检查 git 历史**

运行：`git log --oneline | Select-Object -First 12`
预期：8-10 个 commit，每个对应一个任务，消息清晰。

- [ ] **步骤 6：最终 commit（如有遗漏改动）**

```bash
git status
```

如有未提交改动，做最终 commit；否则计划完成。

---

## 自检结果

**规格覆盖度**（对照 `docs/superpowers/specs/2026-06-24-exec-toon-output-design.md` §1-§9）：
- ✅ §2 总体架构 → 任务 2-4 覆盖（format 模块 + exec 集成）
- ✅ §3 三种形态映射 → 任务 5（toon.rs 单测）+ 任务 7（集成测试）覆盖
- ✅ §3.4 delimiter=`|`、indent=2 → 任务 2 步骤 3 固化
- ✅ §4.1 R1 → 任务 6
- ✅ §4.2 R2 / §4.3 R3 / §4.4 R4 → 由 toon-format crate 内建处理，任务 6 测试用例验证
- ✅ §4.5 不做的事 → 不做就是不做，无任务
- ✅ §5.1 接口变更 → 任务 3
- ✅ §5.2 stdout/stderr/exit code → 任务 4
- ✅ §5.3 末尾换行 → 任务 4 步骤 3
- ✅ §5.5 兼容性（Break change） → 任务 9
- ✅ §6 模块组织 → 任务 2
- ✅ §6.5 编码器选型 → 任务 1（锁定 toon-format 0.5.0）
- ✅ §6.6 测试组织 → 任务 5/6/7
- ✅ §7 里程碑 → 任务结构对齐

**占位符扫描**：无"TODO"、"待定"、"类似任务 N"、"添加适当的错误处理"等模式。所有代码步骤都给出了完整代码。

**类型一致性**：
- `render_exec_body(body: &str) -> Cow<'_, str>` 在任务 2 定义，任务 4 调用一致
- `normalize(v: Value) -> Value` 在任务 2 占位，任务 6 替换实现，签名一致
- `encode(value: &Value) -> Result<String, String>` 在任务 2 定义，任务 4 调用，任务 5 测试，签名一致
- `EncodeOptions::new().with_delimiter(Delimiter::Pipe).with_spaces(2)` 在任务 2 步骤 3 和任务 1 步骤 3 一致使用

---

## 执行交接

**计划已完成并保存到 `docs/superpowers/plans/2026-06-24-exec-toon-output.md`。**

两种执行方式：

1. **子代理驱动（推荐）** — 每个任务调度一个新的子代理，任务间进行审查，快速迭代
2. **内联执行** — 在当前会话中使用 executing-plans 执行任务，批量执行并设有检查点

选哪种方式？
