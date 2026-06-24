# gdcli exec 默认 TOON 输出 — 设计规格

- **日期**：2026-06-24
- **状态**：Working Draft
- **作用域**：`gdcli exec` 子命令的输出层
- **相关参考**：
  - TOON Spec v3.0：`D:\AI\stock-ai-studio\tradelab\stocks\docs\toon-spec.md`
  - Python 业务封装：`D:\AI\stock-ai-studio\tradelab\stocks\src\base\toon.py`
  - 实际样例：`D:\AI\stock-ai-studio\tradelab.w1\stocks\.data\tests\integration_20260530_223443.toon`

---

## 1. 背景与目标

### 1.1 现状

- `gdcli exec <route>` 当前实现位于 `cli/src/exec.rs:39-111`
- 输出方式：`print!("{}", body)`，**原样透传** gdapi HTTP 响应体（GDScript `JSON.stringify` 产生的单行 minified JSON）
- 全局 `--json` 标志定义在 `cli/src/main.rs:62-64`，但 **exec 分支不读取该标志**（参见 `cli/src/main.rs:288-293`）

### 1.2 目标

1. `gdcli exec` 默认以 **TOON 格式**输出，便于人类终端阅读和 LLM 消费
2. 提供 `--json` 标志以保留旧的 minified JSON 输出（脚本兼容）
3. 设计一种"智能机制"，根据 JSON 数据特征自动选择 TOON 的三种渲染形态（表格 / KV / 树状），无需用户干预

### 1.3 非目标

- 不重构 LSP 子命令的格式化逻辑（保留 `cli/src/commands/lsp.rs` 现有的 `format_*` 函数）
- 不增加 yaml / csv 等其它输出格式
- 不修改 gdapi addon 的响应内容或协议

---

## 2. 总体架构

```
gdcli exec <route> [args...] [--json]
       │
       ▼
┌──────────────────────────┐
│  HTTP request to gdapi   │  (与现状一致)
└──────────────┬───────────┘
               ▼
        ┌──────────────┐
        │ resp body    │  (单行 minified JSON 或非 JSON)
        └──────┬───────┘
               │
        ┌──────▼──────────────┐
        │  cli.json == true ? │
        └──────┬──────────────┘
       是      │      否
   ┌───────────┘────────┐
   ▼                    ▼
原样透传        ┌─────────────────────────────────────┐
（同现状）      │  format::render_exec_body(body)      │
                │   1. serde_json::from_str            │
                │      失败 → 原样透传                  │
                │   2. normalize(value)  ★ R1/R2/R3/R4 │
                │   3. toon::encode(value)             │
                │      失败 → 原样透传                  │
                └──────────────┬──────────────────────┘
                               ▼
                          print!(rendered)
                          + 末尾自动追加 \n
```

**改动边界**：
- 只改 `cli/src/exec.rs:96-104`（输出环节）+ `cli/src/main.rs:288-293`（透传 `cli.json`）
- HTTP 层、退出码映射（`map_status_to_exit`）、stderr 错误前缀、`--data` 处理、`build_body` 等全部不动
- 新增 `cli/src/format/` 模块，对外只暴露 `render_exec_body()` 单 API

---

## 3. TOON 渲染形态映射

TOON spec v3.0 内建三种自动选型规则，对应三种数据形态：

### 3.1 形态 A — KV（缩进对象，spec §8）

**触发条件**：根是 object，叶子全是 primitive 或可继续缩进的嵌套 object。

输入：
```json
{"ok":true,"gdapi_version":"0.2.0"}
```
输出：
```
ok: true
gdapi_version: 0.2.0
```

### 3.2 形态 B — 表格（uniform tabular，spec §9.3）

**触发条件**：array 中每个 element 都是 object，keys 完全一致，所有 value 都是 primitive（或在 R1 规则下等效为 primitive）。

输入：
```json
{"ok":true,"routes":[
  {"path":"ping","summary":"健康检查"},
  {"path":"editor/project/run","summary":"运行场景"}
]}
```
输出：
```
ok: true
routes[2|]{path|summary}:
  ping|健康检查
  editor/project/run|运行场景
```

### 3.3 形态 C — 树状 / expanded list（spec §9.4）

**触发条件**：array 非 uniform，或 element 内含嵌套 object/array。

输入：
```json
{"ok":true,"routes":[
  {"path":"ping","summary":"健康检查","params":[]},
  {"path":"help","summary":"路由列表","params":[{"name":"path","type":"string"}]}
]}
```
输出（裸 spec）：
```
ok: true
routes[2|]:
  - path: ping
    summary: 健康检查
    params[0|]:
  - path: help
    summary: 路由列表
    params[1|]{name|type}:
      string|name
```

