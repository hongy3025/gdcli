## 运行时 input 模拟实现。
##
## 每个公开 op 在创建 InputEvent 前完成严格类型与范围校验。sequence 会先校验
## 全部 entry、子 route 和 data，再执行任何事件；执行时子 op 仍会再次校验。

@tool
class_name GdApiRuntimeInputOps
extends RefCounted

const MAX_SEQUENCE_EVENTS := 100
const MAX_SEQUENCE_TOTAL_MS := 10000
const MAX_KEYCODE := 0x01ffffff
const MAX_DEVICE := 15
const MAX_JOYPAD_BUTTON := 127
const MAX_JOYPAD_AXIS := 3
const MAX_TOUCH_INDEX := 31
const MAX_POSITION_COMPONENT := 1000000.0
const MAX_ACTION_LENGTH := 128
const DEFAULT_OPERATION_TIMEOUT_MS := 5000
const MAX_OPERATION_TIMEOUT_MS := 25000
const INPUT_ROUTES := [
	"runtime/input/key",
	"runtime/input/mouse",
	"runtime/input/gamepad",
	"runtime/input/touch",
	"runtime/input/action",
]


static func key(payload: Dictionary) -> Dictionary:
	var verdict := _validate_key(payload)
	if not bool(verdict.get("ok", false)):
		return verdict
	var keycode: int = payload["keycode"]
	var pressed: bool = payload.get("pressed", true)
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	event.keycode = keycode
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	return _success(
		{
			"event_type": "key",
			"keycode": keycode,
			"pressed": pressed,
		}
	)


static func mouse(payload: Dictionary) -> Dictionary:
	var verdict := _validate_mouse(payload)
	if not bool(verdict.get("ok", false)):
		return verdict
	var kind: String = payload.get("kind", "button")
	var position := _position_value(payload.get("position", [0, 0]))
	if kind == "button":
		var event := InputEventMouseButton.new()
		event.button_index = int(payload.get("button"))
		event.position = position
		event.pressed = payload.get("pressed", true)
		Input.parse_input_event(event)
		return _success(
			{
				"event_type": "button",
				"button": event.button_index,
				"pressed": event.pressed,
			}
		)
	var motion := InputEventMouseMotion.new()
	motion.position = position
	motion.relative = position
	Input.parse_input_event(motion)
	return _success({"event_type": "motion"})


static func gamepad(payload: Dictionary) -> Dictionary:
	var verdict := _validate_gamepad(payload)
	if not bool(verdict.get("ok", false)):
		return verdict
	var device: int = payload.get("device", 0)
	var kind: String = payload.get("kind", "button")
	if kind == "button":
		var event := InputEventJoypadButton.new()
		event.device = device
		event.button_index = int(payload.get("button"))
		event.pressed = payload.get("pressed", true)
		Input.parse_input_event(event)
		return _success(
			{
				"event_type": "gamepad_button",
				"device": device,
				"button": event.button_index,
				"pressed": event.pressed,
			}
		)
	var motion := InputEventJoypadMotion.new()
	motion.device = device
	motion.axis = int(payload.get("axis"))
	motion.axis_value = float(payload.get("value"))
	Input.parse_input_event(motion)
	return _success(
		{
			"event_type": "gamepad_axis",
			"device": device,
			"axis": motion.axis,
			"value": motion.axis_value,
		}
	)


static func touch(payload: Dictionary) -> Dictionary:
	var verdict := _validate_touch(payload)
	if not bool(verdict.get("ok", false)):
		return verdict
	var event := InputEventScreenTouch.new()
	event.index = int(payload.get("index", 0))
	event.position = _position_value(payload.get("position", [0, 0]))
	event.pressed = payload.get("pressed", true)
	Input.parse_input_event(event)
	return _success(
		{
			"event_type": "touch",
			"index": event.index,
			"pressed": event.pressed,
		}
	)


static func action(payload: Dictionary) -> Dictionary:
	var verdict := _validate_action(payload)
	if not bool(verdict.get("ok", false)):
		return verdict
	var action_name: String = payload["action"]
	var pressed: bool = payload.get("pressed", true)
	var event := InputEventAction.new()
	event.action = action_name
	event.pressed = pressed
	event.strength = 1.0 if pressed else 0.0
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	return _success(
		{
			"event_type": "action",
			"action": action_name,
			"pressed": pressed,
		}
	)


