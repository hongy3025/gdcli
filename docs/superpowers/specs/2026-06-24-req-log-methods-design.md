# GdApiRequest 日志方法优化设计

**日期:** 2026-06-24  
**状态:** 待审批  
**范围:** gdapi 插件日志系统优化

## 问题

当前路由处理器记录日志需要重复的样板代码：

```gdscript
var plugin = Engine.get_meta("gdapi_plugin", null)
if plugin:
    plugin.log_message("message", "info")
```

此模式在 5 处路由处理器中重复出现，冗长且无日志级别过滤能力。

## 目标

1. 将日志方法嵌入 `GdApiRequest`，处理器直接调用 `req.log_info()` 等
2. 引入全局日志级别机制（debug/info/warn/error）
3. 提供 API 端点动态设置日志级别
4. 保留 `plugin.log_message()` 供外部使用

## 设计

### 1. 日志级别定义（plugin.gd）

新增常量和变量：

```gdscript
const LOG_DEBUG := 0
const LOG_INFO  := 1
const LOG_WARN  := 2
const LOG_ERROR := 3
const LOG_LEVEL_NAMES := {0: "debug", 1: "info", 2: "warn", 3: "error"}
var _log_level: int = LOG_INFO
```

级别有序，`_log_level` 控制最低记录级别。级别值 <= `_log_level` 的消息才会被记录。

### 2. GdApiRequest 日志方法（request.gd）

构造函数新增插件引用获取：

```gdscript
var _plugin = null

func _init(req_dict: Dictionary) -> void:
    # ... 现有解析逻辑不变 ...
    if Engine.has_meta("gdapi_plugin"):
        _plugin = Engine.get_meta("gdapi_plugin")
```

新增四个日志方法：

```gdscript
func log_debug(text: String) -> void:
    if _plugin and _plugin._log_level <= _plugin.LOG_DEBUG:
        _plugin.log_message(text, "debug")

func log_info(text: String) -> void:
    if _plugin and _plugin._log_level <= _plugin.LOG_INFO:
        _plugin.log_message(text, "info")

func log_warn(text: String) -> void:
    if _plugin and _plugin._log_level <= _plugin.LOG_WARN:
        _plugin.log_message(text, "warn")

func log_error(text: String) -> void:
    if _plugin and _plugin._log_level <= _plugin.LOG_ERROR:
        _plugin.log_message(text, "error")
```

### 3. 路由处理器迁移

将所有 `plugin.log_message(...)` 调用替换为 `req.log_*()`：

| 文件 | 原调用 | 新调用 |
|------|--------|--------|
| `routes/editor/project/run.gd:24` | `plugin.log_message("Started playing main scene", "info")` | `req.log_info("Started playing main scene")` |
| `routes/editor/project/run.gd:44` | `plugin.log_message("Started playing scene: " + scene_path, "info")` | `req.log_info("Started playing scene: " + scene_path)` |
| `routes/editor/project/stop.gd:26` | `plugin.log_message("Stopped playing scene", "info")` | `req.log_info("Stopped playing scene")` |
| `routes/editor/scene/create.gd:66` | `plugin.log_message("Created scene: " + scene_path, "info")` | `req.log_info("Created scene: " + scene_path)` |
| `routes/editor/scene/add_node.gd:91` | `plugin.log_message("Added node ...", "info")` | `req.log_info("Added node " + node_name + " (" + node_type + ") to " + scene_path)` |

同时删除各文件中获取 plugin 的 `var plugin = Engine.get_meta(...)` 行。

### 4. 日志级别 API（新文件）

新增 `routes/editor/log/level.gd`：

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
    if not Engine.has_meta("gdapi_plugin"):
        res.error("gdapi plugin not available", "plugin_not_ready", 503)
        return

    var plugin = Engine.get_meta("gdapi_plugin")
    var new_level: String = req.get_body("level", "")

    if new_level.is_empty():
        res.json({
            "ok": true,
            "level": plugin.LOG_LEVEL_NAMES.get(plugin._log_level, "info"),
        })
        return

    var level_map := {"debug": 0, "info": 1, "warn": 2, "error": 3}
    if not level_map.has(new_level.to_lower()):
        res.error("invalid level: " + new_level + ". Use: debug, info, warn, error", "invalid_param", 400)
        return

    plugin._log_level = level_map[new_level.to_lower()]
    res.json({"ok": true, "level": new_level.to_lower()})
```

**API 调用：**
- 查询当前级别：`POST /log/level` body: `{}`
- 设置级别：`POST /log/level` body: `{"level": "debug"}`

### 5. 不变的部分

- `plugin.log_message()` 保留原样，供外部调用
- `debug_output` 路由保持返回所有级别日志，客户端自行过滤
- `get_log_since()` 方法不变
- `router.gd` 的 `dispatch()` 签名不变

## 涉及文件

| 文件 | 操作 |
|------|------|
| `addon/plugin.gd` | 新增日志级别常量和变量 |
| `addon/runtime/request.gd` | 新增 `_plugin` 属性和四个 `log_*` 方法 |
| `addon/routes/editor/project/run.gd` | 迁移日志调用 |
| `addon/routes/editor/project/stop.gd` | 迁移日志调用 |
| `addon/routes/editor/scene/create.gd` | 迁移日志调用 |
| `addon/routes/editor/scene/add_node.gd` | 迁移日志调用 |
| `addon/routes/editor/log/level.gd` | 新增文件 |

## 验证

1. 启动 Godot 编辑器，加载 gdapi 插件
2. 调用 `POST /editor/project/run` — 确认日志记录且无报错
3. 调用 `POST /log/level` body: `{"level": "debug"}` — 确认返回成功
4. 调用 `POST /log/level` body: `{}` — 确认返回 "debug"
5. 调用 `POST /editor/project/debug_output` — 确认能获取日志条目
