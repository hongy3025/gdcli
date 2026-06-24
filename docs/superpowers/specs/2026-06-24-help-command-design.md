# gdcli exec help 命令与 gdapi 自文档机制设计

- **日期**：2026-06-24
- **状态**：Draft（待用户审阅）
- **影响范围**：`gdapi/addon/runtime/`、`gdapi/addon/routes/` 现有 handler 可选改动、`cli/src/exec.rs`、`cli/src/main.rs`

## 1. 背景与目标

gdcli 通过 `gdcli exec <route>` 向运行中的 Godot 项目发送 HTTP 请求调用 gdapi 路由。目前路由数量已达 11 个，缺少统一的命令发现与帮助查询机制：

- 现有内置路由 `routes` 只返回路径名列表，没有任何描述、参数说明、返回值说明。
- route 实现里只有 `##` doc-comment 注释，文档与代码物理分离，无法在运行时被程序化读取。
- 用户/AI 调用方需要翻源码才能了解某个路由的参数与返回值。

### 目标

1. 新增 `gdcli exec help` 命令，列出所有可用路由及简要说明（path、summary、参数列表）。
2. 新增 `gdcli exec help <cmd_path>` 命令，返回指定路由的完整帮助文档（描述、参数详情、返回值说明、示例）。
3. 在 gdapi runtime 中引入自文档机制：每个 route handler 通过重载 `doc()` 方法返回结构化文档对象，由内置 help 路由聚合输出。
4. 自文档机制对存量 route **非破坏性**：未重载 `doc()` 的 route 仍然能正常工作，只是 help 列表中描述为空。

### 非目标

- 不在本次实现中为现有 11 个 route 全部补齐 `doc()` —— 放到后续独立任务。
- CLI 不对 help 输出做人类可读的额外渲染（表格、对齐等），直接打印服务端返回的 JSON；用户可自行通过 `jq` 等工具加工。
- 不引入 OpenAPI/JSON Schema 等外部规范，自定义轻量结构即可。

## 2. 设计概览

```
┌─────────────────────────────────────────────────────────────┐
│  CLI (Rust)                                                 │
│   gdcli exec help [<path>]                                  │
│     └─ exec.rs 特殊处理：拼 body {"path":"<path>"} 或 {}    │
└──────────────────────────┬──────────────────────────────────┘
                           │ POST /help
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  gdapi runtime (GDScript)                                   │
│   router.gd                                                 │
│     ├─ dispatch: key=="help" → BuiltinHelp.handle()         │
│     └─ scan: 注入全部路由（含 ping/routes/help）到 BuiltinHelp│
│   builtin_help.gd                                           │
│     ├─ body 空 → 列举所有 handler.doc().to_summary_dict()   │
│     └─ body.path → 实例化目标 handler，返回 .doc().to_dict()│
└──────────────────────────┬──────────────────────────────────┘
                           │ 调用
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  自文档机制                                                 │
│   route_handler.gd                                          │
│     └─ func doc() -> GdApiRouteDoc  (默认返回空文档)         │
│   route_doc.gd / param_doc.gd (新增)                        │
│     └─ fluent builder + to_dict() / to_summary_dict()       │
└─────────────────────────────────────────────────────────────┘
```

## 3. 自文档机制（gdapi runtime）

### 3.1 新增 `gdapi/addon/runtime/param_doc.gd`

单个参数的文档对象。

```gdscript
## 路由单个参数的文档描述
##
## 由 GdApiRouteDoc.param() 构造，一般不直接实例化。

@tool
class_name GdApiParamDoc
extends RefCounted

## 参数名
var name: String = ""
## 参数类型字符串（"String", "int", "Dictionary", "Array", "bool" 等，开发者自由约定）
var type: String = ""
## 是否必填
var required: bool = false
## 参数描述
var description: String = ""
## 默认值；null 表示无默认值（必填参数也为 null）
var default = null

## 序列化为字典，供 JSON 响应使用
func to_dict() -> Dictionary:
    return {
        "name": name,
        "type": type,
        "required": required,
        "description": description,
        "default": default,
    }
```