## Sequence delays are relative per entry. Validate their cumulative sum and every
## nested operation before yielding or injecting the first event.
static func sequence(payload: Dictionary) -> Dictionary:
	var verdict := _validate_sequence(payload)
	if not bool(verdict.get("ok", false)):
		return verdict
	var timeout_ms := _operation_timeout(payload)
	var deadline_msec := Time.get_ticks_msec() + timeout_ms
	var events: Array = payload["events"]
	var tree := Engine.get_main_loop() as SceneTree
	if not events.is_empty() and tree == null:
		return _failure("godot_error", "runtime SceneTree is unavailable")
	for entry_variant in events:
		var entry: Dictionary = entry_variant
		var after_ms: int = entry.get("after_ms", 0)
		if after_ms > 0:
			await tree.create_timer(after_ms / 1000.0).timeout
		await tree.process_frame
		if Time.get_ticks_msec() >= deadline_msec:
			return _failure("timeout", "input sequence operation timed out")
		var child_result := _dispatch_child(String(entry["route"]), entry["data"])
		if not bool(child_result.get("ok", false)):
			return child_result
	return _success(
		{
			"event_type": "sequence",
			"events": events.size(),
			"changed": not events.is_empty(),
		}
	)


static func _validate_key(payload: Dictionary) -> Dictionary:
	if not payload.has("keycode"):
		return _failure("missing_param", "keycode is required")
	var keycode: Variant = payload["keycode"]
	if not _integer_in_range(keycode, 1, MAX_KEYCODE):
		return _failure("invalid_param", "keycode must be a bounded positive integer")
	return _validate_optional_bool(payload, "pressed")


static func _validate_mouse(payload: Dictionary) -> Dictionary:
	var kind: Variant = payload.get("kind", "button")
	if typeof(kind) != TYPE_STRING or String(kind) not in ["button", "motion"]:
		return _failure("invalid_param", "mouse kind must be button or motion")
	var position_verdict := _validate_position(payload.get("position", [0, 0]))
	if not bool(position_verdict.get("ok", false)):
		return position_verdict
	if String(kind) == "button":
		if not payload.has("button"):
			return _failure("missing_param", "mouse button is required")
		var button: Variant = payload["button"]
		if not _integer_in_range(button, 1, 8):
			return _failure("invalid_param", "mouse button must be 1..8")
		return _validate_optional_bool(payload, "pressed")
	return {"ok": true}


static func _validate_gamepad(payload: Dictionary) -> Dictionary:
	var device: Variant = payload.get("device", 0)
	if not _integer_in_range(device, 0, MAX_DEVICE):
		return _failure("invalid_param", "gamepad device must be 0..15")
	var kind: Variant = payload.get("kind", "button")
	if typeof(kind) != TYPE_STRING or String(kind) not in ["button", "axis"]:
		return _failure("invalid_param", "gamepad kind must be button or axis")
	if String(kind) == "button":
		if not payload.has("button"):
			return _failure("missing_param", "gamepad button is required")
		var button: Variant = payload["button"]
		if not _integer_in_range(button, 0, MAX_JOYPAD_BUTTON):
			return _failure("invalid_param", "gamepad button must be 0..127")
		return _validate_optional_bool(payload, "pressed")
	if not payload.has("axis"):
		return _failure("missing_param", "gamepad axis is required")
	if not payload.has("value"):
		return _failure("missing_param", "gamepad axis value is required")
	var axis: Variant = payload["axis"]
	if not _integer_in_range(axis, 0, MAX_JOYPAD_AXIS):
		return _failure("invalid_param", "gamepad axis must be 0..3")
	var value: Variant = payload["value"]
	if (
		not _is_number(value)
		or not is_finite(float(value))
		or float(value) < -1.0
		or float(value) > 1.0
	):
		return _failure("invalid_param", "gamepad axis value must be finite and within -1..1")
	return {"ok": true}


static func _validate_touch(payload: Dictionary) -> Dictionary:
	var index: Variant = payload.get("index", 0)
	if not _integer_in_range(index, 0, MAX_TOUCH_INDEX):
		return _failure("invalid_param", "touch index must be 0..31")
	var position_verdict := _validate_position(payload.get("position", [0, 0]))
	if not bool(position_verdict.get("ok", false)):
		return position_verdict
	return _validate_optional_bool(payload, "pressed")


static func _validate_action(payload: Dictionary) -> Dictionary:
	if not payload.has("action"):
		return _failure("missing_param", "action is required")
	var action_name: Variant = payload["action"]
	if (
		typeof(action_name) != TYPE_STRING
		or String(action_name).is_empty()
		or String(action_name).length() > MAX_ACTION_LENGTH
	):
		return _failure("invalid_param", "action must be a non-empty bounded string")
	if not InputMap.has_action(String(action_name)):
		return _failure("invalid_param", "action not in InputMap: %s" % String(action_name))
	return _validate_optional_bool(payload, "pressed")


