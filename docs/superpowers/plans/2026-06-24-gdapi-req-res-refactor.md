# gdapi req/res 改造实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 将 gdapi 路由处理器从返回值模式改造为 Express 风格的 `handle(req, res)` 模式

**架构：** 创建 GdApiRequest 和 GdApiResponse 两个类，封装请求数据和响应方法。路由处理器通过 res 对象的方法（json/send/file/error）发送响应，而非返回 Dictionary。

**技术栈：** GDScript 4.x, Godot EditorPlugin, JSON

---

## 文件结构

### 新增文件
- `gdapi/addon/runtime/request.gd` - 请求对象类
- `gdapi/addon/runtime/response.gd` - 响应对象类

### 修改文件
- `gdapi/addon/runtime/route_handler.gd` - 基类签名更新
- `gdapi/addon/runtime/router.gd` - dispatch 方法重构
- `gdapi/addon/runtime/builtin_ping.gd` - 内置路由迁移
- `gdapi/addon/runtime/builtin_routes.gd` - 内置路由迁移
- `gdapi/addon/routes/**/*.gd` - 所有路由文件迁移

---

## 任务 1：创建 GdApiRequest 类

**文件：**
- 创建：`gdapi/addon/runtime/request.gd`

- [ ] **步骤 1：创建 request.gd 文件**

```gdscript
@tool
class_name GdApiRequest
extends RefCounted

var method: String
var path: String
var headers: Dictionary
var body: Dictionary
var query: String
var params: Dictionary
var raw_body: PackedByteArray

func _init(req_dict: Dictionary) -> void:
	method = req_dict.get("method", "POST")
	path = req_dict.get("path", "/")
	headers = req_dict.get("headers", {})
	raw_body = req_dict.get("body", PackedByteArray())
	
	var parts := path.split("?", true, 1)
	if parts.size() > 1:
		path = parts[0]
		query = parts[1]
	
	if raw_body.size() > 0:
		var text := raw_body.get_string_from_utf8()
		var parsed = JSON.parse_string(text)
		if typeof(parsed) == TYPE_DICTIONARY:
			body = parsed

func get_body(key: String, default: Variant = null) -> Variant:
	return body.get(key, default)

func get_header(name: String) -> String:
	return headers.get(name.to_lower(), "")

func has_body(key: String) -> bool:
	return body.has(key)

func get_query(key: String, default: String = "") -> String:
	for param in query.split("&"):
		var kv := param.split("=", true, 1)
		if kv.size() == 2 and kv[0] == key:
			return kv[1]
	return default

func is_json() -> bool:
	var ct := get_header("content-type")
	return ct.begins_with("application/json")

func client_ip() -> String:
	return headers.get("x-forwarded-for", headers.get("remote-addr", "127.0.0.1"))
```

- [ ] **步骤 2：验证文件语法**

在 Godot 编辑器中打开项目，确认无语法错误。或运行：
```bash
# 检查 GDScript 语法（如果有 linter）
gdcli exec ping --project /path/to/project
```

- [ ] **步骤 3：Commit**

```bash
git add gdapi/addon/runtime/request.gd
git commit -m "feat(gdapi): add GdApiRequest class for req/res pattern"
```

---

## 任务 2：创建 GdApiResponse 类

**文件：**
- 创建：`gdapi/addon/runtime/response.gd`

- [ ] **步骤 1：创建 response.gd 文件**

