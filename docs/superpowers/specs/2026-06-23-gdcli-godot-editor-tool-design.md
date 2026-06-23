# gdcli 通用 Godot 编辑器操作工具 — 设计规格

- **日期**：2026-06-23
- **状态**：已批准（待实现）
- **版本**：0.2.0（破坏性变更）

## 1. 背景与目标

现有 `gdcli` 是 Godot 内置 LSP server 的纯查询客户端（rename、references、definition 等）。本次将其扩展为**通用的 Godot 编辑器操作工具**，可向一个正在运行的 Godot 编辑器实例发送命令完成场景创建、节点操作、项目运行控制等任务。

**核心目标**

1. 新增 `gdcli exec` 子命令，模拟 curl 风格向编辑器内 HTTP API 发送命令。
2. 新增 `gdcli install` 子命令，把一个名为 **gdapi** 的 Godot addon 一键安装到目标项目。
3. 完整迁移 [godot-mcp](https://github.com/Coding-Solo/godot-mcp) 的命令能力（除 `list_projects`、`launch_editor` 两个语义不符的命令）。
4. 解决多 Godot 实例并存时 `gdcli` 如何找到特定实例的 LSP 端口的问题。
5. 现有所有 LSP 子命令降级到 `gdcli lsp <subcommand>` 命名空间。

**非目标（明确不做）**

- LSP 协议本身的变更
- 迁移 godot-mcp 的 `list_projects`、`launch_editor`
- 多 Godot 实例的 LSP 端口自动重映射（用 `--project` 指定即可解决）
- play 进程内启动 gdapi server
- 动态路由参数段（架构预留，本次只做静态路径）
- HTTP keep-alive、HTTPS、认证
- 路由脚本热重载
- GDScript 单元测试框架集成
- CI 内的 Godot 端到端自动化

## 2. 总体架构

```
┌─────────────────────────────────────────────────────────────────┐
│ Godot Editor Process (per project)                              │
│                                                                 │
│  addons/gdapi/  (EditorPlugin, @tool)                           │
│                                                                 │
│  GDExtension (Rust, libgdapi.{dll,dylib,so})                    │
│    tokio HTTP/1.1 server                                        │
│    - bind 7890+ (probe up to 64 ports)                          │
│    - parse request via httparse                                 │
│    - push to in-queue, await oneshot response                   │
│    - write HTTP response, close connection                      │
│             ▲ poll_request / send_response                      │
│             ▼                                                   │
│  GDScript Layer                                                 │
│    plugin.gd (EditorPlugin)                                     │
│      _enter_tree:  server.start(), write .godot/gdapi.json      │
│      _process:     drain in-queue, dispatch via router          │
│      _exit_tree:   server.stop(), delete .godot/gdapi.json      │
│    runtime/router.gd                                            │
│      scan routes/{editor,shared}/**/*.gd                        │
│      match (method, path) → handler.handle(params)              │
│    routes/editor/...   routes/shared/...                        │
│                                                                 │
│  .godot/gdapi.json  ← {"http_port":..., "lsp_port":...,         │
│                        "pid":..., "started_at":...,             │
│                        "gdapi_version":"0.1.0"}                 │
└─────────────────────────────────────────────────────────────────┘
                            ▲
                            │ HTTP
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ gdcli (Rust binary)                                             │
│                                                                 │
│   gdcli install [--project <dir>] [--force] [--no-enable]       │
│   gdcli exec <cmd> [--data <json>] [--timeout <secs>]           │
│   gdcli status                                                  │
│   gdcli lsp <subcommand> ...                                    │
└─────────────────────────────────────────────────────────────────┘
```

**核心架构约束**

1. **Rust 层极薄**：只做 HTTP 协议解析 + 跨线程队列，无业务逻辑、无 JSON 解析、无路由匹配。
2. **GDScript 完全主控**：start/stop server、poll、route、handle 全在 GDScript。
3. **`.godot/gdapi.json` 是唯一发现入口**：同时承载 http_port 和 lsp_port，gdcli 通过 `--project` 解析的项目根来定位它。
4. **GDScript 主线程隔离**：所有业务逻辑在 Godot 主线程执行（`_process` 中 poll），HTTP server 在后台 tokio runtime 里跑，永不阻塞 Godot。
5. **绝对监听本地**：HTTP server 固定绑定 `127.0.0.1`，从不监听外部接口。

## 3. 仓库结构

```
gdcli/                          # workspace 根
  Cargo.toml                    # workspace 定义；包含 [workspace.package] version
  cli/                          # gdcli 可执行（现有 src/ 迁入此处）
    Cargo.toml
    src/
      main.rs                   # 命令分发
      install.rs                # install 子命令
      exec.rs                   # exec 子命令
      status.rs                 # status 子命令
      lsp/                      # 现有 LSP 子命令归类
        mod.rs
        client.rs
        transport.rs
        types.rs
        symbol_path.rs
      project.rs                # 项目根检测（向上查找 project.godot）
      gdapi_meta.rs             # .godot/gdapi.json 读写
  gdapi/
    rust/                       # Rust GDExtension 工程
      Cargo.toml
      src/
        lib.rs                  # GdApiServer GodotClass 定义
        server.rs               # tokio runtime + accept loop
        http.rs                 # httparse 封装
        queue.rs                # PendingRequest / 响应路由
    addon/                      # install 时拷贝到 <project>/addons/gdapi/ 的模板
      plugin.cfg
      plugin.gd
      gdapi.gdextension
      runtime/
        router.gd
        route_handler.gd        # 路由处理器基类
      routes/
        editor/
          scene/create.gd
          scene/add_node.gd
          scene/load_sprite.gd
          scene/save.gd
          scene/export_mesh_library.gd
          project/run.gd
          project/stop.gd
          project/debug_output.gd
          uid/update_all.gd
        shared/
          godot/version.gd
          project/info.gd
          uid/get.gd
          _ping.gd              # 以 _ 开头但 router 特殊处理为内置 /ping
          _routes.gd            # 同上，/routes
      bin/                      # 全平台预编译产物（CI 填充）
        windows/gdapi.dll
        macos/libgdapi.dylib
        linux/libgdapi.so
  docs/
    superpowers/specs/2026-06-23-gdcli-godot-editor-tool-design.md
    exec-commands.md            # 每个路由的 schema
  scripts/
    e2e.sh                      # 本地端到端测试脚本
  README.md
```

**版本号统一**：gdcli 与 gdapi 共用 workspace 顶层的 `[workspace.package] version`。

## 4. Rust GDExtension（gdapi 核心）

### 4.1 Cargo 配置

```toml
[package]
name = "gdapi"
version.workspace = true
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
godot = { version = "0.5", features = ["api-4-3"] }
tokio = { version = "1", features = ["rt-multi-thread", "net", "io-util", "sync", "macros", "time"] }
httparse = "1"
```

选择 `httparse` 而非 `hyper` 的理由：体量小（数百行）、专做 HTTP/1.1 解析、与 tokio 解耦。我们不需要 keep-alive、HTTP/2、TLS。

### 4.2 对外 GDScript API（仅 6 个方法）

```rust
#[derive(GodotClass)]
#[class(base=RefCounted, no_init)]
pub struct GdApiServer {
    runtime: Option<tokio::runtime::Runtime>,
    shutdown_tx: Option<oneshot::Sender<()>>,
    in_rx: Option<mpsc::Receiver<PendingRequest>>,
    pending: HashMap<u64, oneshot::Sender<HttpResponse>>,
    actual_port: Option<u16>,
}

#[godot_api]
impl GdApiServer {
    #[func] fn create() -> Gd<Self>;

    /// 从 port_hint 起逐个 +1 尝试 bind，最多 64 次。
    /// 成功返回端口号；失败返回 -1 并 push_error。
    #[func] fn start(&mut self, port_hint: u16) -> i32;

    /// 停止 server。drop runtime，未完成的 pending 全部返回 503。
    #[func] fn stop(&mut self);

    #[func] fn is_running(&self) -> bool;
    #[func] fn port(&self) -> i32;

    /// 非阻塞 try_recv。无请求返回 null。
    /// 有请求返回 Dictionary：
    ///   { "id": int, "method": String, "path": String,
    ///     "headers": Dictionary<String,String>,
    ///     "body": PackedByteArray }
    #[func] fn poll_request(&mut self) -> Variant;

    /// GDScript 处理完后回填。body 是原始字节（通常 UTF-8 JSON）。
    /// 若 id 对应的 pending 已超时或已关闭，静默丢弃。
    #[func] fn send_response(&mut self, id: i64, status: i64,
                             headers: Dictionary, body: PackedByteArray);
}
```

无其他公开方法。

### 4.3 内部数据流

```
[tokio: accept_loop]
   ↓ new connection
[tokio: per_conn_task]
   read until "\r\n\r\n" + Content-Length body
   parse via httparse
   if parse fails → write 400, close
   if body > 16 MB → write 413, close
   else:
     let id = next_id();
     let (tx, rx) = oneshot::channel();
     pending_map.insert(id, tx);          // 仅 send 时使用，主线程拥有 map
     in_queue.send(PendingRequest { id, ..., resp_tx: tx });
     match tokio::time::timeout(30s, rx).await {
       Ok(resp) => write resp,
       Err(_)   => write 504 {"error":"handler timeout"},
     }
     close
```

主线程侧：

```gdscript
# _process(_dt):
while true:
    var req = server.poll_request()
    if req == null: break
    router.dispatch(req, server)
```

### 4.4 关键参数与策略

| 项 | 值 | 理由 |
|---|---|---|
| 监听地址 | `127.0.0.1`（固定） | 安全：永不暴露外部 |
| 端口探测范围 | 7890 .. 7890+64 | 给多实例足够空间 |
| HTTP 版本 | HTTP/1.1，Connection: close | 编辑器命令吞吐量极低，无需 keep-alive |
| Body 上限 | 16 MB | Rust 层直接拒绝超大 body，返回 413 |
| Handler 超时 | 30 秒 | 大多数编辑器操作秒级完成；超时返回 504 |
| 关停语义 | 同步关闭 runtime，pending 全部 503 | 无 socket 泄漏 |
| 错误隔离 | 单连接 panic 不影响其他（tokio task 隔离） | |

预估代码规模：lib.rs + server.rs + http.rs + queue.rs ≈ 300-400 行（含注释）。

## 5. GDScript 层

### 5.1 plugin.gd（EditorPlugin 入口）

```gdscript
@tool
extends EditorPlugin

const Router := preload("res://addons/gdapi/runtime/router.gd")
const META_PATH := "res://.godot/gdapi.json"
const PORT_HINT := 7890

var _server: GdApiServer
var _router

func _enter_tree() -> void:
    _server = GdApiServer.create()
    var port := _server.start(PORT_HINT)
    if port < 0:
        push_error("[gdapi] failed to bind any port in 7890..7953")
        return
    _router = Router.new()
    _router.scan("res://addons/gdapi/routes")
    _write_meta(port)
    set_process(true)
    print("[gdapi] listening on 127.0.0.1:%d (%d routes)" % [port, _router.count()])

func _exit_tree() -> void:
    set_process(false)
    if _server and _server.is_running():
        _server.stop()
    _delete_meta()

func _process(_dt: float) -> void:
    if _server == null or not _server.is_running(): return
    while true:
        var req: Variant = _server.poll_request()
        if req == null: break
        _router.dispatch(req, _server)

func _write_meta(port: int) -> void:
    var lsp_port := int(EditorInterface.get_editor_settings()
        .get_setting("network/language_server/remote_port"))
    var meta := {
        "http_port": port,
        "lsp_port": lsp_port,
        "pid": OS.get_process_id(),
        "started_at": Time.get_datetime_string_from_system(true),
        "gdapi_version": "0.1.0",
    }
    var f := FileAccess.open(META_PATH, FileAccess.WRITE)
    if f == null:
        push_error("[gdapi] cannot write " + META_PATH); return
    f.store_string(JSON.stringify(meta, "  "))
    f.close()

func _delete_meta() -> void:
    if FileAccess.file_exists(META_PATH):
        DirAccess.remove_absolute(ProjectSettings.globalize_path(META_PATH))
```

### 5.2 文件系统路由规则

```
routes/editor/scene/create.gd   →  POST /scene/create   (editor only)
routes/editor/scene/save.gd     →  POST /scene/save
routes/shared/project/info.gd   →  POST /project/info   (always available)
routes/shared/_ping.gd          →  POST /ping            (内置，特殊处理)
routes/shared/_routes.gd        →  POST /routes          (内置，特殊处理)
```

**规则**

- 顶层目录 `editor/` 或 `shared/` 决定上下文。`play/` 预留，MVP 不扫描。
- 路径 = 文件相对路径去掉顶层目录与 `.gd` 后缀。
- 文件名以 `_` 开头的脚本默认跳过；但 router 内置的 `_ping.gd`、`_routes.gd` 有特殊白名单。
- 所有请求都是 POST（与 `gdcli exec` 契约一致）。

### 5.3 RouteHandler 基类

```gdscript
@tool
class_name GdApiRouteHandler
extends RefCounted

# 子类必须覆盖。默认 405。
func handle(_params: Dictionary) -> Dictionary:
    return {"error": "handler not implemented"}

# 子类可覆盖。默认：含 error 字段返回 500，否则 200。
func status_code(result: Dictionary) -> int:
    return 500 if result.has("error") else 200
```

### 5.4 路由处理脚本约定

```gdscript
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(params: Dictionary) -> Dictionary:
    var scene_path: String = params.get("scene_path", "")
    if scene_path.is_empty():
        return {"error": "scene_path is required", "code": "missing_param"}
    # 业务逻辑 ...
    return {"ok": true, "path": scene_path}
```

**返回值约定**：

- 必须返回 `Dictionary`，否则 router 会替换成 `{"error":"handler must return Dictionary"}`
- 成功：约定包含 `"ok": true`，其余为业务字段
- 失败：约定包含 `"error": "<message>"`，可选 `"code": "<machine_readable>"`、`"details": {...}`

### 5.5 router.dispatch 核心

```gdscript
func dispatch(req: Dictionary, server: GdApiServer) -> void:
    var id: int = req["id"]
    var method: String = req["method"]
    var path: String = req["path"]

    if method != "POST":
        _reply(server, id, 405, {"error": "only POST is supported"})
        return

    var key := path.trim_prefix("/")
    var handler_script: Script = _routes.get(key)
    if handler_script == null:
        _reply(server, id, 404, {
            "error": "route not found: " + path,
            "available": _routes.keys()
        })
        return

    var params := {}
    var body: PackedByteArray = req["body"]
    if body.size() > 0:
        var parsed = JSON.parse_string(body.get_string_from_utf8())
        if typeof(parsed) != TYPE_DICTIONARY:
            _reply(server, id, 400, {"error": "body must be a JSON object"})
            return
        params = parsed

    var handler: GdApiRouteHandler = handler_script.new()
    var result = handler.handle(params)
    if typeof(result) != TYPE_DICTIONARY:
        result = {"error": "handler must return Dictionary, got " + str(typeof(result))}
    var status := handler.status_code(result)
    _reply(server, id, status, result)

func _reply(server: GdApiServer, id: int, status: int, body: Dictionary) -> void:
    var json := JSON.stringify(body)
    var headers := {"Content-Type": "application/json; charset=utf-8"}
    server.send_response(id, status, headers, json.to_utf8_buffer())
```

### 5.6 Context 隔离

`scan()` 时按 `Engine.is_editor_hint()` 过滤：编辑器进程内只加载 `editor/` 和 `shared/`。本次 MVP 因 gdapi 仅在编辑器进程启动，play 进程不会加载 plugin，故实质上只存在 editor 上下文，`play/` 目录留空作为未来预留。

### 5.7 不做的事

- 路由热重载：修改路由脚本后用户需禁用/启用 plugin 或重启编辑器。
- 中间件/拦截器：MVP 不引入。

## 6. gdcli 客户端

### 6.1 命令结构（破坏性变更）

```
gdcli <subcommand> [args] [global opts]

子命令：
  install                          在目标项目安装 gdapi addon
  exec <cmd> [--data <json>]       调用 gdapi 命令
  status                           显示 godot 实例发现状态
  lsp <lsp-subcommand>             现有所有 LSP 命令

全局选项：
  --project <path>                 项目根（可选，默认向上查找）
  --json                           JSON 输出（仅 lsp 子命令）
  --host / --port                  覆盖端口自动发现（仅 lsp）
```

**LSP 子命令**（行为完全等同当前顶层命令）：

```
gdcli lsp rename <target> <new_name>
gdcli lsp references <target>
gdcli lsp definition <target>
gdcli lsp declaration <target>
gdcli lsp symbols <file>
gdcli lsp hover <target>
gdcli lsp native-symbol <class> [member] [--members|--full]
gdcli lsp diagnostics [file]
gdcli lsp capabilities
```

旧顶层命令不保留；README 写明迁移路径。当前 gdcli 版本仍在 0.x，破坏性变更可接受。

### 6.2 项目根检测

适用于所有需要项目上下文的子命令（install、exec、lsp、status）。

```
1. 若指定 --project <dir>：使用该值（验证 <dir>/project.godot 存在）
2. 否则：从当前目录起向上逐级查找 project.godot，最多 5 层
3. 找到 → 该目录为项目根
4. 找不到 → 报错退出，提示用户使用 --project 或切换目录
```

### 6.3 install 子命令

```
gdcli install [--project <dir>] [--force] [--no-enable]
```

**逻辑**

1. 解析 project_root，校验 `project.godot` 存在
2. 目标目录 `<root>/addons/gdapi/`
   - 已存在且无 `--force`：报错 + 提示当前版本号 + `--force` 用法
   - 已存在且 `--force`：先删除整个目录
3. 把内嵌的 addon 模板（编译期通过 `include_dir!` 嵌入 gdcli 二进制）展开到目标
4. 除非 `--no-enable`：解析 `<root>/project.godot`，在 `[editor_plugins]` 段追加 `res://addons/gdapi/plugin.cfg`（保留已有 enabled 列表，去重）
5. 输出：
   ```
   Installed gdapi 0.1.0 → <root>/addons/gdapi/
   Plugin enabled in project.godot.
   Next: open the project in Godot Editor.
   ```

**`include_dir!` 嵌入策略**

- Release 构建：addon 完整目录（含全平台 bin/）打进 gdcli 二进制（约 +3-5 MB）
- Debug 构建：通过 `cfg(debug_assertions)` 走动态路径读取 `gdapi/addon/`，便于本地开发改 GDScript 不用重编 gdcli

### 6.4 exec 子命令

```
gdcli exec <command> [--data <json>] [--timeout <secs>]
```

**逻辑**

1. 解析 project_root
2. 读 `<root>/.godot/gdapi.json`
   - 文件不存在 → 报错："gdapi not running. Open the project in Godot editor with gdapi plugin enabled, or run 'gdcli install' first."
   - JSON 解析失败 → 报错
3. 校验 `pid` 进程仍存活（OS 调用）；不存活则报错 + 建议清理过期文件
4. 处理 `--data`：
   - 无：body = `{}`
   - `--data @file.json`：读文件内容
   - `--data -`：读 stdin
   - 其他：字面 JSON 字符串
   - 客户端先 `serde_json::from_str` 验证；非法则不发请求
5. `POST http://127.0.0.1:<http_port>/<command>`，Content-Type: application/json
6. 超时默认 35 秒（比 server 侧 30s 多 5s buffer），`--timeout` 覆盖
7. 输出：
   - 响应 body 原样写 stdout
   - HTTP 2xx → exit 0
   - HTTP 4xx → stderr 写 `Error (HTTP <code>): <body.error or body>`，exit 2
   - HTTP 5xx → 同上，exit 1
   - 网络/超时错误 → stderr，exit 3

**HTTP 客户端选型**：`ureq`（同步、~50 KB、零依赖）。不引入 reqwest/hyper。

### 6.5 status 子命令（扩展现有）

```
$ gdcli status
Project:        D:\projects\my_game
gdapi:          running (pid 12345, http port 7891, started 2026-06-23 10:00:00)
gdapi version:  0.1.0
LSP:            reachable (port 6005)
```

或：

```
$ gdcli status
Project:        D:\projects\my_game
gdapi:          NOT running (.godot/gdapi.json missing)
LSP:            unreachable on default port 6005
Hint: open the project in Godot Editor and ensure gdapi plugin is enabled.
```

`--json` 输出结构化结果。

### 6.6 LSP 端口发现规则

`gdcli lsp <subcommand>` 中：

1. `--port` 显式指定 → 用之
2. 否则读 `<root>/.godot/gdapi.json` 的 `lsp_port` 字段
3. 否则回退到默认 6005

`--host` 类似，默认始终 `127.0.0.1`。

## 7. 路由清单

总计 **14 个路由**：12 个从 godot-mcp 迁移 + 2 个内置。

### 7.1 内置路由

| 路径 | 用途 |
|---|---|
| `POST /ping` | 健康检查；返回 `{"ok":true,"gdapi_version":"...","editor_version":"..."}` |
| `POST /routes` | 列出所有已注册路由（调试用） |

### 7.2 从 godot-mcp 迁移

| godot-mcp tool | gdapi 路由 | 上下文 | 关键实现 |
|---|---|---|---|
| `get_godot_version` | `/godot/version` | shared | `Engine.get_version_info()` |
| `get_project_info` | `/project/info` | shared | name / main_scene / godot_version / 关键 settings |
| `run_project` | `/project/run` | editor | `EditorInterface.play_main_scene()` 或 `play_custom_scene(path)` |
| `stop_project` | `/project/stop` | editor | `EditorInterface.stop_playing_scene()` |
| `get_debug_output` | `/project/debug_output` | editor | 见 7.4 |
| `create_scene` | `/scene/create` | editor | `PackedScene` + `ResourceSaver.save` + `EditorInterface.reload_scene_from_path` |
| `add_node` | `/scene/add_node` | editor | 加载 → instantiate → 修改 → pack → save |
| `load_sprite` | `/scene/load_sprite` | editor | 含 Sprite2D/3D/TextureRect 类型校验 |
| `save_scene` | `/scene/save` | editor | `EditorInterface.save_scene()` / `save_scene_as()` |
| `export_mesh_library` | `/scene/export_mesh_library` | editor | `MeshLibrary` 构造与保存 |
| `get_uid` | `/uid/get` | shared | 读 `<file>.uid` 或 `ResourceUID` API |
| `update_project_uids` | `/uid/update_all` | editor | 遍历 `.tscn/.gd/.shader` 重新 save |

### 7.3 不迁移

- `list_projects`：文件系统扫描行为，与"在编辑器内部执行"语义不符
- `launch_editor`：编辑器未启动时 gdapi 不可达，逻辑上无法实现；如有需要可作为 gdcli 顶层命令（本规格外）

### 7.4 `/project/debug_output` 设计

godot-mcp 的 `get_debug_output` 是 capture 子进程 stdout。gdapi 在编辑器进程内，采用滚动缓冲区方案：

- gdapi plugin 内维护一个环形缓冲区（默认 1000 条），订阅编辑器日志/`print()` 输出
- 路由请求体：`{"since": <int seq>, "limit": <int>}`
- 响应：`{"entries": [{"seq":..,"level":..,"text":..,"ts":..}], "next_since": <int>}`

**已知限制**：若 Godot 4.x API 不允许完全捕获编辑器内全部输出，MVP 仅捕获 `print()`/`printerr()` 通过 GDScript 重定向 sink 能拿到的部分。若实现遇阻，可先返回 `{"error":"not implemented in this version","hint":"..."}` 作为占位，后续迭代。

### 7.5 路由 schema 文档

每个路由的 request/response schema 写入 `docs/exec-commands.md`，含示例请求与响应。

## 8. 错误处理统一约定

### 8.1 响应 body 形态

```json
// 成功
{ "ok": true, "...业务字段..." }

// 失败
{ "error": "<human-readable>", "code": "<machine-readable>", "details": {...} }
```

### 8.2 HTTP 状态码

| 状态 | 触发场景 |
|---|---|
| 200 | handler 成功 |
| 400 | body 非合法 JSON 对象、必填参数缺失 |
| 404 | 路由不存在 |
| 405 | 非 POST 方法 |
| 413 | body > 16 MB（Rust 层直接拒绝） |
| 500 | handler 返回含 `error` 字段或抛 GDScript 错误 |
| 503 | server 正在关闭 |
| 504 | handler 超过 30 秒未响应 |

### 8.3 gdcli 退出码

| 退出码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | server 错误（5xx）、install 失败、一般运行时错误 |
| 2 | 参数错误（clap）、HTTP 4xx、项目检测失败 |
| 3 | 网络错误、gdapi 不可达、超时 |

## 9. 测试策略

### 9.1 Rust GDExtension（gdapi）

- **单元测试**：httparse 解析路径覆盖（含畸形请求、超大 body、缺失 Content-Length）
- **集成测试**：起一个 mock 的 GDScript 替代（另一个 tokio task）执行 `recv → send_response`，用 `ureq` 真打 HTTP 请求验证。无需启动 Godot 即可验证 server 内核。

### 9.2 gdcli（Rust CLI）

- **单元测试**：`--data` 解析（字面值/`@file`/`-` stdin）、project_root 向上查找、`.godot/gdapi.json` 解析、退出码映射
- **集成测试**：用 `httpmock`（或类似）模拟 gdapi 响应，验证 exec 完整链路

### 9.3 GDScript 路由层

MVP **不写 GDScript 单元测试**（引入 GUT/gdUnit4 成本高），改用端到端覆盖。

### 9.4 端到端测试

- 准备 fixture Godot 项目
- 启动 Godot（`godot --headless --editor --path <fixture>`），等 `.godot/gdapi.json` 出现
- 跑 `gdcli exec ping`、`gdcli exec scene/create --data '...'`
- 验证响应 + 副作用（文件确实被创建）
- 关闭 Godot

MVP 范围：`scripts/e2e.sh` 本地手动跑。CI 集成 Godot 自动化留作后续工作。

## 10. 构建与发布

### 10.1 本地构建

```bash
cargo build --release --workspace          # gdcli + gdapi
cargo build --release -p gdcli              # 仅 gdcli
cargo build --release -p gdapi              # 仅 gdapi
```

### 10.2 全平台发布（CI）

GitHub Actions 矩阵：

1. windows-latest / macos-latest / ubuntu-latest 各自构建 `gdapi` → 上传 artifact
2. 汇总 job 下载全部 artifact → 放置到 `gdapi/addon/bin/{windows,macos,linux}/`
3. 再次矩阵：3 个平台分别构建 `gdcli`（此时 `include_dir!` 把全平台 gdapi 二进制嵌入 gdcli 自身）
4. 发布 release：3 个 gdcli 二进制，每个均内含全平台 gdapi 库（≈ +3-5 MB）

### 10.3 开发模式

`cfg(debug_assertions)` 下 install 命令走动态路径读 `gdapi/addon/`，便于本地改 GDScript 不需要重编 gdcli。

## 11. 文档更新

- `README.md`：重写覆盖 install / exec / lsp 三组命令；含旧命令迁移说明
- `docs/exec-commands.md`：每个路由的 request/response schema 与示例
- `gdapi/addon/README.md`：给 Godot 用户看的 addon 介绍

## 12. 实现阶段建议（垂直切片）

实现计划将按以下阶段切分（具体由 writing-plans 产出）：

1. **端到端最小连通**：Rust HTTP server + GDScript 路由器 + `/ping` 路由 + `gdcli exec ping` 跑通
2. **install 子命令** + addon 模板打包 + `include_dir!` 集成
3. **gdcli CLI 重构**：现有顶层命令降级到 `lsp/`，新增 `status` 扩展
4. **路由批量迁移**：14 个路由分组实现（先 shared 类查询型，再 scene 类，最后 project/uid）
5. **LSP 端口发现**：gdapi 写入 `lsp_port` + gdcli lsp 子命令读取
6. **文档与发布流程**

每个阶段独立可验证，第 1 阶段验证了最难的跨语言异步通信，后续都是增量。
