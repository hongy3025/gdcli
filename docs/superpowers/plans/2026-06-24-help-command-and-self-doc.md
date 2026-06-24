# gdcli exec help 命令与 gdapi 自文档机制 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 gdcli 增加 `exec help [<path>]` 命令，并在 gdapi runtime 中引入基于 `doc()` 方法的自文档机制，让每个 route handler 自行输出帮助文档。

**Architecture:** runtime 端新增两个 doc 数据类（`GdApiRouteDoc` / `GdApiParamDoc`）和一个内置路由（`builtin_help.gd`），通过 `route_handler.gd` 的默认 `doc()` 方法实现非破坏性扩展；router 在 scan 完成后把全路由表注入给 BuiltinHelp。CLI 端在 `exec` 子命令上新增可选位置参数 `args: Vec<String>`，help 命令把第一个位置参数包成 `{"path": "..."}` body 发送，其他命令保持位置参数为空。CLI 不做任何渲染，直接打印服务端 JSON。

**Tech Stack:** GDScript 4 (gdapi runtime), Rust (CLI: clap 4, serde_json, ureq, anyhow), httpmock + assert_cmd（集成测试）。

## Global Constraints

- Spec 文件：`docs/superpowers/specs/2026-06-24-help-command-design.md`
- GDScript 文件必须以制表符缩进（参考 `gdapi/addon/runtime/request.gd`）
- 所有新 GDScript 类用 `@tool` + `class_name` + 中文 doc-comment（`##`），跟随现有风格
- 每个新 `.gd` 必须同时生成 `.gd.uid` 文件 —— Godot 编辑器首次打开会自动生成；本计划中需在最后手工运行一次 Godot 让 UID 落盘后提交
- `route_handler.gd` 的 `doc()` 默认实现必须**非破坏性**：未重载的 route 仍能正常工作，只是 help 列表中 summary 为空
- CLI 必须**完全不做渲染**，help 命令直接 `print!` 服务端 JSON 原文（与现有 exec 行为一致）
- CLI 退出码约定不变：0=成功，1=5xx，2=4xx/客户端错误，3=网络/超时/meta 缺失
- 非 help 命令传位置参数必须报错退出 2（避免静默忽略）
- help 命令同时传 `--data` 必须报错退出 2
- JSON body 构造必须用 `serde_json::json!` 宏，禁止字符串拼接（防止 path 含引号注入）
- 现有 11 个 route handler 在本计划中**不被批量重载** `doc()`，留作后续任务

---

## File Structure

**新增 GDScript 文件：**
- `gdapi/addon/runtime/param_doc.gd` — `GdApiParamDoc` 单参数文档类
- `gdapi/addon/runtime/route_doc.gd` — `GdApiRouteDoc` 路由文档类（fluent builder）
- `gdapi/addon/runtime/builtin_help.gd` — `/help` 路由处理器

**修改 GDScript 文件：**
- `gdapi/addon/runtime/route_handler.gd` — 增加默认 `doc()` 实现
- `gdapi/addon/runtime/router.gd` — 注册 `/help`、注入路由表给 BuiltinHelp、`count()` 调整、名单中加入 `"help"`
- `gdapi/addon/runtime/builtin_ping.gd` — 重载 `doc()`（演示用）
- `gdapi/addon/runtime/builtin_routes.gd` — 重载 `doc()`

**新增 GDScript 测试：**
- `tests/fixture_project/tests/test_route_doc.gd` — RouteDoc / ParamDoc 单元测试

**修改 Rust 文件：**
- `cli/src/main.rs` — `Cmd::Exec` 增加 `args: Vec<String>`，调用 `exec::run` 时透传
- `cli/src/exec.rs` — `run()` 签名加 `args`，抽出 `build_body(command, args, data)` 便于单测，help 命令特殊处理

**修改测试：**
- `cli/tests/exec_integration.rs` — 新增 help 命令集成测试

---

## Task 1: 新增 GdApiParamDoc 数据类

**Files:**
- Create: `gdapi/addon/runtime/param_doc.gd`

**Interfaces:**
- Produces: `class_name GdApiParamDoc`，公开字段 `name: String`, `type: String`, `required: bool`, `description: String`, `default: Variant`；方法 `to_dict() -> Dictionary` 返回 5 字段字典。

- [ ] **Step 1: 创建 `gdapi/addon/runtime/param_doc.gd`**

写入以下内容（**注意必须使用制表符缩进**）：

```gdscript
## 路由单个参数的文档描述
##
## 由 GdApiRouteDoc.param() 构造，一般不直接实例化。
## 用于在 /help 接口序列化为 JSON 返回给客户端。

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
##
## @return 包含 name/type/required/description/default 五个字段的字典
func to_dict() -> Dictionary:
	return {
		"name": name,
		"type": type,
		"required": required,
		"description": description,
		"default": default,
	}
```

- [ ] **Step 2: 提交**

```bash
git add gdapi/addon/runtime/param_doc.gd
git commit -m "feat(gdapi): add GdApiParamDoc data class"
```

---

## Task 2: 新增 GdApiRouteDoc 数据类（带 fluent builder）

**Files:**
- Create: `gdapi/addon/runtime/route_doc.gd`

**Interfaces:**
- Consumes: `GdApiParamDoc`（从 Task 1）
- Produces: `class_name GdApiRouteDoc`；静态工厂 `make(summary: String) -> GdApiRouteDoc`；fluent 方法 `desc(text)`, `param(name, type, required, description, default=null)`, `returns(desc, fields={})`, `example(json)` 均返回 self；序列化方法 `to_dict() -> Dictionary`（完整详情）和 `to_summary_dict() -> Dictionary`（列表用，仅含 summary + params 名/required）。

