# gdlint: ignore=max-returns
@tool
extends RefCounted

const InputOps := preload("res://addons/gdapi/runtime/runtime_input_ops.gd")
const NodeOps := preload("res://addons/gdapi/runtime/runtime_node_ops.gd")
const MAX_EVENTS := 1000
const MAX_MONITORS := 32
var _epoch := 0
var _serial := 0
var _recording: Dictionary = {}
var _monitors: Dictionary = {}
var _replay: Dictionary = {}


func reset() -> void:
	_epoch += 1
	_recording.clear()
	_monitors.clear()
	if not _replay.is_empty():
		_replay["status"] = "cancelled"


func capture(event: InputEvent) -> void:
	if _recording.get("status", "") != "recording" or _replay.get("status", "") == "running":
		return
	var route := ""
	var data: Dictionary = {}
	if event is InputEventKey:
		if event.echo:
			return
		route = "runtime/input/key"
		data = {
			"keycode": event.keycode if event.keycode != 0 else event.physical_keycode,
			"pressed": event.pressed
		}
	elif event is InputEventMouseButton:
		route = "runtime/input/mouse"
		data = {
			"kind": "button",
			"button": event.button_index,
			"pressed": event.pressed,
			"position": [event.position.x, event.position.y]
		}
	elif event is InputEventMouseMotion:
		route = "runtime/input/mouse"
		data = {"kind": "motion", "position": [event.position.x, event.position.y]}
	elif event is InputEventJoypadButton:
		route = "runtime/input/gamepad"
		data = {"button": event.button_index, "device": event.device, "pressed": event.pressed}
	elif event is InputEventJoypadMotion:
		route = "runtime/input/gamepad"
		data = {
			"kind": "axis", "axis": event.axis, "device": event.device, "value": event.axis_value
		}
	elif event is InputEventScreenTouch:
		route = "runtime/input/touch"
		data = {
			"index": event.index,
			"pressed": event.pressed,
			"position": [event.position.x, event.position.y]
		}
	elif event is InputEventAction:
		route = "runtime/input/action"
		data = {"action": String(event.action), "pressed": event.pressed}
	if route.is_empty() or not InputOps._validate_child(route, data).get("ok", false):
		return
	var events: Array = _recording.events
	events.append(
		{
			"cursor": events.size() + 1,
			"at_ms": Time.get_ticks_msec() - int(_recording.started_ms),
			"frame": Engine.get_process_frames() - int(_recording.started_frame),
			"route": route,
			"data": data
		}
	)
	if events.size() >= int(_recording.max_events):
		_recording.status = "limit_reached"


func tick() -> void:
	var now := Time.get_ticks_msec()
	for id in _monitors:
		var monitor: Dictionary = _monitors[id]
		if monitor.status != "running" or now < int(monitor.next_ms):
			continue
		monitor.next_ms = now + int(monitor.interval_ms)
		var observed := NodeOps.get_property(monitor.target)
		if not observed.get("ok", false):
			monitor.status = "target_missing"
			_append_sample(
				monitor,
				{
					"error": observed.get("error", "target unavailable"),
					"code": observed.get("code", "not_found")
				}
			)
		elif monitor.get("last", null) != observed.result.value:
			monitor.last = observed.result.value
			_append_sample(monitor, {"value": observed.result.value})


func _append_sample(monitor: Dictionary, fields: Dictionary) -> void:
	monitor.cursor = int(monitor.cursor) + 1
	fields.merge(
		{
			"cursor": monitor.cursor,
			"at_ms": Time.get_ticks_msec() - int(monitor.started_ms),
			"frame": Engine.get_process_frames()
		},
		true
	)
	monitor.samples.append(fields)
	if monitor.samples.size() > MAX_EVENTS:
		monitor.samples.pop_front()


func dispatch(op: String, payload: Dictionary) -> Dictionary:
	match op:
		"runtime/recording/start":
			if _recording.get("status", "") == "recording":
				return _fail("conflict", "recording is already active")
			var cap: Variant = payload.get("max_events", 100)
			if not _integer(cap, 1, MAX_EVENTS):
				return _fail("invalid_param", "max_events must be 1..1000")
			_serial += 1
			_recording = {
				"recording_id": str(_serial),
				"status": "recording",
				"started_ms": Time.get_ticks_msec(),
				"started_frame": Engine.get_process_frames(),
				"max_events": int(cap),
				"events": []
			}
			return _ok(
				{
					"recording_id": _recording.recording_id,
					"status": _recording.status,
					"changed": true
				}
			)
		"runtime/recording/stop":
			if _recording.is_empty():
				return _fail("not_found", "recording not found")
			var changed: bool = _recording.status == "recording"
			if changed:
				_recording.status = "stopped"
			return _ok(
				{
					"recording_id": _recording.recording_id,
					"status": _recording.status,
					"count": _recording.events.size(),
					"changed": changed
				}
			)
		"runtime/recording/read":
			if _recording.is_empty():
				return _fail("not_found", "recording not found")
			return _page(
				_recording.events,
				payload,
				{"recording_id": _recording.recording_id, "status": _recording.status}
			)
		"runtime/recording/replay":
			return await _play(payload)
		"runtime/recording/cancel":
			var changed: bool = _replay.get("status", "") == "running"
			if changed:
				_replay.status = "cancelled"
			return _ok({"changed": changed, "replay": _replay.duplicate(true)})
		"runtime/monitor/start":
			return _start_monitor(payload)
		"runtime/monitor/read", "runtime/monitor/stop":
			var id := String(payload.get("monitor_id", ""))
			if not _monitors.has(id):
				return _fail("not_found", "monitor not found")
			var monitor: Dictionary = _monitors[id]
			if op.ends_with("stop"):
				var changed: bool = monitor.status == "running"
				if changed:
					monitor.status = "stopped"
				return _ok({"monitor_id": id, "status": monitor.status, "changed": changed})
			return _page(
				monitor.samples,
				payload,
				{"monitor_id": id, "status": monitor.status, "cursor": monitor.cursor}
			)
	return _fail("invalid_param", "unknown session operation")