### 3.4 编码器选项

| 选项 | 取值 | 理由 |
|---|---|---|
| `delimiter` | `\|`（管道符） | 与 toon.py 业务封装一致；CJK / URL / 路径中很少出现；终端视觉对齐好 |
| `indent` | `2` spaces | spec 默认；与 toon.py 一致 |
| `strict` | 不适用（仅编码方向） | — |
| key folding | `"off"` | 保留原始字段名，避免与 gdapi 路由路径风格混淆 |

---

## 4. 通用 tabular 增强规则（启发式预处理）

裸 TOON spec 的 tabular 触发条件较严格，对部分 gdapi 响应不够友好。本节定义在编码前对 `serde_json::Value` 做的变换，使更多数据落入紧凑的 tabular 形态。

### 4.1 R1：空数组 / null 不破坏 uniform 判定

**问题**：spec §9.3 要求 value 全为 primitive。`"params":[]` 会让整个数组退化为 expanded list。

**变换**：判定 uniform 表格时，把 `[]` 和 `null` 视为"等效 primitive"占位；编码时该 cell 输出为空 token（`||` 之间留空）。

**示例**：
```json
[{"path":"ping","params":[]}, {"path":"help","params":["x"]}]
```
变换后渲染：
```
[2|]{path|params}:
  ping|
  help|x
```

**有损性**：单元素数组 `["x"]` 与字符串 `"x"` 在 round-trip 时无法区分。**显式接受该有损性**，原因：目标场景是终端展示 + LLM 消费，而非 round-trip 序列化。

### 4.2 R2：`[{key, value}, ...]` 形态识别为 KV 表

**问题**：gdapi 有些响应把"字典"序列化成 `[{"item":..., "value":...}]`，spec §9.3 会自动按 2 列表格编码，本规则用来**保证**这种触发稳定（即使 N=1 也走 tabular，且字段名不丢失）。

**触发条件**：array 的所有 element 都是 2-key object，且：
- 第一个 key ∈ `{name, key, item, field}`
- 第二个 key ∈ `{value, val}`

**示例**：
```json
{"fields":[{"item":"代码","value":"600519"},{"item":"最新价","value":"1326.0"}]}
```
渲染：
```
fields[2|]{item|value}:
  代码|600519
  最新价|1326.0
```

### 4.3 R3：单元素 array of object 也走 tabular

**变换**：只要满足 uniform + primitive-only（或 R1 扩展后的"等效 primitive"），无论 N 多少，统一走 tabular（不降级为 expanded list）。

### 4.4 R4：纯 primitive array 走 inline

按 spec §9.1 默认行为。例如 `["a","b","c"]` → `[3|]: a|b|c`。需在编码器调研时验证候选实现的默认行为是否符合此规则；若不符合，由 `format::toon` 包装层修正。

### 4.5 不做的事情（明确范围）

- ❌ 不剥 `ok:true` / `ok:false` 外壳，gdapi 协议的顶层契约对调用方仍然可见
- ❌ 不强行扁平化含嵌套 object 的 array
- ❌ 不做字段重排序（保留 JSON encounter order，符合 spec §2）
- ❌ 不做数值精度调整（spec §2 的 canonical form 交给编码器）
- ❌ 不识别"半结构化日志"等更复杂的形态——它们若 uniform 已被 R3 覆盖

### 4.6 应用顺序

递归后序遍历 `serde_json::Value`：

```rust
fn normalize(v: Value) -> Value {
    match v {
        Value::Array(arr) => {
            let arr: Vec<Value> = arr.into_iter().map(normalize).collect();
            // 尝试将整个 array 强制扳成 tabular 表示
            // 内部依次：R3 (严格 uniform) → R1 (含空数组占位) → R2 (KV 形态)
            // 都不命中 → 保持 array 原样，由编码器走 expanded list
            try_coerce_to_tabular(&arr).unwrap_or(Value::Array(arr))
        }
        Value::Object(map) => Value::Object(
            map.into_iter().map(|(k, v)| (k, normalize(v))).collect()
        ),
        primitive => primitive,
    }
}
```

---

## 5. CLI 接口与行为契约

### 5.1 接口变更

```
gdcli [--json] [--project <path>] exec <command> [args...] [--data ...] [--timeout N]
```

| 标志 | 当前 | 改后 |
|---|---|---|
| 无 `--json` | 原样透传 minified JSON | **TOON 渲染**（默认） |
| `--json` | 对 exec 分支无效（被忽略） | 原样透传 minified JSON（即旧默认） |