- [ ] **Step 1: 创建 `gdapi/addon/runtime/route_doc.gd`**

写入以下内容（**注意制表符缩进**）：

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
##
## @param summary_ 一句话功能描述
## @return 新建的 GdApiRouteDoc 实例
static func make(summary_: String) -> GdApiRouteDoc:
	var d := GdApiRouteDoc.new()
	d.summary = summary_
	return d

## 设置详细描述（fluent）
##
## @param text 多行说明
## @return self 以便链式调用
func desc(text: String) -> GdApiRouteDoc:
	description = text
	return self

## 添加一个参数（fluent）
##
## @param name_ 参数名
## @param type_ 类型字符串
## @param required_ 是否必填
## @param description_ 参数说明
## @param default_ 默认值（null 表示无默认值）
## @return self 以便链式调用
func param(name_: String, type_: String, required_: bool, description_: String, default_ = null) -> GdApiRouteDoc:
	var p := ParamDoc.new()
	p.name = name_
	p.type = type_
	p.required = required_
	p.description = description_
	p.default = default_
	params.append(p)
	return self

## 设置返回值描述与字段（fluent）
##
## @param desc_ 返回值整体说明
## @param fields_ 字段字典，键为字段名，值为类型+说明字符串
## @return self 以便链式调用
func returns(desc_: String, fields_: Dictionary = {}) -> GdApiRouteDoc:
	returns_desc = desc_
	returns_fields = fields_
	return self

## 添加一个 JSON 请求示例（fluent）
##
## @param json JSON 字符串形式的请求体示例
## @return self 以便链式调用
func example(json: String) -> GdApiRouteDoc:
	examples.append(json)
	return self

## 完整序列化（详情视图）
##
## @return 含 summary/description/params/returns/examples 的字典
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
##
## @return 仅含 summary 与 params:[{name, required}] 的字典
func to_summary_dict() -> Dictionary:
	var param_summary: Array = []
	for p in params:
		param_summary.append({"name": p.name, "required": p.required})
	return {
		"summary": summary,
		"params": param_summary,
	}
```

- [ ] **Step 2: 提交**

```bash
git add gdapi/addon/runtime/route_doc.gd
git commit -m "feat(gdapi): add GdApiRouteDoc with fluent builder"
```

---

## Task 3: 为 RouteDoc/ParamDoc 编写 GDScript 单元测试

**Files:**
- Create: `tests/fixture_project/tests/test_route_doc.gd`

**Interfaces:**
- Consumes: `GdApiRouteDoc`, `GdApiParamDoc`（从 Task 1、2）

**说明：** 沿用 `tests/fixture_project/tests/test_request.gd` 的 SceneTree 自检风格（手动 `assert_eq` + 计数 + `quit(code)`）。此测试在 Godot 编辑器中通过 `godot --script` 运行；不强制 CI 自动跑（与 test_request.gd 同等地位）。

- [ ] **Step 1: 创建测试文件 `tests/fixture_project/tests/test_route_doc.gd`**

写入以下内容（制表符缩进）：

```gdscript
## GdApiRouteDoc / GdApiParamDoc 单元测试
##
## 覆盖：
## - ParamDoc.to_dict() 五字段完整性与 null 默认值
## - RouteDoc 静态工厂 make()
## - fluent builder 链式调用（desc/param/returns/example）
## - to_dict() 完整详情序列化
## - to_summary_dict() 简要序列化
##
## 运行方式：godot --headless --path tests/fixture_project --script res://tests/test_route_doc.gd

@tool
extends SceneTree

var RouteDoc = preload("res://addons/gdapi/runtime/route_doc.gd")
var ParamDoc = preload("res://addons/gdapi/runtime/param_doc.gd")

var passed := 0
var failed := 0

func _init() -> void:
	print("Running GdApiRouteDoc tests...\n")

	test_param_doc_to_dict()
	test_param_doc_default_null()
	test_route_doc_make_sets_summary()
	test_route_doc_desc_fluent()
	test_route_doc_param_fluent()
	test_route_doc_returns_fluent()
	test_route_doc_example_fluent()
	test_route_doc_to_dict_complete()
	test_route_doc_to_summary_dict_minimal()
	test_route_doc_chained_call()

	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	if failed > 0:
		quit(1)
	else:
		quit(0)

func assert_eq(actual, expected, context: String = "") -> void:
	if actual == expected:
		passed += 1
		print("  PASS: %s" % context)
	else:
		failed += 1
		print("  FAIL: %s - expected '%s', got '%s'" % [context, expected, actual])

func assert_true(value: bool, context: String = "") -> void:
	assert_eq(value, true, context)

func assert_null(value, context: String = "") -> void:
	if value == null:
		passed += 1
		print("  PASS: %s" % context)
	else:
		failed += 1
		print("  FAIL: %s - expected null, got '%s'" % [context, value])

func test_param_doc_to_dict() -> void:
	var p := ParamDoc.new()
	p.name = "scene_path"
	p.type = "String"
	p.required = true
	p.description = "scene path"
	p.default = ""
	var d := p.to_dict()
	assert_eq(d.get("name"), "scene_path", "param name")
	assert_eq(d.get("type"), "String", "param type")
	assert_eq(d.get("required"), true, "param required")
	assert_eq(d.get("description"), "scene path", "param description")
	assert_eq(d.get("default"), "", "param default empty string")

func test_param_doc_default_null() -> void:
	var p := ParamDoc.new()
	var d := p.to_dict()
	assert_null(d.get("default"), "param default null by default")

func test_route_doc_make_sets_summary() -> void:
	var rd := RouteDoc.make("hello")
	assert_eq(rd.summary, "hello", "make sets summary")
	assert_eq(rd.description, "", "make leaves description empty")
	assert_eq(rd.params.size(), 0, "make leaves params empty")