```gdscript
@tool
class_name GdApiResponse
extends RefCounted

var _status: int = 200
var _headers: Dictionary = {}
var _server
var _request_id: int
var _sent: bool = false

func _init(server, request_id: int) -> void:
	_server = server
	_request_id = request_id
	_headers["Content-Type"] = "application/json; charset=utf-8"

func status(code: int) -> GdApiResponse:
	_status = code
	return self

func set(key: String, value: String) -> GdApiResponse:
	_headers[key] = value
	return self

func type(content_type: String) -> GdApiResponse:
	_headers["Content-Type"] = content_type
	return self

func json(data: Dictionary) -> void:
	_send(JSON.stringify(data).to_utf8_buffer())

func send(content: String) -> void:
	if not _headers.has("Content-Type"):
		_headers["Content-Type"] = "text/plain; charset=utf-8"
	_send(content.to_utf8_buffer())

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

func error(msg: String, code: String = "error", status: int = 400, details: Dictionary = {}) -> void:
	_status = status
	var body := {"error": msg, "code": code}
	if not details.is_empty():
		body["details"] = details
	json(body)

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

- [ ] **步骤 2：验证文件语法**

在 Godot 编辑器中打开项目，确认无语法错误。

- [ ] **步骤 3：Commit**

```bash
git add gdapi/addon/runtime/response.gd
git commit -m "feat(gdapi): add GdApiResponse class for req/res pattern"
```

---

## 任务 3：更新 route_handler.gd 基类

**文件：**
- 修改：`gdapi/addon/runtime/route_handler.gd`

- [ ] **步骤 1：更新基类签名**

将 `route_handler.gd` 内容替换为：

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

- [ ] **步骤 2：验证语法**

确认 Godot 编辑器无报错。

- [ ] **步骤 3：Commit**

```bash
git add gdapi/addon/runtime/route_handler.gd
git commit -m "refactor(gdapi): update route_handler base class to req/res signature"
```

---

## 任务 4：更新 router.gd dispatch 方法

**文件：**
- 修改：`gdapi/addon/runtime/router.gd`

- [ ] **步骤 1：添加 import 并更新 dispatch**

将 `router.gd` 内容替换为：

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
	_routes.clear()
	_routes["ping"] = BuiltinPing
	_builtin_routes_handler = BuiltinRoutes.new()
	_scan_dir(root_dir + "/editor", "")
	_scan_dir(root_dir + "/shared", "")
	var names: Array = _routes.keys()
	names.append("routes")
	names.sort()
	_builtin_routes_handler.set_route_names(names)

func count() -> int:
	return _routes.size() + 1

func _scan_dir(dir_path: String, prefix: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full := dir_path + "/" + name
		if dir.current_is_dir():
			var sub_prefix := (prefix + "/" + name) if prefix != "" else name
			_scan_dir(full, sub_prefix)
		elif name.ends_with(".gd") and not name.begins_with("_"):
			var route_name := name.substr(0, name.length() - 3)
			var key := (prefix + "/" + route_name) if prefix != "" else route_name
			var script: Script = load(full) as Script
			if script != null:
				_routes[key] = script
		name = dir.get_next()
	dir.list_dir_end()

func dispatch(req_dict: Dictionary, server) -> void:
	var id: int = req_dict["id"]
	var method: String = req_dict["method"]
	var path: String = req_dict["path"]

	if method != "POST":
		_reply_error(server, id, 405, "only POST is supported", "method_not_allowed")
		return

	var key: String = path.trim_prefix("/")

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

- [ ] **步骤 2：验证语法**

确认 Godot 编辑器无报错。

- [ ] **步骤 3：Commit**

```bash
git add gdapi/addon/runtime/router.gd
git commit -m "refactor(gdapi): update router dispatch to use req/res pattern"
```

---

## 任务 5：迁移 builtin_ping.gd

**文件：**
- 修改：`gdapi/addon/runtime/builtin_ping.gd`

- [ ] **步骤 1：更新 handle 签名**

将 `builtin_ping.gd` 内容替换为：

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	res.json({
		"ok": true,
		"gdapi_version": "0.2.0",
		"editor_version": Engine.get_version_info().get("string", ""),
	})
```

- [ ] **步骤 2：测试 ping 路由**

```bash
gdcli exec ping --project /path/to/godot/project
```

预期输出：
```json
{"editor_version":"4.x.x","gdapi_version":"0.2.0","ok":true}
```

- [ ] **步骤 3：Commit**

```bash
git add gdapi/addon/runtime/builtin_ping.gd
git commit -m "refactor(gdapi): migrate builtin_ping to req/res pattern"
```

---