### 5.2 stdout / stderr / 退出码

| 场景 | stdout | stderr | exit code |
|---|---|---|---|
| 2xx 成功，`--json` | 原 body | — | 0 |
| 2xx 成功，默认（TOON） | TOON 字符串 + `\n` | — | 0 |
| 2xx 成功但 body 非合法 JSON | 原 body | — | 0 |
| 4xx 客户端错误 | — | `Error (HTTP 4xx): <TOON 或原 body>` | 2 |
| 5xx 服务端错误 | — | `Error (HTTP 5xx): <TOON 或原 body>` | 1 |
| 4xx/5xx 但 body 非 JSON | — | `Error (HTTP xxx): <原 body>` | 2/1 |
| 网络/超时 | — | `network error: ...` | 3 |
| `.godot/gdapi.json` 缺失 | — | `gdapi not running: ...` | 3 |
| 预检失败（`--data` 非 JSON 等） | — | 原文 | 2 |

错误响应也尝试 TOON 渲染：4xx/5xx 的 body 若能 parse 为 JSON 则用 TOON 格式化后写入 stderr；prefix `Error (HTTP xxx):` 之后允许跟换行 + TOON 多行块。无法 parse 则原样透传（与今日完全一致）。

### 5.3 行尾约定

| 形态 | 末尾换行 |
|---|---|
| 默认 TOON 输出 | **自动追加一个 `\n`**（CLI 层包装） |
| `--json` 原样透传 | 与今日一致：`print!`，body 有啥就啥 |

> 说明：spec §12 要求"encoders MUST NOT emit trailing newline"，这是面向 TOON 文档作为序列化产物的要求。我们的场景是 CLI 终端输出，按 POSIX 习惯 stdout 最后一行应以 `\n` 结尾。**编码器输出无尾换，CLI 包装时追加**，两者职责分离。

### 5.4 不变的部分

`--data @file` / stdin / `help` 子模式、`build_body`、`resolve_data`、`BuildBodyOutcome` 全部不动。预检逻辑（`cli/src/exec.rs:60-70, 150-175`）保持原样。

### 5.5 兼容性

| 影响面 | 处理 |
|---|---|
| 依赖原 minified JSON 输出的脚本 | **Break change**。CHANGELOG 与 README 必须显式说明：脚本场景需加 `--json` |
| 集成测试 `cli/tests/exec_integration.rs` | 改造：默认断言走 TOON，新增 `--json` 路径断言保留原 JSON |
| 文档 `README.md` | exec 章节说明默认输出格式 + `--json` 的作用 |

---

## 6. 模块组织

### 6.1 文件清单

```
cli/src/
├── main.rs                    [改] exec 分支透传 cli.json 进 exec::run
├── exec.rs                    [改] 签名 +json_mode；输出环节调用 format
└── format/                    [新]
    ├── mod.rs                 [新] 对外只暴露 render_exec_body()
    ├── normalize.rs           [新] R1/R2/R3/R4 的 serde_json::Value 变换
    └── toon.rs                [新] 调用 TOON 编码器（或自实现兜底）
```

### 6.2 公开 API

```rust
// cli/src/format/mod.rs
use std::borrow::Cow;

pub fn render_exec_body(body: &str) -> Cow<'_, str> {
    match serde_json::from_str::<serde_json::Value>(body) {
        Ok(value) => {
            let normalized = normalize::normalize(value);
            match toon::encode(&normalized) {
                Ok(s) => Cow::Owned(s),
                Err(_) => Cow::Borrowed(body),   // 编码失败 → 透传
            }
        }
        Err(_) => Cow::Borrowed(body),           // 非 JSON → 透传
    }
}
```

**为什么用 `Cow<'_, str>`**：透传时零拷贝、零分配；TOON 渲染时新分配 String，调用方无需感知。

### 6.3 `exec.rs` 改动点

```rust
// 签名
pub fn run(
    project: &Path,
    command: &str,
    args: &[String],
    data: Option<&str>,
    timeout_secs: u64,
    json_mode: bool,                // ← 新增
) -> Result<i32>

// 成功输出（原 cli/src/exec.rs:96-99）
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

// 错误输出（原 cli/src/exec.rs:100-104）
let body = read_body(r)?;
let rendered: Cow<'_, str> = if json_mode {
    Cow::Borrowed(body.as_str())
} else {
    format::render_exec_body(&body)
};
eprintln!("Error (HTTP {}): {}", code, rendered.trim_end());
```

### 6.4 `main.rs` 改动点