func test_route_doc_desc_fluent() -> void:
	var rd := RouteDoc.make("s")
	var ret = rd.desc("multi-line")
	assert_true(ret == rd, "desc returns self")
	assert_eq(rd.description, "multi-line", "desc sets description")

func test_route_doc_param_fluent() -> void:
	var rd := RouteDoc.make("s")
	var ret = rd.param("a", "String", true, "desc-a")
	assert_true(ret == rd, "param returns self")
	assert_eq(rd.params.size(), 1, "param appends to params")
	assert_eq(rd.params[0].name, "a", "first param name")
	assert_eq(rd.params[0].required, true, "first param required")
	assert_null(rd.params[0].default, "first param default null when omitted")

func test_route_doc_returns_fluent() -> void:
	var rd := RouteDoc.make("s")
	var ret = rd.returns("returns desc", {"ok": "bool"})
	assert_true(ret == rd, "returns returns self")
	assert_eq(rd.returns_desc, "returns desc", "returns_desc set")
	assert_eq(rd.returns_fields.get("ok"), "bool", "returns_fields set")

func test_route_doc_example_fluent() -> void:
	var rd := RouteDoc.make("s")
	var ret = rd.example('{"x":1}')
	assert_true(ret == rd, "example returns self")
	assert_eq(rd.examples.size(), 1, "example appended")
	assert_eq(rd.examples[0], '{"x":1}', "example content")

func test_route_doc_to_dict_complete() -> void:
	var rd := RouteDoc.make("save scene") \
		.desc("save to disk") \
		.param("scene_path", "String", true, "path") \
		.param("new_path", "String", false, "alt path", "") \
		.returns("save result", {"ok": "bool", "path": "String"}) \
		.example('{"scene_path":"res://a.tscn"}')
	var d := rd.to_dict()
	assert_eq(d.get("summary"), "save scene", "dict summary")
	assert_eq(d.get("description"), "save to disk", "dict description")
	assert_eq(d.get("params").size(), 2, "dict params length")
	assert_eq(d.get("params")[0].get("name"), "scene_path", "dict first param name")
	assert_eq(d.get("params")[1].get("default"), "", "dict second param default")
	assert_eq(d.get("returns").get("description"), "save result", "dict returns.description")
	assert_eq(d.get("returns").get("fields").get("path"), "String", "dict returns.fields.path")
	assert_eq(d.get("examples").size(), 1, "dict examples length")

func test_route_doc_to_summary_dict_minimal() -> void:
	var rd := RouteDoc.make("s") \
		.desc("long desc") \
		.param("a", "String", true, "desc-a") \
		.param("b", "int", false, "desc-b", 0) \
		.returns("r")
	var d := rd.to_summary_dict()
	assert_eq(d.get("summary"), "s", "summary present")
	assert_eq(d.has("description"), false, "summary dict has no description")
	assert_eq(d.has("returns"), false, "summary dict has no returns")
	assert_eq(d.get("params").size(), 2, "summary params length")
	assert_eq(d.get("params")[0].get("name"), "a", "summary first param name")
	assert_eq(d.get("params")[0].get("required"), true, "summary first param required")
	assert_eq(d.get("params")[1].get("required"), false, "summary second param required")
	assert_eq(d.get("params")[0].has("type"), false, "summary params have no type")

func test_route_doc_chained_call() -> void:
	# 不破坏 fluent 链
	var rd = RouteDoc.make("x").desc("y").param("p", "int", true, "d").returns("ok")
	assert_eq(rd.summary, "x", "chained summary")
	assert_eq(rd.description, "y", "chained description")
	assert_eq(rd.params.size(), 1, "chained param count")
	assert_eq(rd.returns_desc, "ok", "chained returns_desc")
```

- [ ] **Step 2: 手动运行测试验证通过**

如果本机已有 Godot，运行：

```powershell
godot --headless --path tests/fixture_project --script res://tests/test_route_doc.gd
```

Expected: 最后一行 `=== Results: N passed, 0 failed ===` 且退出码 0。

若本机无 Godot，跳过本步骤，但必须在 Task 8 e2e 阶段再次运行。

- [ ] **Step 3: 提交**

```bash
git add tests/fixture_project/tests/test_route_doc.gd
git commit -m "test(gdapi): add unit tests for GdApiRouteDoc and GdApiParamDoc"
```

---

## Task 4: route_handler.gd 增加默认 doc() 实现

**Files:**
- Modify: `gdapi/addon/runtime/route_handler.gd`

**Interfaces:**
- Consumes: `GdApiRouteDoc`（从 Task 2）
- Produces: `func doc() -> GdApiRouteDoc` 默认返回空文档（summary 为空），子类可选重载

- [ ] **Step 1: 修改 `gdapi/addon/runtime/route_handler.gd`**

在文件末尾（`handle` 方法之后）追加：

```gdscript

## 路由帮助文档预加载（供 doc() 默认实现使用）
const _RouteDoc := preload("res://addons/gdapi/runtime/route_doc.gd")

## 返回该路由的帮助文档
##
## 子类可选重载：未重载时返回 summary 为空的占位文档，路由仍可正常工作，
## 仅在 /help 列表中显示为空描述。
##
## @return GdApiRouteDoc 实例
func doc() -> _RouteDoc:
	return _RouteDoc.make("")