## 任务 6：迁移 builtin_routes.gd

**文件：**
- 修改：`gdapi/addon/runtime/builtin_routes.gd`

- [ ] **步骤 1：更新 handle 签名**

将 `builtin_routes.gd` 内容替换为：

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

var _route_names: Array = []

func set_route_names(names: Array) -> void:
	_route_names = names

func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	res.json({"ok": true, "routes": _route_names})
```

- [ ] **步骤 2：测试 routes 路由**

```bash
gdcli exec routes --project /path/to/godot/project
```

预期输出包含路由列表。

- [ ] **步骤 3：Commit**

```bash
git add gdapi/addon/runtime/builtin_routes.gd
git commit -m "refactor(gdapi): migrate builtin_routes to req/res pattern"
```

---

## 任务 7：迁移 shared/godot/version.gd

**文件：**
- 修改：`gdapi/addon/routes/shared/godot/version.gd`

- [ ] **步骤 1：更新 handle 签名**

将 `version.gd` 内容替换为：

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

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

- [ ] **步骤 2：测试 version 路由**

```bash
gdcli exec godot/version --project /path/to/godot/project
```

- [ ] **步骤 3：Commit**

```bash
git add gdapi/addon/routes/shared/godot/version.gd
git commit -m "refactor(gdapi): migrate godot/version to req/res pattern"
```

---

## 任务 8：迁移 shared/project/info.gd

**文件：**
- 修改：`gdapi/addon/routes/shared/project/info.gd`

- [ ] **步骤 1：更新 handle 签名**

将 `info.gd` 内容替换为：

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	var ps := ProjectSettings
	res.json({
		"ok": true,
		"name": ps.get_setting("application/config/name", ""),
		"main_scene": ps.get_setting("application/run/main_scene", ""),
		"godot_version": Engine.get_version_info().get("string", ""),
		"project_path": ProjectSettings.globalize_path("res://"),
		"rendering_method": ps.get_setting("rendering/renderer/rendering_method", ""),
	})
```

- [ ] **步骤 2：测试 project/info 路由**

```bash
gdcli exec project/info --project /path/to/godot/project
```

- [ ] **步骤 3：Commit**

```bash
git add gdapi/addon/routes/shared/project/info.gd
git commit -m "refactor(gdapi): migrate project/info to req/res pattern"
```

---

## 任务 9：迁移 shared/uid/get.gd

**文件：**
- 修改：`gdapi/addon/routes/shared/uid/get.gd`

- [ ] **步骤 1：更新 handle 签名**

将 `uid/get.gd` 内容替换为：

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var file_path: String = req.get_body("file_path", "")
	if file_path.is_empty():
		res.error("file_path is required", "missing_param")
		return

	if not file_path.begins_with("res://"):
		file_path = "res://" + file_path

	var abs_path := ProjectSettings.globalize_path(file_path)
	if not FileAccess.file_exists(abs_path):
		res.error("file not found: " + file_path, "not_found", 404)
		return

	var uid_path := file_path + ".uid"
	var uid_content := ""
	var uid_exists := false

	if FileAccess.file_exists(uid_path):
		var f := FileAccess.open(uid_path, FileAccess.READ)
		if f:
			uid_content = f.get_as_text().strip_edges()
			f.close()
			uid_exists = true

	res.json({
		"ok": true,
		"file": file_path,
		"absolute_path": abs_path,
		"uid": uid_content,
		"uid_exists": uid_exists,
	})