static func _validate_sequence(payload: Dictionary) -> Dictionary:
	var timeout_ms := _operation_timeout(payload)
	if timeout_ms <= 0:
		return _failure("invalid_param", "timeout_ms must be a bounded positive integer")
	if not payload.has("events"):
		return _failure("missing_param", "events is required")
	var events_variant: Variant = payload["events"]
	if typeof(events_variant) != TYPE_ARRAY:
		return _failure("invalid_param", "events must be an array")
	var events: Array = events_variant
	if events.size() > MAX_SEQUENCE_EVENTS:
		return _failure("invalid_param", "sequence has more than 100 events")
	var total_ms := 0
	for entry_variant in events:
		if typeof(entry_variant) != TYPE_DICTIONARY:
			return _failure("invalid_param", "sequence entries must be objects")
		var entry: Dictionary = entry_variant
		var after_variant: Variant = entry.get("after_ms", 0)
		if not _integer_in_range(after_variant, 0, MAX_SEQUENCE_TOTAL_MS):
			return _failure("invalid_param", "after_ms must be a non-negative integer")
		total_ms += int(after_variant)
		if total_ms > MAX_SEQUENCE_TOTAL_MS:
			return _failure("invalid_param", "sequence total duration exceeds 10s")
		if total_ms >= timeout_ms:
			return _failure("invalid_param", "sequence duration must be less than timeout_ms")
		if not entry.has("route") or typeof(entry["route"]) != TYPE_STRING:
			return _failure("invalid_param", "sequence route must be a string")
		var route: String = entry["route"]
		if route not in INPUT_ROUTES:
			return _failure("invalid_param", "sequence contains unsupported route: %s" % route)
		if not entry.has("data") or typeof(entry["data"]) != TYPE_DICTIONARY:
			return _failure("invalid_param", "sequence data must be an object")
		var child_verdict := _validate_child(route, entry["data"])
		if not bool(child_verdict.get("ok", false)):
			return child_verdict
	return {"ok": true, "total_ms": total_ms}


static func _validate_child(route: String, data: Dictionary) -> Dictionary:
	match route:
		"runtime/input/key":
			return _validate_key(data)
		"runtime/input/mouse":
			return _validate_mouse(data)
		"runtime/input/gamepad":
			return _validate_gamepad(data)
		"runtime/input/touch":
			return _validate_touch(data)
		"runtime/input/action":
			return _validate_action(data)
		_:
			return _failure("invalid_param", "sequence contains unsupported route: %s" % route)


static func _dispatch_child(route: String, data: Dictionary) -> Dictionary:
	match route:
		"runtime/input/key":
			return key(data)
		"runtime/input/mouse":
			return mouse(data)
		"runtime/input/gamepad":
			return gamepad(data)
		"runtime/input/touch":
			return touch(data)
		"runtime/input/action":
			return action(data)
		_:
			return _failure("invalid_param", "sequence contains unsupported route: %s" % route)


static func _validate_position(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_ARRAY:
		return _failure("invalid_param", "position must be a two-number array")
	var position: Array = value
	if position.size() != 2 or not _is_number(position[0]) or not _is_number(position[1]):
		return _failure("invalid_param", "position must be a two-number array")
	for component in position:
		var number := float(component)
		if not is_finite(number) or absf(number) > MAX_POSITION_COMPONENT:
			return _failure("invalid_param", "position components must be finite and bounded")
	return {"ok": true}


static func _position_value(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))


static func _validate_optional_bool(payload: Dictionary, key_name: String) -> Dictionary:
	if payload.has(key_name) and typeof(payload[key_name]) != TYPE_BOOL:
		return _failure("invalid_param", "%s must be a boolean" % key_name)
	return {"ok": true}


static func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT


static func _integer_in_range(value: Variant, minimum: int, maximum: int) -> bool:
	if typeof(value) == TYPE_INT:
		return value >= minimum and value <= maximum
	if typeof(value) != TYPE_FLOAT:
		return false
	var number := float(value)
	return (
		is_finite(number)
		and number == floor(number)
		and number >= float(minimum)
		and number <= float(maximum)
	)


static func _operation_timeout(payload: Dictionary) -> int:
	if not payload.has("timeout_ms"):
		return DEFAULT_OPERATION_TIMEOUT_MS
	var raw: Variant = payload["timeout_ms"]
	if not _integer_in_range(raw, 1, MAX_OPERATION_TIMEOUT_MS):
		return -1
	return int(raw)


static func _success(fields: Dictionary) -> Dictionary:
	var result := {
		"changed": bool(fields.get("changed", true)),
		"undoable": false,
	}
	for key_name in fields:
		if key_name != "changed":
			result[key_name] = fields[key_name]
	return {"ok": true, "result": result}


static func _failure(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