### 3.2 新增 `gdapi/addon/runtime/route_doc.gd`

路由级文档对象，提供 fluent builder API。

```gdscript
## 路由帮助文档对象
##
## 通过 GdApiRouteDoc.make("...").desc("...").param(...).returns(...) 链式构造。
## 由 route handler 的 doc() 方法返回，内置 /help 路由调用 to_dict()/to_summary_dict() 序列化。

@tool
class_name GdApiRouteDoc
extends RefCounted

const ParamDoc := preload("res://addons/gdapi/runtime/param_doc.gd")

## 一句话功能描述（出现在列表和详情视图）
var summary: String = ""
## 多行详细说明（仅出现在详情视图）
var description: String = ""
## 参数列表
var params: Array[ParamDoc] = []
## 返回值整体说明
var returns_desc: String = ""
## 返回值字段说明（flat dict，键为字段名，值为类型+说明字符串）
var returns_fields: Dictionary = {}
## 调用示例（JSON 请求体字符串数组）
var examples: Array[String] = []

## 静态工厂：创建一个带 summary 的 RouteDoc
static func make(summary_: String) -> GdApiRouteDoc:
    var d := GdApiRouteDoc.new()
    d.summary = summary_
    return d

## 设置详细描述（fluent）
func desc(text: String) -> GdApiRouteDoc:
    description = text
    return self

## 添加一个参数（fluent）
func param(name: String, type: String, required: bool, description: String, default = null) -> GdApiRouteDoc:
    var p := ParamDoc.new()
    p.name = name
    p.type = type
    p.required = required
    p.description = description
    p.default = default
    params.append(p)
    return self

## 设置返回值描述与字段（fluent）
func returns(desc_: String, fields: Dictionary = {}) -> GdApiRouteDoc:
    returns_desc = desc_
    returns_fields = fields
    return self

## 添加一个 JSON 请求示例（fluent）
func example(json: String) -> GdApiRouteDoc:
    examples.append(json)
    return self

## 完整序列化（详情视图）
func to_dict() -> Dictionary:
    var param_dicts: Array = []
    for p in params:
        param_dicts.append(p.to_dict())
    return {
        "summary": summary,
        "description": description,
        "params": param_dicts,
        "returns": {
            "description": returns_desc,
            "fields": returns_fields,
        },
        "examples": examples,
    }

## 简要序列化（列表视图）
func to_summary_dict() -> Dictionary:
    var param_summary: Array = []
    for p in params:
        param_summary.append({"name": p.name, "required": p.required})
    return {
        "summary": summary,
        "params": param_summary,
    }
```

### 3.3 修改 `gdapi/addon/runtime/route_handler.gd`

加入默认的 `doc()` 实现：

```gdscript
const RouteDoc := preload("res://addons/gdapi/runtime/route_doc.gd")

## 返回该路由的帮助文档
##
## 子类可选重载：未重载时返回 summary 为空的占位文档，路由仍可正常工作，
## 仅在 /help 列表中显示为空描述。
func doc() -> RouteDoc:
    return RouteDoc.make("")
```

### 3.4 自文档使用示例

```gdscript
# routes/editor/scene/save.gd
func doc() -> GdApiRouteDoc:
    return GdApiRouteDoc.make("保存 Godot 场景文件") \
        .desc("支持保存到原路径或另存为新路径，自动创建不存在的目录") \
        .param("scene_path", "String", true, "场景路径，可省略 res:// 前缀") \
        .param("new_path", "String", false, "另存目标路径，留空则覆盖原路径", "") \
        .returns("保存成功后返回路径信息", {
            "ok": "bool, 是否成功",
            "path": "String, 实际保存路径",
        })
```

## 4. /help 路由

### 4.1 新增 `gdapi/addon/runtime/builtin_help.gd`