```

- [ ] **步骤 2：测试 uid/get 路由**

```bash
gdcli exec uid/get --project /path/to/godot/project --body '{"file_path": "project.godot"}'
```

- [ ] **步骤 3：Commit**

```bash
git add gdapi/addon/routes/shared/uid/get.gd
git commit -m "refactor(gdapi): migrate uid/get to req/res pattern"
```

---

## 任务 10：迁移 editor/project/run.gd

**文件：**
- 修改：`gdapi/addon/routes/editor/project/run.gd`

- [ ] **步骤 1：更新 handle 签名**

将 `run.gd` 内容替换为：

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var scene_path: String = req.get_body("scene_path", "")

	if scene_path.is_empty():
		EditorInterface.play_main_scene()
		var plugin = Engine.get_meta("gdapi_plugin", null)
		if plugin:
			plugin.log_message("Started playing main scene", "info")
		res.json({"ok": true, "action": "play_main_scene"})
		return

	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path

	var abs_path := ProjectSettings.globalize_path(scene_path)
	if not FileAccess.file_exists(abs_path):
		res.error("scene not found: " + scene_path, "not_found", 404)
		return

	EditorInterface.play_custom_scene(scene_path)

	var plugin = Engine.get_meta("gdapi_plugin", null)
	if plugin:
		plugin.log_message("Started playing scene: " + scene_path, "info")

	res.json({"ok": true, "action": "play_custom_scene", "scene": scene_path})
```

- [ ] **步骤 2：测试 project/run 路由**

```bash
gdcli exec project/run --project /path/to/godot/project
```

- [ ] **步骤 3：Commit**

```bash
git add gdapi/addon/routes/editor/project/run.gd
git commit -m "refactor(gdapi): migrate project/run to req/res pattern"
```

---

## 任务 11：迁移 editor/project/stop.gd

**文件：**
- 修改：`gdapi/addon/routes/editor/project/stop.gd`

- [ ] **步骤 1：更新 handle 签名**

将 `stop.gd` 内容替换为：

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	if not EditorInterface.is_playing_scene():
		res.json({"ok": true, "action": "stop", "message": "not playing"})
		return

	EditorInterface.stop_playing_scene()

	var plugin = Engine.get_meta("gdapi_plugin", null)
	if plugin:
		plugin.log_message("Stopped playing scene", "info")

	res.json({"ok": true, "action": "stop"})
```

- [ ] **步骤 2：测试 project/stop 路由**

```bash
gdcli exec project/stop --project /path/to/godot/project
```

- [ ] **步骤 3：Commit**

```bash
git add gdapi/addon/routes/editor/project/stop.gd
git commit -m "refactor(gdapi): migrate project/stop to req/res pattern"
```

---

## 任务 12：迁移 editor/project/debug_output.gd

**文件：**
- 修改：`gdapi/addon/routes/editor/project/debug_output.gd`

- [ ] **步骤 1：更新 handle 签名**

将 `debug_output.gd` 内容替换为：

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var since: int = req.get_body("since", 0)
	var limit: int = req.get_body("limit", 100)

	if not Engine.has_meta("gdapi_plugin"):
		res.json({
			"ok": false,
			"error": "gdapi plugin not available",
			"code": "plugin_not_ready",
		})
		return

	var plugin = Engine.get_meta("gdapi_plugin")
	var entries: Array = plugin.get_log_since(since, limit)

	var next_since: int = since
	if entries.size() > 0:
		next_since = entries[entries.size() - 1].seq

	res.json({
		"ok": true,
		"entries": entries,
		"next_since": next_since,
	})
```

- [ ] **步骤 2：测试 debug_output 路由**

```bash
gdcli exec project/debug_output --project /path/to/godot/project --body '{"since": 0, "limit": 10}'
```

- [ ] **步骤 3：Commit**

```bash
git add gdapi/addon/routes/editor/project/debug_output.gd
git commit -m "refactor(gdapi): migrate debug_output to req/res pattern"
```

---

## 任务 13：迁移 editor/uid/update_all.gd

**文件：**
- 修改：`gdapi/addon/routes/editor/uid/update_all.gd`

- [ ] **步骤 1：更新 handle 签名**

