# GdApiRequest 日志方法优化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [`) syntax for tracking.

**Goal:** 将日志方法嵌入 GdApiRequest，引入全局日志级别机制，提供 API 端点设置级别

**Architecture:** 在 plugin.gd 新增日志级别常量和全局变量；在 request.gd 通过 Engine meta 获取插件引用并暴露 log_debug/info/warn/error 方法；新增独立路由处理级别查询/设置；迁移 4 个路由处理器的调用方式

**Tech Stack:** GDScript, Godot EditorPlugin, GdApi HTTP server

## Global Constraints

- `plugin.log_message()` 保留不删除，供外部调用
- `debug_output` 路由返回所有级别日志，不过滤
- `router.gd` 的 `dispatch()` 签名不变
- 日志级别默认 `LOG_INFO (1)`

---

### Task 1: plugin.gd 新增日志级别定义

**Files:**
- Modify: `gdapi/addon/plugin.gd`

**Interfaces:**
- Produces: `LOG_DEBUG`, `LOG_INFO`, `LOG_WARN`, `LOG_ERROR` 常量（int）
- Produces: `LOG_LEVEL_NAMES` 字典（int -> String）
- Produces: `_log_level` 变量（int，默认 `LOG_INFO`）

- [ ] **Step 1: 在 plugin.gd 中添加日志级别常量**

在 `const MAX_LOG_ENTRIES: int = 1000` 之后添加：

```gdscript
## 日志级别常量
const LOG_DEBUG := 0
const LOG_INFO  := 1
const LOG_WARN  := 2
const LOG_ERROR := 3

## 级别名称映射
const LOG_LEVEL_NAMES := {0: "debug", 1: "info", 2: "warn", 3: "error"}
```

- [ ] **Step 2: 添加全局日志级别变量**

在 `var _log_seq: int = 0` 之后添加：

```gdscript
## 当前全局日志级别，默认 INFO
var _log_level: int = LOG_INFO
```

- [ ] **Step 3: 验证文件无语法错误**

在 Godot 编辑器中确认 plugin.gd 无报错，或用 `gdtoolkit` 的 `gdparse` 检查。

- [ ] **Step 4: Commit**

```bash
git add gdapi/addon/plugin.gd
git commit -m "feat: add log level constants and global level to plugin"
```

---

### Task 2: GdApiRequest 新增日志方法

**Files:**
- Modify: `gdapi/addon/runtime/request.gd`

**Interfaces:**
- Consumes: `Engine.get_meta("gdapi_plugin")` — plugin 实例
- Produces: `req.log_debug(text)`, `req.log_info(text)`, `req.log_warn(text)`, `req.log_error(text)`

- [ ] **Step 1: 添加 _plugin 属性**

在 `var raw_body: PackedByteArray` 之后添加：

```gdscript
## 插件引用，用于日志记录
var _plugin = null
```

- [ ] **Step 2: 在 _init 中获取插件引用**

在 `_init` 函数末尾（JSON 解析逻辑之后）添加：

```gdscript
	# 获取插件引用用于日志
	if Engine.has_meta("gdapi_plugin"):
		_plugin = Engine.get_meta("gdapi_plugin")
```

- [ ] **Step 3: 添加四个日志方法**

在 `client_ip()` 方法之后添加：

```gdscript
## 记录 debug 级别日志
## @param text 日志内容
func log_debug(text: String) -> void:
	if _plugin and _plugin._log_level <= _plugin.LOG_DEBUG:
		_plugin.log_message(text, "debug")

## 记录 info 级别日志
## @param text 日志内容
func log_info(text: String) -> void:
	if _plugin and _plugin._log_level <= _plugin.LOG_INFO:
		_plugin.log_message(text, "info")

## 记录 warn 级别日志
## @param text 日志内容
func log_warn(text: String) -> void:
	if _plugin and _plugin._log_level <= _plugin.LOG_WARN:
		_plugin.log_message(text, "warn")

## 记录 error 级别日志
## @param text 日志内容
func log_error(text: String) -> void:
	if _plugin and _plugin._log_level <= _plugin.LOG_ERROR:
		_plugin.log_message(text, "error")
```

- [ ] **Step 4: 验证文件无语法错误**

确认 request.gd 无报错。

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/request.gd
git commit -m "feat: add log_debug/info/warn/error methods to GdApiRequest"
```

---

### Task 3: 迁移路由处理器日志调用

**Files:**
- Modify: `gdapi/addon/routes/editor/project/run.gd`
- Modify: `gdapi/addon/routes/editor/project/stop.gd`
- Modify: `gdapi/addon/routes/editor/scene/create.gd`
- Modify: `gdapi/addon/routes/editor/scene/add_node.gd`

**Interfaces:**
- Consumes: `req.log_info(text)` — 由 Task 2 提供

- [ ] **Step 1: 迁移 run.gd**

删除 L22-24 的 plugin 获取和 log 调用：
```gdscript
		var plugin = Engine.get_meta("gdapi_plugin", null)
		if plugin:
			plugin.log_message("Started playing main scene", "info")
```
替换为：
```gdscript
		req.log_info("Started playing main scene")
```

删除 L42-44 的 plugin 获取和 log 调用：
```gdscript
	var plugin = Engine.get_meta("gdapi_plugin", null)
	if plugin:
		plugin.log_message("Started playing scene: " + scene_path, "info")
```
替换为：
```gdscript
	req.log_info("Started playing scene: " + scene_path)