```gdscript
## 内置帮助路由
##
## POST /help            → 返回所有路由的简要列表
## POST /help {path:"x"} → 返回路由 x 的完整帮助文档

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

# router 在 scan 完成后注入：{ path: handler_script }
var _routes: Dictionary = {}

## 由 router 在扫描完成后调用，传入完整路由表（含 ping/routes/help 等内置项）
func set_routes(routes: Dictionary) -> void:
    _routes = routes

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
    var path: String = req.get_body("path", "")

    if path.is_empty():
        res.json({"ok": true, "routes": _build_list()})
        return

    if not _routes.has(path):
        res.error("route not found: " + path, "not_found", 404)
        return

    var handler = _routes[path].new()
    var detail: Dictionary = handler.doc().to_dict()
    detail["path"] = path
    res.json({"ok": true, "doc": detail})

func _build_list() -> Array:
    var result: Array = []
    var keys: Array = _routes.keys()
    keys.sort()
    for key in keys:
        var handler = _routes[key].new()
        var summary: Dictionary = handler.doc().to_summary_dict()
        summary["path"] = key
        result.append(summary)
    return result

## 自身的文档
func doc() -> GdApiRouteDoc:
    return GdApiRouteDoc.make("列出可用路由或查询单个路由的帮助文档") \
        .desc("不带 path 参数返回所有路由的简要列表；带 path 参数返回该路由的完整文档") \
        .param("path", "String", false, "要查询的路由路径，留空返回全部路由列表", "") \
        .returns("列表模式返回 routes 数组；详情模式返回 doc 对象", {
            "ok": "bool",
            "routes": "Array, 仅列表模式存在",
            "doc": "Dictionary, 仅详情模式存在",
        })
```

### 4.2 修改 `gdapi/addon/runtime/router.gd`

```gdscript
const BuiltinHelp := preload("res://addons/gdapi/runtime/builtin_help.gd")

var _builtin_help_handler: BuiltinHelp

func scan(root_dir: String) -> void:
    _routes.clear()
    _routes["ping"] = BuiltinPing
    _builtin_routes_handler = BuiltinRoutes.new()
    _builtin_help_handler = BuiltinHelp.new()
    _scan_dir(root_dir + "/editor", "")
    _scan_dir(root_dir + "/shared", "")

    var names: Array = _routes.keys()
    names.append("routes")
    names.append("help")
    names.sort()
    _builtin_routes_handler.set_route_names(names)

    # 把所有路由（含内置）注入到 help handler
    var all_routes: Dictionary = _routes.duplicate()
    all_routes["routes"] = BuiltinRoutes
    all_routes["help"] = BuiltinHelp
    _builtin_help_handler.set_routes(all_routes)

func count() -> int:
    # _routes 已含 ping，再加 routes + help 两个内置
    return _routes.size() + 2

func dispatch(req_dict: Dictionary, server) -> void:
    # ... 前置校验与 method 判断不变 ...

    if key == "routes":
        # ... 不变 ...
        return

    if key == "help":
        var req := GdApiRequest.new(req_dict)
        var res := GdApiResponse.new(server, id)
        _builtin_help_handler.handle(req, res)
        return

    # ... 其余不变 ...
```

### 4.3 内置 ping/routes 的 doc() 重载

为示范并保证内置路由也出现在列表中带有描述，`builtin_ping.gd` 和 `builtin_routes.gd` 分别重载 `doc()`：

```gdscript
# builtin_ping.gd
func doc() -> GdApiRouteDoc:
    return GdApiRouteDoc.make("健康检查，返回 pong") \
        .returns("固定响应", {"ok": "bool", "msg": "String, 固定为 'pong'"})

# builtin_routes.gd
func doc() -> GdApiRouteDoc:
    return GdApiRouteDoc.make("列出所有已注册的路由名称") \
        .returns("路由名数组", {"ok": "bool", "routes": "Array[String]"})
```

### 4.4 响应格式示例

**`POST /help`**（列表）：

```json
{
  "ok": true,
  "routes": [
    {
      "path": "editor/scene/save",
      "summary": "保存 Godot 场景文件",
      "params": [
        {"name": "scene_path", "required": true},
        {"name": "new_path", "required": false}
      ]
    },
    {
      "path": "ping",
      "summary": "健康检查，返回 pong",
      "params": []
    }
  ]
}
```

**`POST /help` body `{"path":"editor/scene/save"}`**（详情）：