```

**注意**：使用 `_RouteDoc` 私有常量名是为了避免与子类自定义的常量冲突；子类如果要构造 RouteDoc，可以直接用 `GdApiRouteDoc.make(...)`（class_name 全局可用）。

- [ ] **Step 2: 提交**

```bash
git add gdapi/addon/runtime/route_handler.gd
git commit -m "feat(gdapi): add default doc() to GdApiRouteHandler base class"
```

---

## Task 5: 新增 builtin_help.gd 内置路由

**Files:**
- Create: `gdapi/addon/runtime/builtin_help.gd`

**Interfaces:**
- Consumes: `GdApiRouteDoc`, `GdApiRequest`, `GdApiResponse`, `GdApiRouteHandler` 基类
- Produces: 
  - 类（无 class_name，靠 path 引用）：`extends "res://addons/gdapi/runtime/route_handler.gd"`
  - `func set_routes(routes: Dictionary) -> void` — 由 router 注入完整路由表 `{path: handler_script}`
  - `func handle(req, res) -> void` — 实现 /help 路由协议
  - `func doc() -> GdApiRouteDoc` — 自身的文档

- [ ] **Step 1: 创建 `gdapi/addon/runtime/builtin_help.gd`**

写入以下内容（制表符缩进）：

```gdscript
## 内置帮助路由
##
## POST /help            → 返回所有路由的简要列表（path + summary + params 名/required）
## POST /help {path:"x"} → 返回路由 x 的完整帮助文档
##
## 路由表由 router.scan() 完成后调用 set_routes() 注入。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 完整路由表：{ path: handler_script }，由 router 注入
var _routes: Dictionary = {}

## 由 router 在扫描完成后调用，传入完整路由表（含 ping/routes/help 等内置项）
##
## @param routes 路由表字典
func set_routes(routes: Dictionary) -> void:
	_routes = routes

## 处理 /help 请求
##
## 无 body.path → 返回列表；带 body.path → 返回该路由的完整文档；
## 路径不存在 → 404 not_found。
##
## @param req 请求对象
## @param res 响应对象
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

## 构建路由简要列表
##
## 对每个注册路由实例化 handler，调用 doc().to_summary_dict() 并补上 path 字段。
## 路由按字母序排序。
##
## @return 排序后的简要路由信息数组
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

## 自身的帮助文档
##
## @return GdApiRouteDoc 描述 /help 路由的语义
func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("列出可用路由或查询单个路由的帮助文档") \
		.desc("不带 path 参数返回所有路由的简要列表；带 path 参数返回该路由的完整文档") \
		.param("path", "String", false, "要查询的路由路径，留空返回全部路由列表", "") \
		.returns("列表模式返回 routes 数组；详情模式返回 doc 对象", {
			"ok": "bool, 是否成功",
			"routes": "Array, 仅列表模式存在",
			"doc": "Dictionary, 仅详情模式存在",
		})
```

- [ ] **Step 2: 提交**

```bash
git add gdapi/addon/runtime/builtin_help.gd
git commit -m "feat(gdapi): add builtin_help route handler"
```

---

## Task 6: router.gd 注册 /help 路由

**Files:**
- Modify: `gdapi/addon/runtime/router.gd`

**Interfaces:**
- Consumes: `BuiltinHelp`（从 Task 5）
- Produces: router `dispatch()` 处理 `key == "help"`；`scan()` 注入路由表到 BuiltinHelp；`count()` 返回 `_routes.size() + 2`

- [ ] **Step 1: 在文件顶部常量区追加 BuiltinHelp 预加载**

定位到原文件第 17 行附近（已有 `BuiltinPing`、`BuiltinRoutes`），在其后增加一行：

```gdscript
## 内置帮助路由处理器
const BuiltinHelp := preload("res://addons/gdapi/runtime/builtin_help.gd")
```

最终该区块为：

```gdscript
const BuiltinPing := preload("res://addons/gdapi/runtime/builtin_ping.gd")
const BuiltinRoutes := preload("res://addons/gdapi/runtime/builtin_routes.gd")
## 内置帮助路由处理器
const BuiltinHelp := preload("res://addons/gdapi/runtime/builtin_help.gd")
```

- [ ] **Step 2: 在成员变量区追加 _builtin_help_handler**

在 `var _builtin_routes_handler: BuiltinRoutes` 之后增加：

```gdscript
## 内置帮助路由处理器实例
var _builtin_help_handler: BuiltinHelp
```

- [ ] **Step 3: 修改 `scan()` 方法**

将现有的 `scan` 方法体替换为以下内容（保留 doc-comment）：

```gdscript
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
```

- [ ] **Step 4: 修改 `count()` 方法**

原本：

```gdscript
func count() -> int:
	return _routes.size() + 1
```

改为：

```gdscript
func count() -> int:
	# _routes 已含 ping；额外两个内置路由：routes + help
	return _routes.size() + 2
```

- [ ] **Step 5: 修改 `dispatch()` 方法增加 /help 分支**

在现有 `if key == "routes":` 分支之后、`if not _routes.has(key):` 之前插入：

```gdscript
	# 处理内置 help 路由
	if key == "help":
		var req_help := GdApiRequest.new(req_dict)
		var res_help := GdApiResponse.new(server, id)
		_builtin_help_handler.handle(req_help, res_help)
		return
```

（变量名用 `req_help` / `res_help` 避免与 routes 分支变量名冲突；GDScript 在同一函数内变量名作用域是函数级。）

- [ ] **Step 6: 提交**

```bash
git add gdapi/addon/runtime/router.gd
git commit -m "feat(gdapi): register /help route and inject route table"
```

---

## Task 7: 内置 ping/routes 重载 doc()

**Files:**
- Modify: `gdapi/addon/runtime/builtin_ping.gd`
- Modify: `gdapi/addon/runtime/builtin_routes.gd`

**Interfaces:**
- Consumes: `GdApiRouteDoc`（class_name 全局可用）

- [ ] **Step 1: 修改 `gdapi/addon/runtime/builtin_ping.gd`**

在文件末尾追加（保持现有内容不变）：

```gdscript

