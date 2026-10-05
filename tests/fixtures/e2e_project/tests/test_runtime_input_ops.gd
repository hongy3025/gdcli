@tool
extends RefCounted

const InputOps := preload("res://addons/gdapi/runtime/runtime_input_ops.gd")

var passed := 0
var failed := 0
var _tree: SceneTree


func run(tree: SceneTree) -> Dictionary:
	_tree = tree
	print("Running GdApiRuntimeInputOps tests...")
	await test_all_integer_fields_reject_non_integral_and_unsafe_numbers()
	await test_sequence_duration_must_fit_operation_timeout()
	await test_sequence_checks_deadline_after_timer_before_side_effect()

	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	return {"ok": failed == 0, "passed": passed, "failed": failed}


func assert_eq(actual: Variant, expected: Variant, context: String = "") -> void:
	if actual == expected:
		passed += 1
		print("  PASS: %s" % context)
	else:
		failed += 1
		print("  FAIL: %s - expected '%s', got '%s'" % [context, expected, actual])


func _assert_invalid(result: Dictionary, context: String) -> void:
	assert_eq(result.get("ok", true), false, context + " rejected")
	assert_eq(result.get("code", ""), "invalid_param", context + " code")


func _integer_case(field_name: String, value: Variant) -> Dictionary:
	var result: Dictionary = {"ok": true}
	match field_name:
		"keycode":
			result = InputOps.key({"keycode": value})
		"mouse.button":
			result = InputOps.mouse({"kind": "button", "button": value})
		"gamepad.device":
			result = InputOps.gamepad({"kind": "button", "device": value, "button": 0})
		"gamepad.button":
			result = InputOps.gamepad({"kind": "button", "device": 0, "button": value})
		"gamepad.axis":
			result = InputOps.gamepad({"kind": "axis", "device": 0, "axis": value, "value": 0.0})
		"touch.index":
			result = InputOps.touch({"index": value})
		"sequence.after_ms":
			result = await (
				InputOps
				. sequence(
					{
						"timeout_ms": 5000,
						"events":
						[
							{
								"after_ms": value,
								"route": "runtime/input/key",
								"data": {"keycode": 32},
							}
						]
					}
				)
			)
	return result


func test_all_integer_fields_reject_non_integral_and_unsafe_numbers() -> void:
	var bad_values: Array = [1.0000001, -0.0000001, NAN, INF, -INF, 1.0e30]
	var fields := [
		"keycode",
		"mouse.button",
		"gamepad.device",
		"gamepad.button",
		"gamepad.axis",
		"touch.index",
		"sequence.after_ms",
	]
	for field_name in fields:
		for value in bad_values:
			_assert_invalid(await _integer_case(field_name, value), "%s=%s" % [field_name, value])


func test_sequence_duration_must_fit_operation_timeout() -> void:
	var event := {
		"after_ms": 10,
		"route": "runtime/input/key",
		"data": {"keycode": 32},
	}
	_assert_invalid(
		await InputOps.sequence({"timeout_ms": 10, "events": [event]}),
		"sequence duration equal to timeout"
	)


func test_sequence_checks_deadline_after_timer_before_side_effect() -> void:
	var keycode := KEY_F24
	var originally_pressed := Input.is_key_pressed(keycode)
	_tree.process_frame.connect(func() -> void: OS.delay_msec(20), CONNECT_ONE_SHOT)
	var result: Dictionary = await (
		InputOps
		. sequence(
			{
				"timeout_ms": 10,
				"events":
				[
					{
						"after_ms": 1,
						"route": "runtime/input/key",
						"data": {"keycode": keycode, "pressed": not originally_pressed},
					}
				],
			}
		)
	)
	assert_eq(result.get("ok", true), false, "expired sequence fails")
	assert_eq(result.get("code", ""), "timeout", "expired sequence code")
	assert_eq(
		Input.is_key_pressed(keycode), originally_pressed, "expired sequence injects no key change"
	)
	if Input.is_key_pressed(keycode) != originally_pressed:
		InputOps.key({"keycode": keycode, "pressed": originally_pressed})