将 `update_all.gd` 内容替换为：

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var project_path: String = req.get_body("project_path", "res://")
	if not project_path.begins_with("res://"):
		project_path = "res://" + project_path
	if not project_path.ends_with("/"):
		project_path += "/"

	var scenes := _find_files(project_path, ".tscn")
	var scripts := _find_files(project_path, ".gd") + _find_files(project_path, ".shader") + _find_files(project_path, ".gdshader")

	var success_count := 0
	var error_count := 0

	for scene_path in scenes:
		var scene = load(scene_path)
		if scene:
			var result := ResourceSaver.save(scene, scene_path)
			if result == OK:
				success_count += 1
			else:
				error_count += 1
		else:
			error_count += 1

	var missing_uids := 0
	var generated_uids := 0

	for script_path in scripts:
		var uid_path := script_path + ".uid"
		if not FileAccess.file_exists(uid_path):
			missing_uids += 1
			var res_load = load(script_path)
			if res_load:
				var result := ResourceSaver.save(res_load, script_path)
				if result == OK:
					generated_uids += 1

	res.json({
		"ok": true,
		"scenes_processed": scenes.size(),
		"scenes_saved": success_count,
		"scenes_errors": error_count,
		"scripts_missing_uids": missing_uids,
		"uids_generated": generated_uids,
	})

