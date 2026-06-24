# gdapi 路由处理器 req/res 改造设计

> 日期: 2026-06-24
> 状态: 待审批
> 作者: Jerry + AI

## 背景

当前 gdapi 路由处理器采用返回值方式响应 HTTP 请求：

```gdscript
func handle(params: Dictionary) -> Dictionary:
    return {"ok": true, ...}  # 成功
    return {"error": "...", "code": "..."}  # 失败
```

这种方式存在以下问题：
1. **返回值耦合** - 响应格式与业务逻辑耦合
2. **无法精细控制** - 无法设置自定义 headers、显式 status code
3. **请求信息不完整** - `params` 只是 body，缺少 headers、query params 等
4. **不符合 Express 模式** - 缺少 `req/res` 的灵活性

## 目标

将路由处理器改造为类似 Node.js Express 的 `handle(req, res)` 形态：
1. 精心设计 req、res 对象的数据结构和方法
2. 不通过返回值来响应，而是调用 res 方法
3. 保持 GDScript 的惯用法，提供完整的便捷方法

## 设计决策

| 决策点 | 选择 | 理由 |
|--------|------|------|
| 实现方式 | 完整类封装 | 类型安全，IDE 支持好 |
| 链式调用 | Express 风格（返回 self） | 灵活，代码简洁 |
| 错误处理 | 两者兼容 | error() 便捷 + 手动组合灵活 |
| 函数签名 | 纯 req/res | 干净，无额外参数 |
| 默认状态码 | 默认 200，必须显式设置 | 清晰，不易出错 |
| 迁移策略 | 一次性全量迁移 | 一致性高，无兼容负担 |
| 便捷方法 | 完整便捷方法 | 开发体验好 |
| 中间件 | 不预留 | 保持简单，YAGNI |
| 基类 | 保留，强制继承 | 类型检查，一致性 |
| 响应类型 | JSON + send + file | 灵活，满足多种场景 |
| 流式响应 | 不支持 | 当前无需求 |
| Body 类型 | 仅支持 JSON | 简化设计 |
| 错误格式 | 灵活错误格式 | 支持多种错误形式 |

## 架构设计

### 类图

```
┌─────────────────┐     ┌─────────────────┐
│  GdApiRequest   │     │  GdApiResponse  │
├─────────────────┤     ├─────────────────┤
│ + method        │     │ - _status       │
│ + path          │     │ - _headers      │
│ + headers       │     │ - _server       │
│ + body          │     │ - _request_id   │
│ + query         │     │ - _sent         │
│ + params        │     ├─────────────────┤
│ + raw_body      │     │ + status()      │
├─────────────────┤     │ + set()         │
│ + get_body()    │     │ + type()        │
│ + get_header()  │     │ + json()        │
│ + has_body()    │     │ + send()        │
│ + get_query()   │     │ + file()        │
│ + is_json()     │     │ + error()       │
│ + client_ip()   │     └─────────────────┘
└─────────────────┘
```

### 请求流程

```
HTTP Request
    │
    ▼
┌─────────────────┐
│ Rust HTTP Server│
│ (parse_request) │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Request Queue   │
│ (mpsc channel)  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐     ┌─────────────────┐
│ Router.dispatch │────▶│ GdApiRequest.new│
│                 │     │ GdApiResponse.new│
└────────┬────────┘     └─────────────────┘
         │
         ▼
┌─────────────────┐
│ Handler.handle  │
│ (req, res)      │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ res.json()      │
│ res.send()      │
│ res.file()      │
│ res.error()     │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Response Queue  │
│ (oneshot)       │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Rust HTTP Server│
│ (write_response)│
└─────────────────┘
```

## 详细设计

### 1. GdApiRequest 类

**文件**: `gdapi/addon/runtime/request.gd`

