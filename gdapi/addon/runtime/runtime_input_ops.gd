## 运行时 input 模拟实现
##
## 输入事件通过 Input.parse_input_event/action_press/action_release。
## 每个 op 都返回 {"ok":true, "result": {changed:true, undoable:false, event_type:...}}.

@tool
class_name GdApiRuntimeInputOps
extends RefCounted

const MAX_SEQUENCE_EVENTS := 100
const MAX_SEQUENCE_TOTAL_MS := 10000

## key:发送一个 InputEventKey
static func key(payload: Dictionary) -> Dictionary:
	var keycode: int = int(payload.get("keycode", 0))
	if keycode == 0:
		return {"ok": false, "code": "invalid_param", "error": "keycode is required"}
	var pressed: bool = bool(payload.get("pressed", true))
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	event.keycode = keycode
	event.pressed = pressed
	Input.parse_input_event(event)
	return {"ok": true, "result": {"changed": true, "undoable": false, "event_type": "key", "keycode": keycode, "pressed": pressed}}

## mouse:支持 button/motion 类型
static func mouse(payload: Dictionary) -> Dictionary:
	var kind: String = String(payload.get("kind", "button"))
	var pos_arr: Array = payload.get("position", [0, 0])
	var position := Vector2(float(pos_arr[0]), float(pos_arr[1])) if pos_arr.size() >= 2 else Vector2.ZERO
	match kind:
		"button":
			var button: int = int(payload.get("button", 1))
			if button < 1 or button > 8:
				return {"ok": false, "code": "invalid_param", "error": "mouse button must be 1..8"}
			var event := InputEventMouseButton.new()
			event.button_index = button
			event.position = position
			event.pressed = bool(payload.get("pressed", true))
			Input.parse_input_event(event)
			return {"ok": true, "result": {"changed": true, "undoable": false, "event_type": "button", "button": button, "pressed": event.pressed}}
		"motion":
			var event := InputEventMouseMotion.new()
			event.position = position
			event.relative = position
			Input.parse_input_event(event)
			return {"ok": true, "result": {"changed": true, "undoable": false, "event_type": "motion"}}
		_:
			return {"ok": false, "code": "invalid_param", "error": "mouse kind must be button or motion"}

## gamepad: button / axis
static func gamepad(payload: Dictionary) -> Dictionary:
	var device: int = int(payload.get("device", 0))
	var kind: String = String(payload.get("kind", "button"))
	match kind:
		"button":
			var button: int = int(payload.get("button", 0))
			var event := InputEventJoypadButton.new()
			event.device = device
			event.button_index = button
			event.pressed = bool(payload.get("pressed", true))
			Input.parse_input_event(event)
			return {"ok": true, "result": {"changed": true, "undoable": false, "event_type": "gamepad_button", "button": button, "pressed": event.pressed}}
		"axis":
			var axis: int = int(payload.get("axis", 0))
			var value: float = float(payload.get("value", 0.0))
			var event := InputEventJoypadMotion.new()
			event.device = device
			event.axis = axis
			event.axis_value = value
			Input.parse_input_event(event)
			return {"ok": true, "result": {"changed": true, "undoable": false, "event_type": "gamepad_axis", "axis": axis, "value": value}}
		_:
			return {"ok": false, "code": "invalid_param", "error": "gamepad kind must be button or axis"}

## touch:touch / drag
static func touch(payload: Dictionary) -> Dictionary:
	var index: int = int(payload.get("index", 0))
	var pos_arr: Array = payload.get("position", [0, 0])
	var position := Vector2(float(pos_arr[0]), float(pos_arr[1])) if pos_arr.size() >= 2 else Vector2.ZERO
	var pressed: bool = bool(payload.get("pressed", true))
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = position
	event.pressed = pressed
	Input.parse_input_event(event)
	return {"ok": true, "result": {"changed": true, "undoable": false, "event_type": "touch", "index": index, "pressed": pressed}}

## action: input.action_press/release
static func action(payload: Dictionary) -> Dictionary:
	var action_name: String = String(payload.get("action", ""))
	if action_name.is_empty():
		return {"ok": false, "code": "missing_param", "error": "action is required"}
	if not InputMap.has_action(action_name):
		return {"ok": false, "code": "invalid_param", "error": "action not in InputMap: %s" % action_name}
	if bool(payload.get("pressed", true)):
		Input.action_press(action_name)
	else:
		Input.action_release(action_name)
	return {"ok": true, "result": {"changed": true, "undoable": false, "event_type": "action", "action": action_name, "pressed": bool(payload.get("pressed", true))}}

## sequence:依次执行最多 100 个 event,累计 <= 10s。
static func sequence(payload: Dictionary) -> Dictionary:
	var events: Array = payload.get("events", [])
	if events.size() > MAX_SEQUENCE_EVENTS:
		return {"ok": false, "code": "invalid_param", "error": "sequence has more than 100 events"}
	var total_ms: int = 0
	var last_after_ms := 0
	for entry in events:
		if typeof(entry) != TYPE_DICTIONARY:
			return {"ok": false, "code": "invalid_param", "error": "sequence entries must be objects"}
		var after_ms: int = int(entry.get("after_ms", 0))
		if after_ms < 0:
			return {"ok": false, "code": "invalid_param", "error": "after_ms must be >= 0"}
		total_ms = max(total_ms, after_ms)
		last_after_ms = total_ms
	if total_ms > MAX_SEQUENCE_TOTAL_MS:
		return {"ok": false, "code": "invalid_param", "error": "sequence total duration exceeds 10s"}
	for entry in events:
		var after_ms: int = int(entry.get("after_ms", 0))
		var t: SceneTreeTimer = (Engine.get_main_loop() as SceneTree).create_timer(after_ms / 1000.0)
		await t.timeout
		var route: String = String(entry.get("route", ""))
		var data: Dictionary = entry.get("data", {})
		match route:
			"runtime/input/key":
				key(data)
			"runtime/input/mouse":
				mouse(data)
			"runtime/input/gamepad":
				gamepad(data)
			"runtime/input/touch":
				touch(data)
			"runtime/input/action":
				action(data)
			_:
				return {"ok": false, "code": "invalid_param", "error": "sequence contains unsupported route: %s" % route}
	return {"ok": true, "result": {"changed": true, "undoable": false, "event_type": "sequence", "events": events.size()}}
