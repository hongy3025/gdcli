@tool
extends RefCounted

const EvalService := preload("res://addons/gdapi/runtime/services/eval_service.gd")

var passed := 0
var failed := 0


func run(_tree: SceneTree) -> Dictionary:
	var result := (
		EvalService
		. execute(
			"origin + delta",
			{
				"origin": {"type": "Vector2", "value": [1.0, 2.0]},
				"delta": {"type": "Vector2", "value": [3.0, 4.0]},
			}
		)
	)
	assert_eq(
		result.get("value", {}), {"type": "Vector2", "value": [4.0, 6.0]}, "typed vector expression"
	)
	var denied := EvalService.execute("Engine.get_main_loop()", {})
	assert_eq(denied.get("code", ""), "permission_denied", "object access is denied")
	var unknown := EvalService.execute("instance_from_id(1)", {})
	assert_eq(unknown.get("code", ""), "permission_denied", "unknown call is denied")
	# 输入 key 不再受限：任意 key 可用
	var free_keys := EvalService.execute("a + b", {"a": 1, "b": 2})
	assert_true(free_keys.get("ok", false), "arbitrary input keys are allowed")
	for shape in range(4):
		_test_rejection_does_not_load_script(shape)
	_test_forbidden_native_values(_tree)
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	return {"ok": failed == 0, "passed": passed, "failed": failed}


func _test_rejection_does_not_load_script(shape: int) -> void:
	var suffix := "%d_%d" % [Time.get_ticks_usec(), shape]
	var script_path := "user://eval_security_%s.gd" % suffix
	var marker_path := "user://eval_security_%s.marker" % suffix
	var script_file := FileAccess.open(script_path, FileAccess.WRITE)
	assert_true(script_file != null, "security script can be written")
	if script_file == null:
		return
	script_file.store_string(
		(
			(
				"@tool\nextends RefCounted\n\n"
				+ "static func _static_init() -> void:\n"
				+ '\tvar marker := FileAccess.open("%s", FileAccess.WRITE)\n'
				+ '\tmarker.store_string("executed")\n'
				+ "\tmarker.close()\n"
			)
			% marker_path
		)
	)
	script_file.close()
	var encoded := {"type": "Resource", "value": script_path}
	var value: Variant = encoded
	match shape:
		1:
			value = [encoded]
		2:
			value = {"nested": [encoded]}
		3:
			value = {encoded: "dictionary key"}
	var rejected := EvalService.execute("1", {"input": value})
	assert_eq(rejected.get("code"), "invalid_param", "unsafe encoding is rejected")
	assert_true(not FileAccess.file_exists(marker_path), "rejection has no static init side effect")
	var control := ResourceLoader.load(script_path)
	assert_true(control != null, "security script is a valid loadable resource")
	assert_true(FileAccess.file_exists(marker_path), "control load executes static init")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(script_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(marker_path))


func _test_forbidden_native_values(tree: SceneTree) -> void:
	var object := RefCounted.new()
	for value in [object, RID(), Callable(self, "assert_true"), Signal(tree, "tree_changed")]:
		var rejected := EvalService.execute("1", {"input": {"nested": [value]}})
		assert_eq(rejected.get("code"), "invalid_param", "native executable value is rejected")
	var safe := EvalService.execute("input", {"input": [1, {"safe": true}, null]})
	assert_eq(safe.get("value"), [1, {"safe": true}, null], "safe nested Variants remain usable")


func assert_eq(actual: Variant, expected: Variant, context: String) -> void:
	if actual == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s expected=%s actual=%s" % [context, expected, actual])


func assert_true(actual: bool, context: String) -> void:
	assert_eq(actual, true, context)