```rust
// cli/src/main.rs:288-293
Cmd::Exec { ref command, ref args, ref data, timeout } => {
    let project_root = project::resolve_project_root(project)
        .map_err(|e| anyhow::anyhow!(e))?;
    let code = exec::run(
        &project_root, command, args, data.as_deref(), timeout,
        cli.json,                    // ← 透传全局 --json
    )?;
    std::process::exit(code);
}
```

### 6.5 TOON 编码器依赖策略

在实现阶段先做调研：

1. `cargo search toon` / crates.io 查找候选；评估标准：
   - 实现 TOON spec v3.x（不是 v2.x 早期实现）
   - 支持 `delimiter='|'`
   - 提供 `encode(&serde_json::Value, opts)` 风格 API
   - 至少有基本下载量或最近 6 个月内的更新
2. **找到合适 crate** → `cli/src/format/toon.rs` 是 10-30 行薄包装
3. **找不到** → `cli/src/format/toon.rs` 实现 spec 最小子集（预估 300-500 行），覆盖：
   - primitives 引号规则（§7.2）
   - object 缩进输出（§8）
   - 数组三个分支：inline / tabular / expanded list（§9）
   - canonical number form（§2）
   - 不实现：key folding、path expansion、strict mode 验证

### 6.6 测试组织

```
cli/tests/
└── exec_integration.rs        [改] 默认断言走 TOON 形态；新增 --json 路径
cli/src/format/
├── normalize.rs               #[cfg(test)] mod，覆盖 R1/R2/R3/R4 每条规则
└── toon.rs                    #[cfg(test)] mod，用 gdapi 实际响应做 snapshot
```

**Snapshot 测试用例**：

| Case | 输入特征 | 预期形态 |
|---|---|---|
| `ping_success` | `{"ok":true,"gdapi_version":"0.2.0"}` | 形态 A（KV） |
| `help_routes` | `{"ok":true,"routes":[...含空数组...]}` | 形态 B（tabular，R1 命中） |
| `nested_object` | 深嵌套响应 | 形态 C（expanded list） |
| `error_4xx` | `{"ok":false,"code":"not_found","msg":"..."}` | 形态 A，走 stderr |
| `non_json_body` | `"raw text"` | 透传（无变换） |
| `empty_array` | `{"items":[]}` | `items[0\|]:` |
| `kv_array` | `{"fields":[{"item":"代码","value":"600519"}]}` | 形态 B（R2 命中） |

---

## 7. 实现里程碑

实施时拆分为以下可独立验证的里程碑（详细顺序由后续 plan 文档定义）：

1. **M1**：新增 `cli/src/format/` 骨架 + `render_exec_body` API，编码器返回 stub 占位字符串，跑通端到端调用链
2. **M2**：完成 TOON 编码器（依赖调研后决定 crate 或自实现），覆盖 spec 三种形态
3. **M3**：实现 `normalize` 模块的 R1/R2/R3/R4 启发式规则 + 单元测试
4. **M4**：更新集成测试、CHANGELOG、README
5. **M5**：手动 e2e 验证（运行 `scripts/e2e-ping.ps1` 类脚本）

---

## 8. 风险与权衡

| 风险 | 缓解 |
|---|---|
| TOON crate 不存在或质量差 | 自实现最小子集兜底，spec §8/§9 子集逻辑明确 |
| R1 有损变换造成误解 | 文档显式说明；脚本场景用 `--json` 规避 |
| Break change 影响存量用户 | README + CHANGELOG 显式提示，提供一键迁移方案（脚本加 `--json`） |
| TOON spec v3.0 仍是 Working Draft | 锁定本设计针对的 spec 修订版本，未来 spec 演进通过 patch release 跟进 |
| 大响应 body 性能 | 编码 + normalize 都是 O(N) 线性；body 上限 16MB（`cli/src/exec.rs:220`）不变 |

---

## 9. 决策摘要

| 决策 | 取值 |
|---|---|
| 默认输出格式 | TOON |
| 切回 JSON 的方式 | 复用全局 `--json` |
| TOON delimiter | `\|` |
| TOON indent | 2 spaces |
| 智能检测策略 | TOON spec 自动选型 + 通用 tabular 增强 |
| 编码器实现 | 优先 crate，自实现兜底 |
| 错误响应处理 | 尝试 TOON 渲染，parse 失败原样透传 |
| 末尾换行 | CLI 层自动追加 |
| 模块组织 | 新增 `cli/src/format/`，对外单 API `render_exec_body` |
| LSP 命令复用 | 本轮不动，未来可扩展 |