```gdscript
@tool
class_name GdApiRequest
extends RefCounted

# ─── 属性 ────────────────────────────────────────────
var method: String       # HTTP 方法: "POST"
var path: String         # 请求路径: "/scene/save"
var headers: Dictionary  # 请求头: {"content-type": "application/json", ...}
var body: Dictionary     # 解析后的 JSON body
var query: String        # 原始 query string
var params: Dictionary   # 路径参数（预留）
var raw_body: PackedByteArray  # 原始字节

# ─── 初始化 ──────────────────────────────────────────
func _init(req_dict: Dictionary) -> void:
    method = req_dict.get("method", "POST")
    path = req_dict.get("path", "/")
    headers = req_dict.get("headers", {})
    raw_body = req_dict.get("body", PackedByteArray())
    
    # 解析 query string
    var parts := path.split("?", true, 1)
    if parts.size() > 1:
        path = parts[0]
        query = parts[1]
    
    # 解析 JSON body
    if raw_body.size() > 0:
        var text := raw_body.get_string_from_utf8()
        var parsed = JSON.parse_string(text)
        if typeof(parsed) == TYPE_DICTIONARY:
            body = parsed

# ─── 便捷方法 ────────────────────────────────────────
## 获取 body 字段值
func get_body(key: String, default: Variant = null) -> Variant:
    return body.get(key, default)

## 获取请求头（小写 key）
func get_header(name: String) -> String:
    return headers.get(name.to_lower(), "")

## 检查 body 字段是否存在
func has_body(key: String) -> bool:
    return body.has(key)

## 解析 query string 参数
func get_query(key: String, default: String = "") -> String:
    for param in query.split("&"):
        var kv := param.split("=", true, 1)
        if kv.size() == 2 and kv[0] == key:
            return kv[1]
    return default

## 检查 Content-Type 是否为 JSON
func is_json() -> bool:
    var ct := get_header("content-type")
    return ct.begins_with("application/json")

## 获取客户端 IP
func client_ip() -> String:
    return headers.get("x-forwarded-for", headers.get("remote-addr", "127.0.0.1"))
```

### 2. GdApiResponse 类

**文件**: `gdapi/addon/runtime/response.gd`

```gdscript
@tool
class_name GdApiResponse
extends RefCounted

# ─── 属性 ────────────────────────────────────────────
var _status: int = 200
var _headers: Dictionary = {}
var _server  # GdApiServer 实例
var _request_id: int
var _sent: bool = false

# ─── 初始化 ──────────────────────────────────────────
func _init(server, request_id: int) -> void:
    _server = server
    _request_id = request_id
    _headers["Content-Type"] = "application/json; charset=utf-8"

# ─── 链式方法 ────────────────────────────────────────
## 设置 HTTP 状态码
func status(code: int) -> GdApiResponse:
    _status = code
    return self

## 设置响应头
func set(key: String, value: String) -> GdApiResponse:
    _headers[key] = value
    return self

## 设置 Content-Type
func type(content_type: String) -> GdApiResponse:
    _headers["Content-Type"] = content_type
    return self

# ─── 终结方法 ────────────────────────────────────────
## 发送 JSON 响应
func json(data: Dictionary) -> void:
    _send(JSON.stringify(data).to_utf8_buffer())

## 发送纯文本响应
func send(content: String) -> void:
    if not _headers.has("Content-Type"):
        _headers["Content-Type"] = "text/plain; charset=utf-8"
    _send(content.to_utf8_buffer())

## 发送文件响应
func file(path: String) -> void:
    var abs_path := ProjectSettings.globalize_path(path)
    if not FileAccess.file_exists(abs_path):
        error("file not found: " + path, "not_found", 404)
        return
    
    var f := FileAccess.open(abs_path, FileAccess.READ)
    if f == null:
        error("cannot read file: " + path, "read_error", 500)
        return
    
    var buffer := f.get_buffer(f.get_length())
    f.close()
    
    var ext := path.get_extension().to_lower()
    var mime := _get_mime_type(ext)
    _headers["Content-Type"] = mime
    _send(buffer)

## 发送错误响应
func error(msg: String, code: String = "error", status: int = 400, details: Dictionary = {}) -> void:
    _status = status
    var body := {"error": msg, "code": code}
    if not details.is_empty():
        body["details"] = details
    json(body)

# ─── 内部方法 ────────────────────────────────────────
func _send(body: PackedByteArray) -> void:
    if _sent:
        push_warning("GdApiResponse: already sent")
        return
    _sent = true
    
    var headers_dict := {}
    for key in _headers:
        headers_dict[key] = _headers[key]
    
    _server.send_response(_request_id, _status, headers_dict, body)

func _get_mime_type(ext: String) -> String:
    match ext:
        "png": return "image/png"
        "jpg", "jpeg": return "image/jpeg"
        "gif": return "image/gif"
        "svg": return "image/svg+xml"
        "json": return "application/json"
        "txt": return "text/plain"
        "html": return "text/html"
        "css": return "text/css"
        "js": return "application/javascript"
        "gdshader", "shader": return "text/plain"
        "tscn", "tres", "gd": return "text/plain"
        _: return "application/octet-stream"
```

### 3. 更新后的 route_handler.gd

```gdscript
@tool
class_name GdApiRouteHandler
extends RefCounted

## 路由处理器基类。所有 routes/**/*.gd 必须 extends 它。
##
## 子类约定：
## - 必须覆盖 handle(req: GdApiRequest, res: GdApiResponse) -> void
## - 通过 res.json() 返回成功响应
## - 通过 res.error() 返回错误响应
## - 不要使用返回值

func handle(_req: GdApiRequest, _res: GdApiResponse) -> void:
    push_error("handler not implemented")
```