## 返回该路由的帮助文档
func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("健康检查，返回 pong 与版本信息") \
		.desc("用于验证 API 服务是否正常运行；常用于连接测试和监控探针") \
		.returns("固定响应", {
			"ok": "bool, 固定为 true",
			"gdapi_version": "String, gdapi 插件版本",
			"editor_version": "String, Godot 编辑器版本",
		})
```

- [ ] **Step 2: 修改 `gdapi/addon/runtime/builtin_routes.gd`**

在文件末尾追加：

```gdscript

## 返回该路由的帮助文档
func doc() -> GdApiRouteDoc:
	return GdApiRouteDoc.make("列出所有已注册的路由名称") \
		.desc("返回当前 gdapi 运行时所有可调用路由的扁平名称数组；用于客户端发现 API 端点") \
		.returns("路由名数组（含内置 ping / routes / help）", {
			"ok": "bool",
			"routes": "Array[String], 按字母序排列的路由路径",
		})
```

- [ ] **Step 3: 提交**

```bash
git add gdapi/addon/runtime/builtin_ping.gd gdapi/addon/runtime/builtin_routes.gd
git commit -m "feat(gdapi): add doc() overrides for builtin ping/routes routes"
```

---

## Task 8: 手动 e2e 验证 gdapi 端

**说明：** 本任务在真实 Godot 环境中跑一次 fixture 项目，确认 /help 路由工作正常且 .gd.uid 文件由 Godot 自动生成。

**Files:**
- 可能新增（Godot 自动生成）：
  - `gdapi/addon/runtime/param_doc.gd.uid`
  - `gdapi/addon/runtime/route_doc.gd.uid`
  - `gdapi/addon/runtime/builtin_help.gd.uid`

- [ ] **Step 1: 在真实 Godot 中打开 fixture 项目让 UID 落盘**

```powershell
godot --headless --path tests/fixture_project --quit
```

Expected: 命令在几秒内退出。若编辑器报 GDScript 语法错误，回到对应任务修正后重跑。

- [ ] **Step 2: 运行 Task 3 的单元测试**

```powershell
godot --headless --path tests/fixture_project --script res://tests/test_route_doc.gd
```

Expected: `=== Results: N passed, 0 failed ===` 且退出码 0。

- [ ] **Step 3: 手动验证 /help 路由**

启动 fixture 项目编辑器（保持运行）：

```powershell
godot --editor --path tests/fixture_project
```

读取端口：`tests/fixture_project/.godot/gdapi.json` 的 `http_port` 字段。然后另开终端：

```powershell
# 列表
curl -X POST http://127.0.0.1:<port>/help -H "content-type: application/json" -d "{}"

# 详情
curl -X POST http://127.0.0.1:<port>/help -H "content-type: application/json" -d "{\"path\":\"ping\"}"