```json
{
  "ok": true,
  "doc": {
    "path": "editor/scene/save",
    "summary": "保存 Godot 场景文件",
    "description": "支持保存到原路径或另存为新路径，自动创建不存在的目录",
    "params": [
      {"name": "scene_path", "type": "String", "required": true, "default": null,
       "description": "场景路径，可省略 res:// 前缀"},
      {"name": "new_path", "type": "String", "required": false, "default": "",
       "description": "另存目标路径，留空则覆盖原路径"}
    ],
    "returns": {
      "description": "保存成功后返回路径信息",
      "fields": {"ok": "bool, 是否成功", "path": "String, 实际保存路径"}
    },
    "examples": []
  }
}
```

### 4.5 错误处理

- `path` 不存在于路由表 → HTTP 404，错误体 `{"ok": false, "code": "not_found", "msg": "route not found: <path>"}`，CLI 退出码 2。
- handler 实例化失败（罕见，例如脚本编译错误）→ 沿用 router 现有错误处理；不在本设计范围内特别处理。
- 路由未重载 `doc()` → 返回默认空文档（summary 为空），不视为错误。

## 5. CLI 端

### 5.1 修改 `cli/src/main.rs` 的 `Cmd::Exec`

```rust
Exec {
    /// gdapi 路由命令名
    command: String,
    /// 位置参数。仅 help 命令使用：作为查询的路由路径
    args: Vec<String>,
    /// 请求 JSON 数据（字面 JSON、@file 或 - 表示 stdin）
    #[arg(long)]
    data: Option<String>,
    /// HTTP 请求超时秒数
    #[arg(long, default_value_t = 30)]
    timeout: u64,
},
```

分发：

```rust
Cmd::Exec { ref command, ref args, ref data, timeout } => {
    let project_root = project::resolve_project_root(project)
        .map_err(|e| anyhow::anyhow!(e))?;
    let code = exec::run(&project_root, command, args, data.as_deref(), timeout)?;
    std::process::exit(code);
}
```

### 5.2 修改 `cli/src/exec.rs`

`run()` 签名增加 `args: &[String]`。在原本计算 `body_text` 的位置加入分支：

```rust
let body_text: String = if command == "help" {
    if data.is_some() {
        eprintln!("'help' command does not accept --data; use positional path argument");
        return Ok(2);
    }
    match args.first() {
        Some(path) => serde_json::json!({ "path": path }).to_string(),
        None => "{}".to_string(),
    }
} else {
    if !args.is_empty() {
        eprintln!("unexpected positional arguments for '{}': {:?}", command, args);
        return Ok(2);
    }
    match resolve_data(data)? {
        Some(t) => t,
        None => "{}".to_string(),
    }
};
```

后续 URL 构造、HTTP 请求、响应处理、退出码映射保持不变。

### 5.3 行为表

| 用户输入 | CLI 行为 |
|---|---|
| `gdcli exec help` | POST `/help` body `{}`，stdout 打印列表 JSON，退出码 0 |
| `gdcli exec help editor/scene/save` | POST `/help` body `{"path":"editor/scene/save"}`，stdout 打印详情 JSON |
| `gdcli exec help foo/bar`（不存在） | 服务端 404，stderr 打印错误，退出码 2 |
| `gdcli exec help --data '{}'` | 退出码 2，stderr：help 不接受 --data |
| `gdcli exec ping extra_arg` | 退出码 2，stderr：unexpected positional arguments |
| `gdcli exec ping`、`gdcli exec foo --data '{...}'` | 行为完全不变 |

### 5.4 输出策略

CLI **完全不做渲染**，直接 `print!` 服务端 JSON。`--json` 标志在 exec 子命令上目前没有差异化语义，保持现状。用户可后续用 `jq` 加工。

## 6. 文件变更总览

**新增**

- `gdapi/addon/runtime/route_doc.gd` (+ `.gd.uid`)
- `gdapi/addon/runtime/param_doc.gd` (+ `.gd.uid`)
- `gdapi/addon/runtime/builtin_help.gd` (+ `.gd.uid`)

**修改**

