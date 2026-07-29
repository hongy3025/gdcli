@tool
extends SceneTree

const EvalService := preload("res://addons/gdapi/runtime/services/eval_service.gd")

var passed := 0
var failed := 0

func _init() -> void:
	var policy := {"max_source_bytes": 16384, "allowed_input_keys": ["origin", "delta"]}
	var result := EvalService.execute("origin + delta", {"origin": {"type": "Vector2", "value": [1, 2]}, "delta": {"type": "Vector2", "value": [3, 4]}}, policy)
	assert_eq(result.get("value", {}), {"type": "Vector2", "value": [4.0, 6.0]}, "typed vector expression")
	var denied := EvalService.execute("Engine.get_main_loop()", {}, policy)
	assert_eq(denied.get("code", ""), "permission_denied", "object access is denied")
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)

func assert_eq(actual: Variant, expected: Variant, context: String) -> void:
	if actual == expected: passed += 1
	else:
		failed += 1
		print("FAIL: %s expected=%s actual=%s" % [context, expected, actual])