### 4. 更新后的 router.gd

```gdscript
@tool
extends RefCounted

const GdApiRequest := preload("res://addons/gdapi/runtime/request.gd")
const GdApiResponse := preload("res://addons/gdapi/runtime/response.gd")
const BuiltinPing := preload("res://addons/gdapi/runtime/builtin_ping.gd")
const BuiltinRoutes := preload("res://addons/gdapi/runtime/builtin_routes.gd")

var _routes: Dictionary = {}
var _builtin_routes_handler: BuiltinRoutes

func scan(root_dir: String) -> void:
    # ... 保持不变 ...

func count() -> int:
    return _routes.size() + 1

func _scan_dir(dir_path: String, prefix: String) -> void:
    # ... 保持不变 ...

func dispatch(req_dict: Dictionary, server) -> void:
    var id: int = req_dict["id"]
    var method: String = req_dict["method"]
    var path: String = req_dict["path"]

    if method != "POST":
        _reply_error(server, id, 405, "only POST is supported", "method_not_allowed")
        return

    var key: String = path.trim_prefix("/")

    # /routes 特殊处理
    if key == "routes":
        var req := GdApiRequest.new(req_dict)
        var res := GdApiResponse.new(server, id)
        _builtin_routes_handler.handle(req, res)
        return

    if not _routes.has(key):
        _reply_error(server, id, 404, "route not found: /" + key, "not_found")
        return

    var handler_script: Script = _routes[key]
    var handler = handler_script.new()

    var req := GdApiRequest.new(req_dict)
    var res := GdApiResponse.new(server, id)

    handler.handle(req, res)

func _reply_error(server, id: int, status: int, msg: String, code: String) -> void:
    var res := GdApiResponse.new(server, id)
    res.error(msg, code, status)
```

### 5. 路由示例转换

#### builtin_ping.gd

**旧代码:**
```gdscript
func handle(_params: Dictionary) -> Dictionary:
    return {
        "ok": true,
        "gdapi_version": "0.2.0",
        "editor_version": Engine.get_version_info().get("string", ""),
    }
```

**新代码:**
```gdscript
func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
    res.json({
        "ok": true,
        "gdapi_version": "0.2.0",
        "editor_version": Engine.get_version_info().get("string", ""),
    })
```

#### builtin_routes.gd

**旧代码:**
```gdscript
func handle(_params: Dictionary) -> Dictionary:
    return {"ok": true, "routes": _route_names}
```

**新代码:**
```gdscript
func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
    res.json({"ok": true, "routes": _route_names})
```

#### routes/editor/scene/save.gd

**旧代码:**
```gdscript
func handle(params: Dictionary) -> Dictionary:
    var scene_path: String = params.get("scene_path", "")
    var new_path: String = params.get("new_path", "")

    if scene_path.is_empty():
        return {"error": "scene_path is required", "code": "missing_param"}

    if not scene_path.begins_with("res://"):
        scene_path = "res://" + scene_path

    var abs_path := ProjectSettings.globalize_path(scene_path)
    if not FileAccess.file_exists(abs_path):
        return {"error": "scene not found: " + scene_path, "code": "not_found"}

    # ... 业务逻辑 ...

    return {
        "ok": true,
        "path": save_path,
    }
```

**新代码:**
```gdscript
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
    var scene_path: String = req.get_body("scene_path", "")
    var new_path: String = req.get_body("new_path", "")

    if scene_path.is_empty():
        res.error("scene_path is required", "missing_param")
        return

    if not scene_path.begins_with("res://"):
        scene_path = "res://" + scene_path

    var abs_path := ProjectSettings.globalize_path(scene_path)
    if not FileAccess.file_exists(abs_path):
        res.error("scene not found: " + scene_path, "not_found", 404)
        return

    # ... 业务逻辑 ...

    res.json({
        "ok": true,
        "path": save_path,
    })
```

#### routes/editor/scene/create.gd

**旧代码:**
```gdscript
func handle(params: Dictionary) -> Dictionary:
    var scene_path: String = params.get("scene_path", "")
    if scene_path.is_empty():
        return {"error": "scene_path is required", "code": "missing_param"}

    var root_type: String = params.get("root_node_type", "Node2D")

    # ... 业务逻辑 ...

    return {
        "ok": true,
        "path": scene_path,
        "root_type": root_type,
    }
```

**新代码:**
```gdscript
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
    var scene_path: String = req.get_body("scene_path", "")
    if scene_path.is_empty():
        res.error("scene_path is required", "missing_param")
        return

    var root_type: String = req.get_body("root_node_type", "Node2D")

    # ... 业务逻辑 ...

    res.json({
        "ok": true,
        "path": scene_path,
        "root_type": root_type,
    })
```

