@tool
extends SceneTree

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

var passed := 0
var failed := 0

func _init() -> void:
	assert_eq(PathGuard.validate("scenes/a.tscn", "read").path, "res://scenes/a.tscn", "relative path")
	assert_true(PathGuard.validate("user://cache.json", "write").ok, "user write")
	assert_eq(PathGuard.validate("res://foo..bar.txt", "read").ok, true, "double dot filename")
	assert_eq(PathGuard.validate("res://a/../b", "read").code, ErrorCodes.INVALID_PATH, "parent segment")
	assert_eq(PathGuard.validate("C:/temp/a.txt", "read").code, ErrorCodes.INVALID_PATH, "windows absolute")
	assert_eq(PathGuard.validate("/tmp/a.txt", "read").code, ErrorCodes.INVALID_PATH, "posix absolute")
	assert_eq(PathGuard.validate("res://addons/gdapi/plugin.gd", "write").code, ErrorCodes.PERMISSION_DENIED, "addon protected")
	assert_eq(PathGuard.validate("res://.godot/gdapi.json", "delete").code, ErrorCodes.PERMISSION_DENIED, "metadata protected")
	assert_eq(PathGuard.validate("res://a.txt", "execute").code, ErrorCodes.INVALID_PARAM, "unknown mode")
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)

func assert_true(value: bool, context: String) -> void:
	assert_eq(value, true, context)

func assert_eq(actual, expected, context: String) -> void:
	if actual == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s expected=%s actual=%s" % [context, expected, actual])