- `gdapi/addon/runtime/route_handler.gd`：增加默认 `doc()` 实现
- `gdapi/addon/runtime/router.gd`：注册 `/help` 路由、注入路由表给 BuiltinHelp、`count()` 调整
- `gdapi/addon/runtime/builtin_ping.gd`：重载 `doc()`
- `gdapi/addon/runtime/builtin_routes.gd`：重载 `doc()`（`"help"` 字符串由 router.gd 加入 names 列表，无需在本文件改）
- `cli/src/main.rs`：`Cmd::Exec` 增加 `args: Vec<String>`，调用处透传
- `cli/src/exec.rs`：`run()` 接收 `args`，help 命令特殊处理
- `cli/tests/exec_integration.rs`：新增 help 命令集成测试

**不在本次实现**

- 现有 11 个 route 重载 `doc()`：另起任务逐步补齐。本设计保证未实现时也能工作。

## 7. 测试策略

### 7.1 GDScript 端

在 `tests/fixture_project/tests/` 中加入或扩展测试：

- `GdApiRouteDoc.make().desc(...).param(...)` 返回的 `to_dict()` 包含所有字段且 fluent 链式正确。
- `to_summary_dict()` 只含 `summary` 与 `params: [{name, required}]`。
- `GdApiParamDoc.to_dict()` 包含全部 5 个字段，`default = null` 正确序列化。

集成测试（依赖运行中的 Godot，可选）：

- POST `/help` 返回 `routes` 数组，且包含 `help` 自身。
- POST `/help` body `{"path":"ping"}` 返回 ping 的详情 doc。
- POST `/help` body `{"path":"nonexistent"}` 返回 404。

### 7.2 CLI 端

`cli/src/exec.rs` 单元测试：

- 抽出 body 构造逻辑（可考虑拆为独立函数 `build_body(command, args, data)` 便于测试），覆盖：
  - `help` + 无参数 → `{}`
  - `help` + 一个路径 → `{"path":"editor/scene/save"}`
  - `help` + `--data` → 错误
  - 非 help + 额外位置参数 → 错误
  - 非 help + `--data` → 走 `resolve_data`

`cli/tests/exec_integration.rs` 集成测试（沿用现有 mock 风格）：

- 启动 mock HTTP server 监听 `/help`，验证 CLI 透传 stdin/stdout、退出码。

## 8. 兼容性与风险

- **存量 route 不受影响**：未重载 `doc()` 时 `route_handler.gd` 提供空文档实现，handler 正常工作，help 列表中显示为空 summary。
- **路由表注入时机**：BuiltinHelp 依赖 router scan 完成后注入完整路由表。如果将来动态增删路由，需要重新调用 `set_routes()`。当前 router 没有动态变更需求，保持简单。
- **handler 反复实例化开销**：`/help` 列表会为每个路由 `new()` 一个 handler 实例调 `doc()`。所有现有 handler 都是 RefCounted 且 `_init` 无副作用，开销可忽略；新增 route 时应保持此约定（不要在 `_init` 中执行 IO 或耗时操作）。
- **CLI 位置参数引入**：`args: Vec<String>` 对非 help 命令默认要求为空，杜绝静默忽略。现有调用方式 `gdcli exec ping` / `gdcli exec foo --data '...'` 行为完全不变。
- **JSON 注入安全**：CLI 构造 body 时使用 `serde_json::json!` 而非字符串拼接，避免 path 中含引号导致的注入问题。

## 9. 实施顺序建议（供 plan 使用）

1. gdapi runtime：新增 `param_doc.gd` + `route_doc.gd` + 修改 `route_handler.gd` 默认实现，加单元测试。
2. gdapi runtime：新增 `builtin_help.gd` + 修改 `router.gd` 注册 `/help`，加内置路由 `doc()` 重载。
3. CLI：修改 `main.rs` + `exec.rs` 增加 help 处理，抽 `build_body` 便于单测。
4. 集成测试：CLI 端 mock 测试 + GDScript 端可选集成测试。
5. 手工 e2e：在真实 fixture 项目上跑 `gdcli exec help` 和 `gdcli exec help ping` 验证。
