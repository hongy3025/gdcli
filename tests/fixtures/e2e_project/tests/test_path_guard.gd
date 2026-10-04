@tool
extends SceneTree

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

var passed := 0
var failed := 0


func _init() -> void:
	assert_true(PathGuard.validate("res://", "read").ok, "project root can be read")
	assert_eq(
		PathGuard.validate("res://", "write").code,
		ErrorCodes.INVALID_PATH,
		"project root is not a write target"
	)
	assert_eq(
		PathGuard.validate("scenes/a.tscn", "read").path, "res://scenes/a.tscn", "relative path"
	)
	assert_true(PathGuard.validate("user://cache.json", "write").ok, "user write")
	assert_eq(PathGuard.validate("res://foo..bar.txt", "read").ok, true, "double dot filename")
	assert_eq(
		PathGuard.validate("res://a/../b", "read").code, ErrorCodes.INVALID_PATH, "parent segment"
	)
	assert_eq(
		PathGuard.validate("C:/temp/a.txt", "read").code,
		ErrorCodes.INVALID_PATH,
		"windows absolute"
	)
	assert_eq(
		PathGuard.validate("/tmp/a.txt", "read").code, ErrorCodes.INVALID_PATH, "posix absolute"
	)
	assert_eq(
		PathGuard.validate("res://addons/gdapi/plugin.gd", "write").code,
		ErrorCodes.PERMISSION_DENIED,
		"addon protected"
	)
	for protected_path in [
		"res://addons/gdapi/plugin.gd",
		"res://./addons/gdapi/plugin.gd",
	]:
		for mode in ["write", "delete"]:
			assert_eq(
				PathGuard.validate(protected_path, mode).code,
				ErrorCodes.PERMISSION_DENIED,
				"normalized protected path: " + mode + " " + protected_path
			)
	var windows_case_insensitive := OS.get_name() == "Windows"
	for protected_path in [
		"res://addons/gdapi",
		"res://addons/gdapi/plugin.gd",
		"res://addons/GDAPI",
		"res://addons/GDAPI/plugin.gd",
		"res://ADDONS/GdApi",
		"res://ADDONS/GdApi/plugin.gd",
	]:
		var is_protected_case: bool = (
			windows_case_insensitive
			or protected_path == "res://addons/gdapi"
			or protected_path == "res://addons/gdapi/plugin.gd"
		)
		for mode in ["write", "delete"]:
			var result := PathGuard.validate(protected_path, mode)
			if is_protected_case:
				assert_eq(
					result.code,
					ErrorCodes.PERMISSION_DENIED,
					"protected casing: " + mode + " " + protected_path
				)
			else:
				assert_true(result.ok, "case-sensitive distinct path: " + protected_path)
	assert_true(
		PathGuard.validate("res://addons/gdapi_backup/plugin.gd", "write").ok,
		"protected segment-prefix neighbor"
	)
	assert_true(
		PathGuard.validate("user://addons/GDAPI/plugin.gd", "write").ok,
		"user path is not a res:// alias"
	)
	assert_eq(
		PathGuard.validate("res://.godot/gdapi.json", "delete").code,
		ErrorCodes.PERMISSION_DENIED,
		"metadata protected"
	)
	assert_eq(
		PathGuard.validate("res://a.txt", "execute").code, ErrorCodes.INVALID_PARAM, "unknown mode"
	)
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