#### routes/editor/project/run.gd

**旧代码:**
```gdscript
func handle(params: Dictionary) -> Dictionary:
    var scene_path: String = params.get("scene_path", "")

    if scene_path.is_empty():
        EditorInterface.play_main_scene()
        return {"ok": true, "action": "play_main_scene"}

    # ... 业务逻辑 ...

    return {"ok": true, "action": "play_custom_scene", "scene": scene_path}
```

**新代码:**
```gdscript
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
    var scene_path: String = req.get_body("scene_path", "")

    if scene_path.is_empty():
        EditorInterface.play_main_scene()
        res.json({"ok": true, "action": "play_main_scene"})
        return

    # ... 业务逻辑 ...

    res.json({"ok": true, "action": "play_custom_scene", "scene": scene_path})
```

#### routes/shared/godot/version.gd

**旧代码:**
```gdscript
func handle(_params: Dictionary) -> Dictionary:
    var info := Engine.get_version_info()
    return {
        "ok": true,
        "version": info.get("string", ""),
        "major": info.get("major", 0),
        "minor": info.get("minor", 0),
        "patch": info.get("patch", 0),
        "status": info.get("status", ""),
        "build": info.get("build", ""),
    }
```

**新代码:**
```gdscript
func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
    var info := Engine.get_version_info()
    res.json({
        "ok": true,
        "version": info.get("string", ""),
        "major": info.get("major", 0),
        "minor": info.get("minor", 0),
        "patch": info.get("patch", 0),
        "status": info.get("status", ""),
        "build": info.get("build", ""),
    })
```

## 需要修改的文件清单

### 新增文件
1. `gdapi/addon/runtime/request.gd` - GdApiRequest 类
2. `gdapi/addon/runtime/response.gd` - GdApiResponse 类

### 修改文件
1. `gdapi/addon/runtime/route_handler.gd` - 更新基类签名
2. `gdapi/addon/runtime/router.gd` - 更新 dispatch 方法
3. `gdapi/addon/runtime/builtin_ping.gd` - 更新 handle 签名
4. `gdapi/addon/runtime/builtin_routes.gd` - 更新 handle 签名

### 路由文件（全量迁移）
1. `gdapi/addon/routes/editor/scene/save.gd`
2. `gdapi/addon/routes/editor/scene/create.gd`
3. `gdapi/addon/routes/editor/scene/load_sprite.gd`
4. `gdapi/addon/routes/editor/scene/add_node.gd`
5. `gdapi/addon/routes/editor/scene/export_mesh_library.gd`
6. `gdapi/addon/routes/editor/project/debug_output.gd`
7. `gdapi/addon/routes/editor/project/stop.gd`
8. `gdapi/addon/routes/editor/project/run.gd`
9. `gdapi/addon/routes/editor/uid/update_all.gd`
10. `gdapi/addon/routes/shared/godot/version.gd`
11. `gdapi/addon/routes/shared/project/info.gd`
12. `gdapi/addon/routes/shared/uid/get.gd`

## 测试策略

### 单元测试
- GdApiRequest 初始化测试
- GdApiRequest 便捷方法测试
- GdApiResponse 链式调用测试
- GdApiResponse 错误处理测试

### 集成测试
- 完整请求/响应流程测试
- 错误场景测试
- 文件响应测试

### 手动测试
```bash
# 测试 ping 路由
gdcli exec ping --project /path/to/project

# 测试 scene/create 路由
gdcli exec scene/create --project /path/to/project --body '{"scene_path": "test.tscn"}'

# 测试错误场景
gdcli exec scene/save --project /path/to/project --body '{}'
```

## 风险与缓解

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| 全量迁移遗漏 | 高 | 逐个文件测试，确保每个路由都更新 |
| 旧代码兼容 | 中 | 无兼容层，强制迁移 |
| 性能影响 | 低 | 对象创建开销可忽略 |
| IDE 支持弱 | 低 | 使用 class_name 提供类型提示 |

## 后续扩展

以下功能不在本次设计范围内，但接口已预留扩展点：

1. **中间件支持** - 可在 router.gd 中扩展
2. **路径参数** - GdApiRequest.params 已预留
3. **流式响应** - 可在 GdApiResponse 中扩展
4. **文件上传** - 可在 GdApiRequest 中扩展

## 参考

- [Express.js Request API](https://expressjs.com/en/4x/api.html#req)
- [Express.js Response API](https://expressjs.com/en/4x/api.html#res)
- [gdapi 现有架构](../plans/2026-06-23-phase1-gdapi-minimal-e2e.md)
