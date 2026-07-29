@tool
extends SceneTree

const EvalService := preload("res://addons/gdapi/runtime/services/eval_service.gd")

var passed := 0
var failed := 0


func _init() -> void:
	var policy := {"max_source_bytes": 16384, "allowed_input_keys": ["origin", "delta"]}
	var result := EvalService.execute(
		"origin + delta",
		{
			"origin": {"type": "Vector2", "value": [1, 2]},
			"delta": {"type": "Vector2", "value": [3, 4]}
		},
		policy
	)
	assert_eq(
		result.get("value", {}), {"type": "Vector2", "value": [4.0, 6.0]}, "typed vector expression"
	)
	var denied := EvalService.execute("Engine.get_main_loop()", {}, policy)
	assert_eq(denied.get("code", ""), "permission_denied", "object access is denied")
	var comparison := EvalService.execute("origin.x <= 2", {}, policy)
	assert_eq(comparison.get("code", ""), "permission_denied", "member access remains denied")
	var allowed_comparison := (
		EvalService
		. execute(
			"a <= b and a != 0",
			{"a": 1, "b": 2},
			{
				"max_source_bytes": 16384,
				"allowed_input_keys": ["a", "b"],
			}
		)
	)
	assert_true(allowed_comparison.get("ok", false), "comparisons are allowed")
	var unknown := EvalService.execute("instance_from_id(1)", {}, policy)
	assert_eq(unknown.get("code", ""), "permission_denied", "unknown call is denied")
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
