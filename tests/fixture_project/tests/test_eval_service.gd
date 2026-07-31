@tool
extends SceneTree

const EvalService := preload("res://addons/gdapi/runtime/services/eval_service.gd")

var passed := 0
var failed := 0


func _init() -> void:
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
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)


func assert_eq(actual: Variant, expected: Variant, context: String) -> void:
	if actual == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s expected=%s actual=%s" % [context, expected, actual])


func assert_true(actual: bool, context: String) -> void:
	assert_eq(actual, true, context)