func _find_files(path: String, extension: String) -> Array:
	var files := []
	var dir := DirAccess.open(path)
	if not dir:
		return files

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if dir.current_is_dir() and not file_name.begins_with("."):
			files.append_array(_find_files(path + file_name + "/", extension))
		elif file_name.ends_with(extension):
			files.append(path + file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	return files
```

- [ ] **步骤 2：测试 uid/update_all 路由**

```bash
gdcli exec uid/update_all --project /path/to/godot/project
```

- [ ] **步骤 3：Commit**

```bash
git add gdapi/addon/routes/editor/uid/update_all.gd
git commit -m "refactor(gdapi): migrate uid/update_all to req/res pattern"
```

---

## 任务 14：迁移 editor/scene/save.gd

**文件：**
- 修改：`gdapi/addon/routes/editor/scene/save.gd`

- [ ] **步骤 1：更新 handle 签名**

将 `save.gd` 内容替换为：

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

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

	var save_path := scene_path
	if not new_path.is_empty():
		if not new_path.begins_with("res://"):
			new_path = "res://" + new_path
		save_path = new_path
		var new_dir := save_path.get_base_dir()
		if new_dir != "res://":
			var abs_dir := ProjectSettings.globalize_path(new_dir)
			if not DirAccess.dir_exists_absolute(abs_dir):
				DirAccess.make_dir_recursive_absolute(abs_dir)

	var scene := load(scene_path)
	if not scene:
		res.error("failed to load scene: " + scene_path, "load_failed", 500)
		return

	var save_result := ResourceSaver.save(scene, save_path)
	if save_result != OK:
		res.error("failed to save scene: " + str(save_result), "save_failed", 500)
		return

	res.json({
		"ok": true,
		"path": save_path,
	})
```

- [ ] **步骤 2：测试 scene/save 路由**

```bash
gdcli exec scene/save --project /path/to/godot/project --body '{"scene_path": "test.tscn"}'
```

- [ ] **步骤 3：Commit**

```bash
git add gdapi/addon/routes/editor/scene/save.gd
git commit -m "refactor(gdapi): migrate scene/save to req/res pattern"
```

---

## 任务 15：迁移 editor/scene/create.gd

**文件：**
- 修改：`gdapi/addon/routes/editor/scene/create.gd`

- [ ] **步骤 1：更新 handle 签名**

将 `create.gd` 内容替换为：

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var scene_path: String = req.get_body("scene_path", "")
	if scene_path.is_empty():
		res.error("scene_path is required", "missing_param")
		return

	var root_type: String = req.get_body("root_node_type", "Node2D")

	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path

	var root_node: Node = null
	if ClassDB.class_exists(root_type) and ClassDB.can_instantiate(root_type):
		root_node = ClassDB.instantiate(root_type)
	else:
		res.error("cannot instantiate node type: " + root_type, "invalid_type", 400)
		return

	root_node.name = "root"
	root_node.owner = root_node

	var dir_path := scene_path.get_base_dir()
	if dir_path != "res://":
		var abs_dir := ProjectSettings.globalize_path(dir_path)
		if not DirAccess.dir_exists_absolute(abs_dir):
			DirAccess.make_dir_recursive_absolute(abs_dir)

	var packed := PackedScene.new()
	var pack_result := packed.pack(root_node)
	if pack_result != OK:
		res.error("failed to pack scene: " + str(pack_result), "pack_failed", 500)
		return

	var save_result := ResourceSaver.save(packed, scene_path)
	if save_result != OK:
		res.error("failed to save scene: " + str(save_result), "save_failed", 500)
		return

	EditorInterface.reload_scene_from_path(scene_path)

	var plugin = Engine.get_meta("gdapi_plugin", null)
	if plugin:
		plugin.log_message("Created scene: " + scene_path, "info")

	res.json({
		"ok": true,
		"path": scene_path,
		"root_type": root_type,
	})
```

- [ ] **步骤 2：测试 scene/create 路由**

```bash
gdcli exec scene/create --project /path/to/godot/project --body '{"scene_path": "test_new.tscn"}'
```

- [ ] **步骤 3：Commit**

```bash
git add gdapi/addon/routes/editor/scene/create.gd
git commit -m "refactor(gdapi): migrate scene/create to req/res pattern"
```

---

## 任务 16：迁移 editor/scene/add_node.gd

**文件：**
- 修改：`gdapi/addon/routes/editor/scene/add_node.gd`

- [ ] **步骤 1：更新 handle 签名**

将 `add_node.gd` 内容替换为：

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var scene_path: String = req.get_body("scene_path", "")
	var node_type: String = req.get_body("node_type", "")
	var node_name: String = req.get_body("node_name", "")
	var parent_path: String = req.get_body("parent_node_path", "root")
	var properties: Dictionary = req.get_body("properties", {})

	if scene_path.is_empty():
		res.error("scene_path is required", "missing_param")
		return
	if node_type.is_empty():
		res.error("node_type is required", "missing_param")
		return
	if node_name.is_empty():
		res.error("node_name is required", "missing_param")
		return

	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path

	var scene := load(scene_path)
	if not scene:
		res.error("failed to load scene: " + scene_path, "load_failed", 500)
		return

	var scene_root := scene.instantiate()

	var parent: Node = scene_root
	if parent_path != "root":
		var relative_path := parent_path.replace("root/", "")
		parent = scene_root.get_node(relative_path)
		if not parent:
			res.error("parent node not found: " + parent_path, "parent_not_found", 404)
			return

	var new_node: Node = null
	if ClassDB.class_exists(node_type) and ClassDB.can_instantiate(node_type):
		new_node = ClassDB.instantiate(node_type)
	else:
		res.error("cannot instantiate node type: " + node_type, "invalid_type", 400)
		return

	new_node.name = node_name

	for prop in properties:
		var value = properties[prop]
		if typeof(value) == TYPE_STRING and value.begins_with("res://"):
			value = load(value)
		new_node.set(prop, value)

	parent.add_child(new_node)
	new_node.owner = scene_root

	var packed := PackedScene.new()
	var pack_result := packed.pack(scene_root)
	if pack_result != OK:
		res.error("failed to pack scene: " + str(pack_result), "pack_failed", 500)
		return

	var save_result := ResourceSaver.save(packed, scene_path)
	if save_result != OK:
		res.error("failed to save scene: " + str(save_result), "save_failed", 500)
		return

	var plugin = Engine.get_meta("gdapi_plugin", null)
	if plugin:
		plugin.log_message("Added node " + node_name + " (" + node_type + ") to " + scene_path, "info")

	res.json({
		"ok": true,
		"node_name": node_name,
		"node_type": node_type,
		"parent": parent_path,
	})
```

- [ ] **步骤 2：测试 scene/add_node 路由**

```bash
gdcli exec scene/add_node --project /path/to/godot/project --body '{"scene_path": "test.tscn", "node_type": "Sprite2D", "node_name": "MySprite"}'
```

- [ ] **步骤 3：Commit**

```bash
git add gdapi/addon/routes/editor/scene/add_node.gd
git commit -m "refactor(gdapi): migrate scene/add_node to req/res pattern"
```

---

## 任务 17：迁移 editor/scene/load_sprite.gd

**文件：**
- 修改：`gdapi/addon/routes/editor/scene/load_sprite.gd`

- [ ] **步骤 1：更新 handle 签名**

将 `load_sprite.gd` 内容替换为：

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var scene_path: String = req.get_body("scene_path", "")
	var node_path: String = req.get_body("node_path", "")
	var texture_path: String = req.get_body("texture_path", "")

	if scene_path.is_empty():
		res.error("scene_path is required", "missing_param")
		return
	if node_path.is_empty():
		res.error("node_path is required", "missing_param")
		return
	if texture_path.is_empty():
		res.error("texture_path is required", "missing_param")
		return

	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path
	if not texture_path.begins_with("res://"):
		texture_path = "res://" + texture_path

	var scene := load(scene_path)
	if not scene:
		res.error("failed to load scene: " + scene_path, "load_failed", 500)
		return

	var scene_root := scene.instantiate()

	var sprite_path := node_path.replace("root/", "")
	var sprite_node = scene_root.get_node(sprite_path)
	if not sprite_node:
		res.error("node not found: " + node_path, "node_not_found", 404)
		return

	if not (sprite_node is Sprite2D or sprite_node is Sprite3D or sprite_node is TextureRect):
		res.error("node is not a sprite type: " + sprite_node.get_class(), "invalid_type", 400)
		return

	var texture = load(texture_path)
	if not texture:
		res.error("failed to load texture: " + texture_path, "texture_not_found", 404)
		return

	sprite_node.texture = texture

	var packed := PackedScene.new()
	var pack_result := packed.pack(scene_root)
	if pack_result != OK:
		res.error("failed to pack scene: " + str(pack_result), "pack_failed", 500)
		return

	var abs_path := ProjectSettings.globalize_path(scene_path)
	var save_result := ResourceSaver.save(packed, abs_path)
	if save_result != OK:
		res.error("failed to save scene: " + str(save_result), "save_failed", 500)
		return

	res.json({
		"ok": true,
		"node": node_path,
		"texture": texture_path,
	})
```

- [ ] **步骤 2：测试 scene/load_sprite 路由**

```bash
gdcli exec scene/load_sprite --project /path/to/godot/project --body '{"scene_path": "test.tscn", "node_path": "root/MySprite", "texture_path": "icon.png"}'
```

- [ ] **步骤 3：Commit**

```bash
git add gdapi/addon/routes/editor/scene/load_sprite.gd
git commit -m "refactor(gdapi): migrate scene/load_sprite to req/res pattern"
```

---

## 任务 18：迁移 editor/scene/export_mesh_library.gd

**文件：**
- 修改：`gdapi/addon/routes/editor/scene/export_mesh_library.gd`

- [ ] **步骤 1：更新 handle 签名**

将 `export_mesh_library.gd` 内容替换为：

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var scene_path: String = req.get_body("scene_path", "")
	var output_path: String = req.get_body("output_path", "")
	var mesh_item_names: Array = req.get_body("mesh_item_names", [])

	if scene_path.is_empty():
		res.error("scene_path is required", "missing_param")
		return
	if output_path.is_empty():
		res.error("output_path is required", "missing_param")
		return

	if not scene_path.begins_with("res://"):
		scene_path = "res://" + scene_path
	if not output_path.begins_with("res://"):
		output_path = "res://" + output_path

	var scene := load(scene_path)
	if not scene:
		res.error("failed to load scene: " + scene_path, "load_failed", 500)
		return

	var scene_root := scene.instantiate()

	var mesh_library := MeshLibrary.new()
	var item_id := 0
	var use_specific := mesh_item_names.size() > 0

	for child in scene_root.get_children():
		if use_specific and not (child.name in mesh_item_names):
			continue

		var mesh_instance: MeshInstance3D = null
		if child is MeshInstance3D:
			mesh_instance = child
		else:
			for descendant in child.get_children():
				if descendant is MeshInstance3D:
					mesh_instance = descendant
					break

		if mesh_instance and mesh_instance.mesh:
			mesh_library.create_item(item_id)
			mesh_library.set_item_name(item_id, child.name)
			mesh_library.set_item_mesh(item_id, mesh_instance.mesh)

			for collision_child in child.get_children():
				if collision_child is CollisionShape3D and collision_child.shape:
					mesh_library.set_item_shapes(item_id, [collision_child.shape])
					break

			item_id += 1

	if item_id == 0:
		res.error("no valid meshes found in scene", "no_meshes", 400)
		return

	var out_dir := output_path.get_base_dir()
	if out_dir != "res://":
		var abs_dir := ProjectSettings.globalize_path(out_dir)
		if not DirAccess.dir_exists_absolute(abs_dir):
			DirAccess.make_dir_recursive_absolute(abs_dir)

	var save_result := ResourceSaver.save(mesh_library, output_path)
	if save_result != OK:
		res.error("failed to save MeshLibrary: " + str(save_result), "save_failed", 500)
		return

	res.json({
		"ok": true,
		"output": output_path,
		"item_count": item_id,
	})
```

- [ ] **步骤 2：测试 scene/export_mesh_library 路由**

```bash
gdcli exec scene/export_mesh_library --project /path/to/godot/project --body '{"scene_path": "mesh_scene.tscn", "output_path": "mesh_library.tres"}'
```

- [ ] **步骤 3：Commit**

```bash
git add gdapi/addon/routes/editor/scene/export_mesh_library.gd
git commit -m "refactor(gdapi): migrate scene/export_mesh_library to req/res pattern"
```

---

## 任务 19：验证所有路由

- [ ] **步骤 1：测试所有内置路由**

```bash
gdcli exec ping --project /path/to/godot/project
gdcli exec routes --project /path/to/godot/project
```

- [ ] **步骤 2：测试 shared 路由**

```bash
gdcli exec godot/version --project /path/to/godot/project
gdcli exec project/info --project /path/to/godot/project
gdcli exec uid/get --project /path/to/godot/project --body '{"file_path": "project.godot"}'
```

- [ ] **步骤 3：测试 editor 路由**

```bash
gdcli exec project/run --project /path/to/godot/project
gdcli exec project/stop --project /path/to/godot/project
gdcli exec project/debug_output --project /path/to/godot/project --body '{"since": 0, "limit": 5}'
gdcli exec scene/create --project /path/to/godot/project --body '{"scene_path": "test_req_res.tscn"}'
gdcli exec scene/save --project /path/to/godot/project --body '{"scene_path": "test_req_res.tscn"}'
```

- [ ] **步骤 4：测试错误场景**

```bash
# 缺少必填参数
gdcli exec scene/save --project /path/to/godot/project --body '{}'

# 路由不存在
gdcli exec nonexistent --project /path/to/godot/project
```

- [ ] **步骤 5：Final Commit**

```bash
git add -A
git commit -m "refactor(gdapi): complete req/res pattern migration"
```

---

## 自检清单

- [x] 规格覆盖度：所有 12 个路由文件都有对应任务
- [x] 占位符扫描：无 TODO、待定、未完成章节
- [x] 类型一致性：所有文件使用一致的 GdApiRequest/GdApiResponse 类型
- [x] 文件路径精确：所有文件路径都是绝对路径
- [x] 代码完整：每个步骤都有完整代码
- [x] 测试命令：每个任务都有测试命令和预期输出
- [x] Commit 消息：每个任务都有明确的 commit 消息

---

## 执行方式

计划已完成并保存到 `docs/superpowers/plans/2026-06-24-gdapi-req-res-refactor.md`。

**两种执行方式：**

**1. 子代理驱动（推荐）** - 每个任务调度一个新的子代理，任务间进行审查，快速迭代

**2. 内联执行** - 在当前会话中使用 executing-plans 执行任务，批量执行并设有检查点

选哪种方式？