func _start_monitor(payload: Dictionary) -> Dictionary:
	if _monitors.size() >= MAX_MONITORS:
		return _fail(
			"conflict", "monitor limit reached; reset the session to release subscriptions"
		)
	var interval: Variant = payload.get("interval_ms", 16)
	if not _integer(interval, 1, 25000):
		return _fail("invalid_param", "interval_ms must be 1..25000")
	var target := {
		"node_path": payload.get("node_path", ""), "property": payload.get("property", "")
	}
	var value := NodeOps.get_property(target)
	if not value.get("ok", false):
		return value
	_serial += 1
	var id := str(_serial)
	var monitor := {
		"target": target,
		"status": "running",
		"interval_ms": int(interval),
		"next_ms": 0,
		"started_ms": Time.get_ticks_msec(),
		"last": value.result.value,
		"samples": [],
		"cursor": 0
	}
	_append_sample(monitor, {"value": value.result.value})
	_monitors[id] = monitor
	return _ok({"monitor_id": id, "status": "running", "changed": true})


func _play(payload: Dictionary) -> Dictionary:
	if _replay.get("status", "") == "running":
		return _fail("conflict", "replay is already running")
	var events: Variant = payload.get("events", _recording.get("events", []))
	if typeof(events) != TYPE_ARRAY or events.size() > MAX_EVENTS:
		return _fail("invalid_param", "events must be an array of at most 1000 entries")
	var timeout: Variant = payload.get("timeout_ms", 5000)
	if not _integer(timeout, 1, 25000):
		return _fail("invalid_param", "timeout_ms must be 1..25000")
	var previous := 0
	for raw in events:
		if (
			typeof(raw) != TYPE_DICTIONARY
			or not _integer(raw.get("at_ms", -1), previous, 25000)
			or typeof(raw.get("data")) != TYPE_DICTIONARY
		):
			return _fail("invalid_param", "events require ordered at_ms, route and data")
		var verdict := InputOps._validate_child(String(raw.get("route", "")), raw.data)
		if not verdict.get("ok", false):
			return verdict
		previous = int(raw.at_ms)
	var tree := Engine.get_main_loop() as SceneTree
	var epoch := _epoch
	var start := Time.get_ticks_msec()
	_replay = {"status": "running", "completed_events": 0, "total_events": events.size()}
	var state := _replay
	for raw in events:
		# Always yield one frame so release/press edges remain observable even at equal timestamps.
		await tree.process_frame
		while (
			Time.get_ticks_msec() - start < int(raw.at_ms)
			and Time.get_ticks_msec() - start < int(timeout)
			and state.status == "running"
			and epoch == _epoch
		):
			await tree.process_frame
		if epoch != _epoch or state.status == "cancelled":
			state.status = "cancelled"
			break
		if Time.get_ticks_msec() - start >= int(timeout):
			state.status = "timed_out"
			break
		var executed := InputOps._dispatch_child(String(raw.route), raw.data)
		if not executed.get("ok", false):
			state.status = "failed"
			state.error = executed
			break
		state.completed_events = int(state.completed_events) + 1
	if state.status == "running":
		state.status = "completed"
	state.elapsed_ms = Time.get_ticks_msec() - start
	state.changed = int(state.completed_events) > 0
	return _ok(state.duplicate(true))


func _page(items: Array, payload: Dictionary, metadata: Dictionary) -> Dictionary:
	var after: Variant = payload.get("after_cursor", 0)
	var limit: Variant = payload.get("limit", 100)
	if not _integer(after, 0, 2147483647) or not _integer(limit, 1, 500):
		return _fail("invalid_param", "after_cursor and limit must be bounded integers")
	var page: Array = []
	for item in items:
		if int(item.cursor) > int(after) and page.size() < int(limit):
			page.append(item.duplicate(true))
	metadata["items"] = page
	metadata["next_cursor"] = int(page.back().cursor) if not page.is_empty() else int(after)
	metadata["oldest_cursor"] = int(items.front().cursor) if not items.is_empty() else 0
	return _ok(metadata)


static func _integer(value: Variant, low: int, high: int) -> bool:
	return (
		(typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT)
		and is_finite(float(value))
		and float(value) == floor(float(value))
		and value >= low
		and value <= high
	)


static func _ok(result: Dictionary) -> Dictionary:
	return {"ok": true, "result": result}


static func _fail(code: String, error: String) -> Dictionary:
	return {"ok": false, "code": code, "error": error}
