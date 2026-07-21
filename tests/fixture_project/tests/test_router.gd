@tool
extends SceneTree

const Router := preload("res://addons/gdapi/runtime/router.gd")
const TEST_ROOT := "user://gdapi_router_test"
const HANDLER_TEMPLATE := """@tool
extends \"res://addons/gdapi/runtime/route_handler.gd\"
func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
    res.json({\"ok\": true})
func doc() -> GdApiRouteDoc:
    return GdApiRouteDoc.make(\"%s\")
"""

var passed := 0
var failed := 0

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	_cleanup()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_ROOT))
	var router := Router.new()
	_write_handler("v1")
	router.scan(TEST_ROOT, true)
	assert_eq(router._routes["sample"].new().doc().summary, "v1", "route added")
	_write_handler("v2")
	router.scan(TEST_ROOT)
	assert_eq(router._routes["sample"].new().doc().summary, "v2", "route replaced")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_ROOT + "/sample.gd"))
	router.scan(TEST_ROOT)
	assert_eq(router._routes.has("sample"), false, "route deleted")
	_cleanup()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)

func _write_handler(summary: String) -> void:
	var file := FileAccess.open(TEST_ROOT + "/sample.gd", FileAccess.WRITE)
	file.store_string(HANDLER_TEMPLATE % summary)
	file.close()

func _cleanup() -> void:
	var file_path := ProjectSettings.globalize_path(TEST_ROOT + "/sample.gd")
	if FileAccess.file_exists(file_path):
		DirAccess.remove_absolute(file_path)
	var dir_path := ProjectSettings.globalize_path(TEST_ROOT)
	if DirAccess.dir_exists_absolute(dir_path):
		DirAccess.remove_absolute(dir_path)

func assert_eq(actual, expected, context: String) -> void:
	if actual == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s expected=%s actual=%s" % [context, expected, actual])