# 404
curl -X POST http://127.0.0.1:<port>/help -H "content-type: application/json" -d "{\"path\":\"nonexistent\"}"
```

Expected:
- 列表返回 `{"ok":true,"routes":[...]}`，数组中含 `{"path":"help",...}`, `{"path":"ping","summary":"健康检查，返回 pong 与版本信息",...}`, `{"path":"routes",...}` 及所有 editor/shared 下的路由（其余 summary 为空字符串）
- 详情返回 `{"ok":true,"doc":{...}}`，`doc.path == "ping"`，`doc.summary == "健康检查，返回 pong 与版本信息"`
- 404 返回 HTTP 404 状态 + `{"ok":false,"code":"not_found","msg":"route not found: nonexistent"}`

关闭 Godot 编辑器。

- [ ] **Step 4: 提交新生成的 .uid 文件**

```bash
git add gdapi/addon/runtime/*.gd.uid
git status
git commit -m "chore(gdapi): add .uid files for new runtime scripts" || echo "no uid files generated"
```

若没有新 .uid 文件（可能 Godot 已经自动 import 过），跳过提交。

---

## Task 9: 重构 exec.rs 抽出 build_body 并加 help 支持

**Files:**
- Modify: `cli/src/exec.rs`

**Interfaces:**
- Produces: 
  - `pub fn run(project: &Path, command: &str, args: &[String], data: Option<&str>, timeout_secs: u64) -> Result<i32>` — 新签名增加 `args: &[String]`
  - `fn build_body(command: &str, args: &[String], data: Option<&str>) -> Result<BuildBodyOutcome>` — 内部抽出便于单测
  - `enum BuildBodyOutcome { Body(String), Reject(String) }` — 内部辅助类型，`Reject(msg)` 表示构造前置错误，调用方打印 msg 后退出 2

- [ ] **Step 1: 编写失败的单元测试**

在 `cli/src/exec.rs` 末尾追加（先不实现 build_body，让测试编译失败）：

```rust
#[cfg(test)]
mod build_body_tests {
    use super::*;

    fn args(vs: &[&str]) -> Vec<String> {
        vs.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn help_no_args_no_data_yields_empty_object() {
        let out = build_body("help", &[], None).unwrap();
        match out {
            BuildBodyOutcome::Body(s) => assert_eq!(s, "{}"),
            BuildBodyOutcome::Reject(m) => panic!("unexpected reject: {}", m),
        }
    }

    #[test]
    fn help_with_path_arg_builds_path_object() {
        let out = build_body("help", &args(&["editor/scene/save"]), None).unwrap();
        match out {
            BuildBodyOutcome::Body(s) => assert_eq!(s, r#"{"path":"editor/scene/save"}"#),
            BuildBodyOutcome::Reject(m) => panic!("unexpected reject: {}", m),
        }
    }

    #[test]
    fn help_with_path_containing_quotes_escapes_safely() {
        // 通过 serde_json::json! 保证转义
        let out = build_body("help", &args(&[r#"weird"name"#]), None).unwrap();
        match out {
            BuildBodyOutcome::Body(s) => {
                // 解析回 JSON 确认转义正确
                let v: serde_json::Value = serde_json::from_str(&s).unwrap();
                assert_eq!(v["path"], r#"weird"name"#);
            }
            BuildBodyOutcome::Reject(m) => panic!("unexpected reject: {}", m),
        }
    }

    #[test]
    fn help_with_data_is_rejected() {
        let out = build_body("help", &[], Some("{}")).unwrap();
        match out {
            BuildBodyOutcome::Reject(m) => assert!(m.contains("--data"), "msg should mention --data: {}", m),
            BuildBodyOutcome::Body(_) => panic!("should reject"),
        }
    }

    #[test]
    fn non_help_with_extra_positional_is_rejected() {
        let out = build_body("ping", &args(&["unexpected"]), None).unwrap();
        match out {
            BuildBodyOutcome::Reject(m) => assert!(m.contains("positional"), "msg should mention positional: {}", m),
            BuildBodyOutcome::Body(_) => panic!("should reject"),
        }
    }

    #[test]
    fn non_help_with_data_passes_through() {
        let out = build_body("foo", &[], Some(r#"{"x":1}"#)).unwrap();
        match out {
            BuildBodyOutcome::Body(s) => assert_eq!(s, r#"{"x":1}"#),
            BuildBodyOutcome::Reject(m) => panic!("unexpected reject: {}", m),
        }
    }

    #[test]
    fn non_help_no_args_no_data_yields_empty_object() {
        let out = build_body("ping", &[], None).unwrap();
        match out {
            BuildBodyOutcome::Body(s) => assert_eq!(s, "{}"),
            BuildBodyOutcome::Reject(m) => panic!("unexpected reject: {}", m),
        }
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cargo test -p gdcli --lib build_body
```

Expected: 编译错误 `cannot find function build_body in this scope` 或类似。

- [ ] **Step 3: 实现 build_body + BuildBodyOutcome**

在 `cli/src/exec.rs` 的 `resolve_data` 函数之前插入：

```rust
/// build_body 的输出。
///
/// 调用方根据变体决定行为：Body 用作 HTTP 请求体；
/// Reject 表示构造前置校验失败，调用方打印 msg 到 stderr 后退出 2。
pub(crate) enum BuildBodyOutcome {
    /// 构造好的 JSON 字符串，可直接发送
    Body(String),
    /// 构造前置校验失败，msg 已包含给用户的解释
    Reject(String),
}

/// 根据 command/args/data 构造请求体。
///
/// 规则：
/// - command == "help": 必须无 --data；位置参数最多一个作为 path
///   - 无位置参数 → "{}"
///   - 一个位置参数 → {"path": "<arg>"}
///   - 多个位置参数 → Reject
/// - 其他 command: 位置参数必须为空，否则 Reject；body 来自 resolve_data
///   - 无 --data → "{}"
///   - 有 --data → resolve_data 解析（字面 JSON / @file / stdin）
///
/// # Arguments
/// * `command` - 路由命令名
/// * `args` - 位置参数数组
/// * `data` - --data 参数原始值
///
/// # Returns
/// BuildBodyOutcome::Body 或 BuildBodyOutcome::Reject
///
/// # Errors
/// resolve_data 失败（文件读取/stdin 错误）时返回 Err
pub(crate) fn build_body(
    command: &str,
    args: &[String],
    data: Option<&str>,
) -> Result<BuildBodyOutcome> {
    if command == "help" {
        if data.is_some() {
            return Ok(BuildBodyOutcome::Reject(
                "'help' command does not accept --data; use positional path argument instead".to_string(),
            ));
        }
        if args.len() > 1 {
            return Ok(BuildBodyOutcome::Reject(format!(
                "'help' accepts at most one positional path argument, got {}: {:?}",
                args.len(),
                args
            )));
        }
        let body = match args.first() {
            Some(path) => serde_json::json!({ "path": path }).to_string(),
            None => "{}".to_string(),
        };
        return Ok(BuildBodyOutcome::Body(body));
    }

    if !args.is_empty() {
        return Ok(BuildBodyOutcome::Reject(format!(
            "unexpected positional arguments for '{}': {:?}",
            command, args
        )));
    }
    let body = match resolve_data(data)? {
        Some(t) => t,
        None => "{}".to_string(),
    };
    Ok(BuildBodyOutcome::Body(body))
}
```

- [ ] **Step 4: 修改 `run()` 签名与实现**

把 `pub fn run(project: &Path, command: &str, data: Option<&str>, timeout_secs: u64) -> Result<i32>` 改为：

```rust
pub fn run(
    project: &Path,
    command: &str,
    args: &[String],
    data: Option<&str>,
    timeout_secs: u64,
) -> Result<i32> {
```

把原本计算 `body_text` 的两段代码：

```rust
    // 2. 准备请求 body
    let body_text = match resolve_data(data)? {
        Some(t) => t,
        None => "{}".to_string(),
    };
    // 客户端先验证 JSON 合法性
    if let Err(e) = serde_json::from_str::<serde_json::Value>(&body_text) {
        eprintln!("invalid JSON in --data: {}", e);
        return Ok(2);
    }
```

替换为：

```rust
    // 2. 准备请求 body（含 help 命令的位置参数特殊处理）
    let body_text = match build_body(command, args, data)? {
        BuildBodyOutcome::Body(t) => t,
        BuildBodyOutcome::Reject(msg) => {
            eprintln!("{}", msg);
            return Ok(2);
        }
    };
    // 客户端先验证 JSON 合法性
    if let Err(e) = serde_json::from_str::<serde_json::Value>(&body_text) {
        eprintln!("invalid JSON in --data: {}", e);
        return Ok(2);
    }
```

`gdapi_meta::read` 等之前/之后的逻辑保持不变。

- [ ] **Step 5: 运行单元测试确认通过**

```bash
cargo test -p gdcli --lib build_body
```

Expected: 7 个测试全部 PASS。

- [ ] **Step 6: 提交**

```bash
git add cli/src/exec.rs
git commit -m "feat(cli): add build_body and help command body handling in exec"
```

---

## Task 10: main.rs 给 Cmd::Exec 增加 args 位置参数

**Files:**
- Modify: `cli/src/main.rs`

**Interfaces:**
- Consumes: `exec::run` 新签名（从 Task 9）
- Produces: `gdcli exec <command> [args]...` clap 接口

- [ ] **Step 1: 修改 `Cmd::Exec` 枚举变体**

定位到 `cli/src/main.rs` 中现有定义（约 124-133 行）：

```rust
    /// 通过 HTTP 调用 gdapi 路由
    Exec {
        /// gdapi 路由命令名
        command: String,
        /// 请求 JSON 数据（字面 JSON、@file 或 - 表示 stdin）
        #[arg(long)]
        data: Option<String>,
        /// HTTP 请求超时秒数
        #[arg(long, default_value_t = 30)]
        timeout: u64,
    },
```

替换为：

```rust
    /// 通过 HTTP 调用 gdapi 路由
    Exec {
        /// gdapi 路由命令名
        command: String,
        /// 位置参数。仅 help 命令使用：作为查询的路由路径。其他命令必须为空。
        args: Vec<String>,
        /// 请求 JSON 数据（字面 JSON、@file 或 - 表示 stdin）
        #[arg(long)]
        data: Option<String>,
        /// HTTP 请求超时秒数
        #[arg(long, default_value_t = 30)]
        timeout: u64,
    },
```

- [ ] **Step 2: 修改 `run()` 中的 Exec 分支调用**

定位到现有调用（约 282-287 行）：

```rust
        Cmd::Exec { ref command, ref data, timeout } => {
            let project_root = project::resolve_project_root(project)
                .map_err(|e| anyhow::anyhow!(e))?;
            let code = exec::run(&project_root, command, data.as_deref(), timeout)?;
            std::process::exit(code);
        }
```

替换为：

```rust
        Cmd::Exec { ref command, ref args, ref data, timeout } => {
            let project_root = project::resolve_project_root(project)
                .map_err(|e| anyhow::anyhow!(e))?;
            let code = exec::run(&project_root, command, args, data.as_deref(), timeout)?;
            std::process::exit(code);
        }
```

- [ ] **Step 3: 编译确认**

```bash
cargo build -p gdcli
```

Expected: 编译通过，仅警告（如有）允许。

- [ ] **Step 4: 提交**

```bash
git add cli/src/main.rs
git commit -m "feat(cli): add positional args to exec command for help path"
```

---

## Task 11: 为 help 命令新增集成测试

**Files:**
- Modify: `cli/tests/exec_integration.rs`

**Interfaces:**
- Consumes: `gdcli exec help [...]` 全链路

- [ ] **Step 1: 在 `cli/tests/exec_integration.rs` 末尾追加 5 个测试**

```rust
#[test]
fn exec_help_list_passes_through_server_json() {
    let server = MockServer::start();
    let mock = server.mock(|when, then| {
        when.method(POST)
            .path("/help")
            .json_body_obj(&serde_json::json!({}));
        then.status(200)
            .header("content-type", "application/json")
            .body(r#"{"ok":true,"routes":[{"path":"ping","summary":"健康检查","params":[]}]}"#);
    });

    let meta = format!(
        r#"{{"http_port":{},"pid":{},"gdapi_version":"0.2.0"}}"#,
        server.port(),
        std::process::id()
    );
    let dir = setup_fake_project(&meta);

    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["exec", "help", "--project", dir.path().to_str().unwrap()])
        .assert()
        .success()
        .stdout(predicates::str::contains(r#""routes""#))
        .stdout(predicates::str::contains(r#""path":"ping""#));

    mock.assert();
}

#[test]
fn exec_help_with_path_sends_path_body() {
    let server = MockServer::start();
    let mock = server.mock(|when, then| {
        when.method(POST)
            .path("/help")
            .json_body_obj(&serde_json::json!({"path": "editor/scene/save"}));
        then.status(200)
            .body(r#"{"ok":true,"doc":{"path":"editor/scene/save","summary":"保存场景"}}"#);
    });

    let meta = format!(
        r#"{{"http_port":{},"pid":{},"gdapi_version":"0.2.0"}}"#,
        server.port(),
        std::process::id()
    );
    let dir = setup_fake_project(&meta);

    Command::cargo_bin("gdcli")
        .unwrap()
        .args([
            "exec",
            "help",
            "editor/scene/save",
            "--project",
            dir.path().to_str().unwrap(),
        ])
        .assert()
        .success()
        .stdout(predicates::str::contains(r#""doc""#));

    mock.assert();
}

#[test]
fn exec_help_missing_path_returns_exit_code_2() {
    let server = MockServer::start();
    server.mock(|when, then| {
        when.method(POST).path("/help");
        then.status(404).body(r#"{"ok":false,"code":"not_found","msg":"route not found: foo"}"#);
    });

    let meta = format!(
        r#"{{"http_port":{},"pid":{},"gdapi_version":"0.2.0"}}"#,
        server.port(),
        std::process::id()
    );
    let dir = setup_fake_project(&meta);

    Command::cargo_bin("gdcli")
        .unwrap()
        .args([
            "exec",
            "help",
            "foo",
            "--project",
            dir.path().to_str().unwrap(),
        ])
        .assert()
        .failure()
        .code(2)
        .stderr(predicates::str::contains("HTTP 404"));
}

#[test]
fn exec_help_with_data_flag_is_rejected() {
    let dir = setup_fake_project(
        r#"{"http_port":1,"pid":1,"gdapi_version":"0.2.0"}"#,
    );

    Command::cargo_bin("gdcli")
        .unwrap()
        .args([
            "exec",
            "help",
            "--data",
            "{}",
            "--project",
            dir.path().to_str().unwrap(),
        ])
        .assert()
        .failure()
        .code(2)
        .stderr(predicates::str::contains("--data"));
}

#[test]
fn exec_non_help_with_positional_arg_is_rejected() {
    let dir = setup_fake_project(
        r#"{"http_port":1,"pid":1,"gdapi_version":"0.2.0"}"#,
    );

    Command::cargo_bin("gdcli")
        .unwrap()
        .args([
            "exec",
            "ping",
            "unexpected",
            "--project",
            dir.path().to_str().unwrap(),
        ])
        .assert()
        .failure()
        .code(2)
        .stderr(predicates::str::contains("positional"));
}
```

- [ ] **Step 2: 运行集成测试**

```bash
cargo test -p gdcli --test exec_integration
```

Expected: 原有 6 个测试 + 新增 5 个测试全部 PASS。

- [ ] **Step 3: 运行全量测试与 lint 检查**

```bash
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
```

Expected: 全部通过。

若 clippy 报警告，逐条修复（typically: 未使用 import、不必要的 clone 等）。

- [ ] **Step 4: 提交**

```bash
git add cli/tests/exec_integration.rs
git commit -m "test(cli): add integration tests for exec help command"
```

---

## Task 12: 真实 e2e 验收 + 文档更新

**Files:**
- 可能修改：`README.md`（如果该项目 README 列出了 exec 子命令示例）

- [ ] **Step 1: 在 fixture 项目中运行真实 e2e**

启动 fixture 项目编辑器：

```powershell
godot --editor --path tests/fixture_project
```

待编辑器完全加载（约 5-10 秒），另开终端运行：

```powershell
.\target\debug\gdcli.exe exec help --project tests/fixture_project
```

Expected: stdout 输出 JSON，含 `"routes":[...]`，至少包含 `help` / `ping` / `routes` 三项。退出码 0。

```powershell
.\target\debug\gdcli.exe exec help ping --project tests/fixture_project
```

Expected: stdout 输出 JSON `{"ok":true,"doc":{"path":"ping","summary":"健康检查...",...}}`。退出码 0。

```powershell
.\target\debug\gdcli.exe exec help nonexistent --project tests/fixture_project
```

Expected: stderr 含 `HTTP 404` 与 `route not found: nonexistent`，退出码 2。

```powershell
.\target\debug\gdcli.exe exec help --data "{}" --project tests/fixture_project
```

Expected: stderr 含 `--data`，退出码 2。

关闭 Godot 编辑器。

- [ ] **Step 2: 检查 README 是否需要更新**

```bash
git grep -n "exec " README.md
```

如果 README 列出了 exec 子命令的用法示例，添加一段：

```markdown
### 查询可用路由

列出所有路由：
\`\`\`bash
gdcli exec help
\`\`\`

查看某个路由的详细文档：
\`\`\`bash
gdcli exec help editor/scene/save
\`\`\`
```

如果 README 没有 exec 用法章节，本步骤跳过（不主动新增）。

- [ ] **Step 3: 提交（仅当 README 有改动时）**

```bash
git status
git add README.md && git commit -m "docs: document gdcli exec help command" || echo "no README change"
```

---

## Self-Review Notes

**Spec coverage 检查：**
- ✅ Spec §3 自文档机制 → Task 1（ParamDoc）、Task 2（RouteDoc）、Task 4（route_handler 默认 doc）
- ✅ Spec §4 /help 路由 → Task 5（builtin_help）、Task 6（router 注册）、Task 7（内置 ping/routes 重载）
- ✅ Spec §5 CLI 端 → Task 9（exec.rs build_body + 签名）、Task 10（main.rs args）
- ✅ Spec §7 测试策略 → Task 3（GDScript 单测）、Task 9.Step 1（build_body 单测）、Task 11（集成测试）
- ✅ Spec §6 文件变更总览 → 与 Task 中 Files: 段一一对应
- ✅ Spec §8 兼容性 → Task 4 默认 doc() 实现保证非破坏性；Task 9 build_body 校验位置参数避免静默忽略；Task 9 build_body 用 serde_json::json! 防注入
- ✅ Spec §9 实施顺序 → 与 Task 编号顺序一致（runtime → router → CLI → 测试 → e2e）

**Type consistency 检查：**
- `GdApiRouteDoc.param(name_, type_, required_, description_, default_ = null)` — Task 2 与 Task 7 使用一致
- `GdApiRouteDoc.returns(desc_, fields_ = {})` — Task 2 与 Task 5/7 一致
- `set_routes(routes: Dictionary)` — Task 5 定义，Task 6 调用一致
- `build_body(command: &str, args: &[String], data: Option<&str>) -> Result<BuildBodyOutcome>` — Task 9 定义，Task 9.Step 4 调用一致
- `exec::run(project, command, args, data, timeout)` — Task 9 修改签名，Task 10 调用一致

**Placeholder 扫描：** 无 TBD / TODO / "类似于 Task N" / "适当的错误处理" 等占位符。

**风险检查：** 
- `.gd.uid` 文件依赖 Godot 自动生成，已在 Task 8 明确步骤
- GDScript const + class_name 同时引用 RouteDoc：Task 4 用 `_RouteDoc` 私有常量避免与子类冲突，子类用全局 class_name `GdApiRouteDoc`，无歧义

---

**Plan complete and saved to `docs/superpowers/plans/2026-06-24-help-command-and-self-doc.md`. Two execution options:**

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