```

- [ ] **Step 2: 迁移 stop.gd**

删除 L24-26 的 plugin 获取和 log 调用：
```gdscript
	var plugin = Engine.get_meta("gdapi_plugin", null)
	if plugin:
		plugin.log_message("Stopped playing scene", "info")
```
替换为：
```gdscript
	req.log_info("Stopped playing scene")
```

注意：stop.gd 的 handle 参数是 `_req`，需要改为 `req`（去掉下划线前缀），因为现在要用到它。

- [ ] **Step 3: 迁移 create.gd**

删除 L64-66 的 plugin 获取和 log 调用：
```gdscript
	var plugin = Engine.get_meta("gdapi_plugin", null)
	if plugin:
		plugin.log_message("Created scene: " + scene_path, "info")
```
替换为：
```gdscript
	req.log_info("Created scene: " + scene_path)
```

- [ ] **Step 4: 迁移 add_node.gd**

删除 L89-91 的 plugin 获取和 log 调用：
```gdscript
	var plugin = Engine.get_meta("gdapi_plugin", null)
	if plugin:
		plugin.log_message("Added node " + node_name + " (" + node_type + ") to " + scene_path, "info")
```
替换为：
```gdscript
	req.log_info("Added node " + node_name + " (" + node_type + ") to " + scene_path)
```

- [ ] **Step 5: 验证所有文件无语法错误**

确认 4 个文件均无报错。

- [ ] **Step 6: Commit**

```bash
git add gdapi/addon/routes/editor/project/run.gd gdapi/addon/routes/editor/project/stop.gd gdapi/addon/routes/editor/scene/create.gd gdapi/addon/routes/editor/scene/add_node.gd
git commit -m "refactor: migrate route handlers to use req.log_info()"
```

---

### Task 4: 新增日志级别 API 路由

**Files:**
- Create: `gdapi/addon/routes/editor/log/level.gd`

**Interfaces:**
- Consumes: `Engine.get_meta("gdapi_plugin")` — plugin 实例
- Consumes: `plugin.LOG_LEVEL_NAMES`, `plugin._log_level`
- Produces: `POST /log/level` API 端点

- [ ] **Step 1: 创建路由文件**

创建 `gdapi/addon/routes/editor/log/level.gd`：

```gdscript
## 日志级别路由处理器
##
## 提供查询和设置全局日志级别的 API 端点。
## 查询：POST /log/level body: {}
## 设置：POST /log/level body: {"level": "debug"}

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 处理日志级别请求
##
## 无 body.level 时查询当前级别，有则设置新级别。
## @param req 请求对象
## @param res 响应对象
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	if not Engine.has_meta("gdapi_plugin"):
		res.error("gdapi plugin not available", "plugin_not_ready", 503)
		return

	var plugin = Engine.get_meta("gdapi_plugin")
	var new_level: String = req.get_body("level", "")

	# 查询当前级别
	if new_level.is_empty():
		res.json({
			"ok": true,
			"level": plugin.LOG_LEVEL_NAMES.get(plugin._log_level, "info"),
		})
		return

	# 设置新级别
	var level_map := {"debug": 0, "info": 1, "warn": 2, "error": 3}
	if not level_map.has(new_level.to_lower()):
		res.error("invalid level: " + new_level + ". Use: debug, info, warn, error", "invalid_param", 400)
		return

	plugin._log_level = level_map[new_level.to_lower()]
	res.json({"ok": true, "level": new_level.to_lower()})
```

- [ ] **Step 2: 验证路由注册**

启动 Godot 编辑器，确认插件加载后 `/log/level` 路由出现在 `/routes` 列表中。

- [ ] **Step 3: Commit**

```bash
git add gdapi/addon/routes/editor/log/level.gd
git commit -m "feat: add /log/level API route for querying and setting log level"
```

---

### Task 5: 端到端验证

**Files:** 无新增/修改

- [ ] **Step 1: 启动 Godot 编辑器并加载插件**

确认控制台输出 `[gdapi] listening on 127.0.0.1:XXXX (N routes)` 且无报错。

- [ ] **Step 2: 查询日志级别**

```bash
curl -X POST http://127.0.0.1:7890/log/level -H "Content-Type: application/json" -d "{}"
```

Expected: `{"ok":true,"level":"info"}`

- [ ] **Step 3: 设置日志级别为 debug**

```bash
curl -X POST http://127.0.0.1:7890/log/level -H "Content-Type: application/json" -d "{\"level\":\"debug\"}"
```

Expected: `{"ok":true,"level":"debug"}`

- [ ] **Step 4: 验证级别已更新**

```bash
curl -X POST http://127.0.0.1:7890/log/level -H "Content-Type: application/json" -d "{}"
```

Expected: `{"ok":true,"level":"debug"}`

- [ ] **Step 5: 触发一次日志记录**

```bash
curl -X POST http://127.0.0.1:7890/editor/project/run -H "Content-Type: application/json" -d "{}"
```

Expected: `{"ok":true,"action":"play_main_scene"}`

- [ ] **Step 6: 获取日志确认记录成功**

```bash
curl -X POST http://127.0.0.1:7890/editor/project/debug_output -H "Content-Type: application/json" -d "{\"since\":0,\"limit\":10}"
```

Expected: 返回包含 `"text":"Started playing main scene"` 的日志条目

- [ ] **Step 7: 验证无效级别参数**

```bash
curl -X POST http://127.0.0.1:7890/log/level -H "Content-Type: application/json" -d "{\"level\":\"invalid\"}"
```

Expected: `{"error":"invalid level: invalid. Use: debug, info, warn, error","code":"invalid_param"}`，HTTP 400
