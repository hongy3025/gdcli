## GdApiRouteDoc / GdApiParamDoc 单元测试
##
## 覆盖：
## - ParamDoc.to_dict() 五字段完整性与 null 默认值
## - RouteDoc 静态工厂 make()
## - fluent builder 链式调用（desc/param/returns/example）
## - to_dict() 完整详情序列化
## - to_summary_dict() 简要序列化
##
## 运行方式：共享编辑器中的 fixture suite runner。

@tool
extends RefCounted

var RouteDoc = preload("res://addons/gdapi/runtime/route_doc.gd")
var Router = preload("res://addons/gdapi/runtime/router.gd")
var BuiltinRoutes = preload("res://addons/gdapi/runtime/builtin_routes.gd")
var BuiltinCommands = preload("res://addons/gdapi/runtime/builtin_commands.gd")
var BuiltinCommandHelp = preload("res://addons/gdapi/runtime/builtin_command_help.gd")
var ParamDoc = preload("res://addons/gdapi/runtime/param_doc.gd")

var passed := 0
var failed := 0


func run(_tree: SceneTree) -> Dictionary:
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
	test_all_route_docs_complete()
	test_route_doc_chained_call()

	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	return {"ok": failed == 0, "passed": passed, "failed": failed}


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
	var rd = (
		RouteDoc
		. make("save scene")
		. desc("save to disk")
		. param("scene_path", "String", true, "path")
		. param("new_path", "String", false, "alt path", "")
		. returns("save result", {"ok": "bool", "path": "String"})
		. example('{"scene_path":"res://a.tscn"}')
	)
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
	var rd = (
		RouteDoc
		. make("s")
		. desc("long desc")
		. param("a", "String", true, "desc-a")
		. param("b", "int", false, "desc-b", 0)
		. returns("r")
	)
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


func test_all_route_docs_complete() -> void:
	var router = Router.new()
	router.scan("res://addons/gdapi/routes", true)
	var handlers: Dictionary = router._routes.duplicate()
	handlers["gdapi/routes"] = BuiltinRoutes
	handlers["command/list"] = BuiltinCommands
	handlers["command/doc"] = BuiltinCommandHelp
	for route_path in handlers:
		var handler = handlers[route_path].new()
		var detail: Dictionary = handler.doc().to_dict()
		var returns: Dictionary = detail.get("returns", {})
		var fields = returns.get("fields", {})
		var params: Array = detail.get("params", [])
		var examples: Array = detail.get("examples", [])
		var complete: bool = (
			not String(detail.get("summary", "")).is_empty()
			and fields is Dictionary
			and not fields.is_empty()
			and (params.is_empty() or not examples.is_empty())
		)
		assert_true(complete, "complete route documentation: " + String(route_path))
