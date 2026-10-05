@tool
extends RefCounted

const Router := preload("res://addons/gdapi/runtime/router.gd")
const HANDLER_TEMPLATE := """@tool
extends \"res://addons/gdapi/runtime/route_handler.gd\"
func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
    res.json({\"ok\": true})
func doc() -> GdApiRouteDoc:
    return GdApiRouteDoc.make(\"%s\")
"""
const ASYNC_HANDLER := """@tool
extends \"res://addons/gdapi/runtime/route_handler.gd\"
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
    await (Engine.get_main_loop() as SceneTree).process_frame
    if not req.body.has(\"number\"):
        res.error(\"number is required\", \"missing_param\", 400)
func doc() -> GdApiRouteDoc:
    return GdApiRouteDoc.make(\"Deferred validation\").mutates()
"""

var passed := 0
var failed := 0
var _tree: SceneTree
var _test_root := "user://gdapi_router_test_%d" % Time.get_ticks_usec()


class FakeServer:
	extends RefCounted
	var responses: Array = []

	func send_response(id: int, status: int, _headers: Dictionary, body: PackedByteArray) -> void:
		responses.append(
			{"id": id, "status": status, "body": JSON.parse_string(body.get_string_from_utf8())}
		)


func run(tree: SceneTree) -> Dictionary:
	_tree = tree
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_test_root))
	var router := Router.new()
	_write_handler("v1")
	router.scan(_test_root, true)
	assert_eq(router._routes["sample"].new().doc().summary, "v1", "route added")
	_write_handler("v2")
	router.scan(_test_root)
	assert_eq(router._routes["sample"].new().doc().summary, "v2", "route replaced")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_test_root + "/sample.gd"))
	router.scan(_test_root)
	assert_eq(router._routes.has("sample"), false, "route deleted")
	await _test_deferred_validation_response(router)
	_cleanup()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	return {"ok": failed == 0, "passed": passed, "failed": failed}


func _write_handler(summary: String) -> void:
	var file := FileAccess.open(_test_root + "/sample.gd", FileAccess.WRITE)
	file.store_string(HANDLER_TEMPLATE % summary)
	file.close()


func _test_deferred_validation_response(router: RefCounted) -> void:
	var file := FileAccess.open(_test_root + "/sample.gd", FileAccess.WRITE)
	file.store_string(ASYNC_HANDLER)
	file.close()
	router.scan(_test_root, true)
	var server := FakeServer.new()
	router.dispatch(
		{
			"id": 42,
			"method": "POST",
			"path": "/sample",
			"headers": {"content-type": "application/json"},
			"body": "{}".to_utf8_buffer()
		},
		server
	)
	assert_eq(server.responses.size(), 0, "async request has not replied before its frame")
	await _tree.process_frame
	assert_eq(server.responses.size(), 1, "request-local handler replies after its await")
	if not server.responses.is_empty():
		assert_eq(server.responses[0].id, 42, "deferred response retains request ownership")
		assert_eq(server.responses[0].status, 400, "deferred validation keeps HTTP status")
		assert_eq(server.responses[0].body.code, "missing_param", "deferred validation fails")
	await _tree.process_frame
	assert_eq(server.responses.size(), 1, "deferred response is emitted exactly once")


func _cleanup() -> void:
	var file_path := ProjectSettings.globalize_path(_test_root + "/sample.gd")
	if FileAccess.file_exists(file_path):
		DirAccess.remove_absolute(file_path)
	var dir_path := ProjectSettings.globalize_path(_test_root)
	if DirAccess.dir_exists_absolute(dir_path):
		DirAccess.remove_absolute(dir_path)


func assert_eq(actual, expected, context: String) -> void:
	if actual == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s expected=%s actual=%s" % [context, expected, actual])
