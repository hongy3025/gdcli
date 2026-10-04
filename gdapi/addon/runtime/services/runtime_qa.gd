# gdlint: ignore=max-returns
@tool
extends RefCounted

const NodeOps := preload("res://addons/gdapi/runtime/runtime_node_ops.gd")
const InputOps := preload("res://addons/gdapi/runtime/runtime_input_ops.gd")
const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const Codec := preload("res://addons/gdapi/runtime/variant_codec.gd")
const Condition := preload("res://addons/gdapi/runtime/runtime_condition.gd")
const ALLOWED_OPS := [
	"runtime/node/get",
	"runtime/node/set",
	"runtime/node/call",
	"runtime/assert/node_exists",
	"runtime/assert/property_equals",
	"runtime/assert/condition",
	"runtime/assert/signal_received",
	"runtime/signal/emit",
	"runtime/input/key",
	"runtime/input/mouse",
	"runtime/input/gamepad",
	"runtime/input/touch",
	"runtime/input/action",
	"runtime/assert/screen_text",
	"wait"
]
var _reports: Dictionary = {}
var _serial := 0
var _epoch := 0
var _branches: Array[Node] = []


func reset() -> void:
	_epoch += 1
	_reports.clear()
	for branch in _branches:
		if is_instance_valid(branch):
			branch.queue_free()
	_branches.clear()


func dispatch(op: String, payload: Dictionary) -> Dictionary:
	if op == "runtime/test/report":
		var id := String(payload.get("report_id", ""))
		if not _reports.has(id):
			return _fail("not_found", "report not found")
		return {"ok": true, "result": _reports[id].duplicate(true)}
	if op == "runtime/assert/screen_text":
		return await assert_screen_text(payload)
	return await _run(payload, op == "runtime/test/stress")


func _scenario(payload: Dictionary) -> Dictionary:
	var scenario: Variant = payload.get("scenario", {})
	if payload.has("script_path"):
		var loaded := _read_scenario_file(String(payload.script_path))
		if not loaded.ok:
			return loaded
		scenario = loaded.value
	if (
		typeof(scenario) != TYPE_DICTIONARY
		or typeof(scenario.get("steps")) != TYPE_ARRAY
		or scenario.steps.size() > 100
	):
		return _fail("invalid_param", "scenario requires at most 100 steps")
	scenario = scenario.duplicate(true)
	for step in scenario.steps:
		if (
			typeof(step) != TYPE_DICTIONARY
			or String(step.get("op", "")) not in ALLOWED_OPS
			or typeof(step.get("data", {})) != TYPE_DICTIONARY
		):
			return _fail(
				"invalid_param", "scenario step operation is not in the controlled allowlist"
			)
		if step.op == "wait" and not _integer(step.get("data", {}).get("duration_ms", 0), 0, 25000):
			return _fail("invalid_param", "wait duration_ms must be 0..25000")
	if scenario.has("scene_path"):
		var guarded := _project_path(String(scenario.scene_path), "tscn")
		if not guarded.get("ok", false):
			return guarded
		scenario.scene_path = guarded.path
	return {"ok": true, "scenario": scenario}


func _read_scenario_file(path: String) -> Dictionary:
	var guarded := _project_path(path, "json")
	if not guarded.get("ok", false):
		return guarded
	if not FileAccess.file_exists(guarded.path):
		return _fail("not_found", "scenario script not found")
	var file := FileAccess.open(guarded.path, FileAccess.READ)
	if file == null or file.get_length() > 1048576:
		return _fail("invalid_param", "scenario script must be readable and at most 1 MiB")
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK:
		return _fail(
			"invalid_param", "scenario script must be declarative JSON, not executable source"
		)
	return {"ok": true, "value": parser.data}


func _run(payload: Dictionary, stress: bool) -> Dictionary:
	var validated := _scenario(payload)
	if not validated.get("ok", false):
		return validated
	var iterations: Variant = payload.get("iterations", 10) if stress else 1
	var concurrency: Variant = payload.get("concurrency", 2) if stress else 1
	var timeout: Variant = payload.get("timeout_ms", 5000)
	if (
		not _integer(iterations, 1, 100)
		or not _integer(concurrency, 1, 8)
		or not _integer(timeout, 1, 25000)
	):
		return _fail(
			"invalid_param",
			"iterations 1..100, concurrency 1..8 and timeout_ms 1..25000 are required"
		)
	if _reports.size() >= 100:
		_reports.erase(_reports.keys().front())
	_serial += 1
	var id := str(_serial)
	var start := Time.get_ticks_msec()
	var deadline := start + int(timeout)
	var epoch := _epoch
	var report := {
		"report_id": id,
		"status": "running",
		"kind": "stress" if stress else "scenario",
		"iterations": int(iterations),
		"concurrency": int(concurrency),
		"completed_iterations": 0,
		"passed_iterations": 0,
		"failed_iterations": 0,
		"samples": [],
		"elapsed_ms": 0,
		"changed": false
	}
	_reports[id] = report
	var tree := Engine.get_main_loop() as SceneTree
	var batch_start := 0
	while batch_start < int(iterations) and Time.get_ticks_msec() < deadline and epoch == _epoch:
		var batch := {"pending": 0}
		for index in range(batch_start, mini(batch_start + int(concurrency), int(iterations))):
			batch.pending = int(batch.pending) + 1
			_worker(validated.scenario, index, deadline, epoch, report, batch)
		while int(batch.pending) > 0:
			await tree.process_frame
		batch_start += int(concurrency)
	report.elapsed_ms = Time.get_ticks_msec() - start
	if epoch != _epoch:
		report.status = "cancelled"
	elif Time.get_ticks_msec() >= deadline:
		report.status = "timed_out"
	elif int(report.failed_iterations) > 0:
		report.status = "failed"
	else:
		report.status = "passed"
	return {"ok": true, "result": report.duplicate(true)}


func _worker(
	scenario: Dictionary,
	index: int,
	deadline: int,
	epoch: int,
	report: Dictionary,
	batch: Dictionary
) -> void:
	var start := Time.get_ticks_msec()
	var tree := Engine.get_main_loop() as SceneTree
	var branch := Node.new()
	branch.name = "GdApiTest_%s_%s" % [report.report_id, index]
	var host: Node = tree.current_scene if tree.current_scene != null else tree.root
	host.add_child(branch)
	_branches.append(branch)
	var steps: Array = []
	var passed := true
	if scenario.has("scene_path"):
		var resource := load(String(scenario.scene_path)) as PackedScene
		if resource == null:
			passed = false
			steps.append(
				{
					"ok": false,
					"code": "invalid_param",
					"error": "scene_path must load a PackedScene"
				}
			)
		else:
			var instance := resource.instantiate()
			instance.name = "Scene"
			branch.add_child(instance)
	# Let _ready and first processing frame execute before asserting a loaded scene.
	await tree.process_frame
	if passed:
		for step in scenario.steps:
			if Time.get_ticks_msec() >= deadline or epoch != _epoch:
				passed = false
				steps.append(
					_fail(
						"timeout" if epoch == _epoch else "conflict",
						"scenario deadline or reset reached"
					)
				)
				break
			var data: Dictionary = _rewrite_paths(
				step.get("data", {}), String(branch.get_path()) + "/Scene"
			)
			data["timeout_ms"] = maxi(1, deadline - Time.get_ticks_msec())
			var result := await _step(String(step.op), data, deadline, epoch)
			steps.append(result)
			report.changed = (
				bool(report.changed) or bool(result.get("result", {}).get("changed", false))
			)
			if not result.get("ok", false):
				passed = false
				break
	if is_instance_valid(branch):
		branch.free()
	_branches.erase(branch)
	report.completed_iterations = int(report.completed_iterations) + 1
	if passed:
		report.passed_iterations = int(report.passed_iterations) + 1
	else:
		report.failed_iterations = int(report.failed_iterations) + 1
	report.samples.append(
		{
			"iteration": index,
			"passed": passed,
			"elapsed_ms": Time.get_ticks_msec() - start,
			"steps": steps
		}
	)
	batch.pending = int(batch.pending) - 1


func _step(op: String, data: Dictionary, deadline: int, epoch: int) -> Dictionary:
	var result: Dictionary
	match op:
		"wait":
			var tree := Engine.get_main_loop() as SceneTree
			var until := mini(deadline, Time.get_ticks_msec() + int(data.get("duration_ms", 0)))
			while Time.get_ticks_msec() < until and epoch == _epoch:
				await tree.process_frame
			result = (
				_fail("timeout", "scenario wait timed out or was reset")
				if Time.get_ticks_msec() >= deadline or epoch != _epoch
				else {"ok": true, "result": {"waited": true}}
			)
		"runtime/node/get":
			result = NodeOps.get_property(data)
		"runtime/node/set":
			result = NodeOps.set_property(data)
		"runtime/node/call":
			result = NodeOps.call_method(data)
		"runtime/signal/emit":
			result = NodeOps.signal_emit(data)
		"runtime/assert/signal_received":
			result = await _signal_assert(data, deadline, epoch)
		"runtime/assert/screen_text":
			result = await assert_screen_text(data)
		"runtime/assert/node_exists", "runtime/assert/property_equals", "runtime/assert/condition":
			result = await _poll_assertion(op, data, deadline, epoch)
		_:
			result = InputOps._dispatch_child(op, data)
	return result


func _poll_assertion(op: String, data: Dictionary, deadline: int, epoch: int) -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	while epoch == _epoch and Time.get_ticks_msec() < deadline:
		var result: Dictionary
		if op.ends_with("node_exists"):
			result = NodeOps.info(data)
		elif op.ends_with("property_equals"):
			result = _property_check(data)
		else:
			result = Condition.evaluate(data.get("condition", {}))
			if result.get("ok", false) and not result.get("value", false):
				result = _fail("timeout", "condition not satisfied")
		if (
			result.get("ok", false)
			or result.get("code", "") not in ["timeout", "not_found", "assertion_failed"]
		):
			return result
		await tree.process_frame
	return _fail("timeout", "scenario assertion timed out or was reset")


func _property_check(data: Dictionary) -> Dictionary:
	if not data.has("value"):
		return _fail("missing_param", "property assertion value is required")
	var actual := NodeOps.get_property(data)
	if not actual.get("ok", false):
		return actual
	var expected := Codec.decode(data.value)
	var decoded := Codec.decode(actual.result.value)
	if not expected.get("ok", false) or not decoded.get("ok", false):
		return _fail("invalid_param", "property assertion contains an invalid typed value")
	if NodeOps._variants_equal(decoded.value, expected.value):
		return {"ok": true, "value": true, "result": {"passed": true, "value": actual.result.value}}
	return _fail("timeout", "property not satisfied")


func _signal_assert(data: Dictionary, deadline: int, epoch: int) -> Dictionary:
	var lookup := NodeOps._resolve(String(data.get("node_path", "")))
	if not lookup.get("ok", false):
		return lookup
	var node: Node = lookup.node
	var signal_name := String(data.get("signal", ""))
	var checked := NodeOps._require_signal(node, signal_name)
	if not checked.get("ok", false):
		return checked
	var completion := {"received": false}
	var callback := func(_a0 = null, _a1 = null, _a2 = null, _a3 = null) -> void:
		completion.received = Time.get_ticks_msec() < deadline and epoch == _epoch
	var error := node.connect(signal_name, callback)
	if error != OK:
		return _fail("godot_error", "signal connection failed")
	var tree := Engine.get_main_loop() as SceneTree
	while (
		not completion.received
		and Time.get_ticks_msec() < deadline
		and epoch == _epoch
		and is_instance_valid(node)
	):
		await tree.process_frame
	if is_instance_valid(node) and node.is_connected(signal_name, callback):
		node.disconnect(signal_name, callback)
	return (
		{"ok": true, "result": {"passed": true}}
		if completion.received
		else _fail("timeout", "signal assertion timed out or reset")
	)


func assert_screen_text(payload: Dictionary) -> Dictionary:
	var expected: Variant = payload.get("text", null)
	var timeout: Variant = payload.get("timeout_ms", 5000)
	var match_mode := String(payload.get("match", "contains"))
	if (
		typeof(expected) != TYPE_STRING
		or not _integer(timeout, 1, 25000)
		or match_mode not in ["contains", "equals"]
	):
		return _fail(
			"invalid_param", "text, match contains|equals, and bounded timeout_ms are required"
		)
	var tree := Engine.get_main_loop() as SceneTree
	var deadline := Time.get_ticks_msec() + int(timeout)
	var epoch := _epoch
	var texts: Array = []
	while Time.get_ticks_msec() < deadline and epoch == _epoch:
		var root := tree.root.get_node_or_null(NodePath(String(payload.get("node_path", "/root"))))
		if root == null:
			return _fail("not_found", "screen text root not found")
		texts.clear()
		_collect_text(root, texts)
		for entry in texts:
			if (
				entry.text == expected
				if match_mode == "equals"
				else String(entry.text).contains(String(expected))
			):
				return {
					"ok": true,
					"result":
					{
						"matched": true,
						"text": entry.text,
						"node_path": entry.node_path,
						"source": "Control.text"
					}
				}
		await tree.process_frame
	return {
		"ok": false,
		"code": "timeout",
		"error": "visible Control text assertion timed out",
		"details": {"texts": texts}
	}


static func _collect_text(node: Node, out: Array) -> void:
	if out.size() >= 200:
		return
	if node is Control and node.is_visible_in_tree():
		if node is Label or node is Button or node is LineEdit or node is TextEdit:
			out.append({"node_path": String(node.get_path()), "text": String(node.get("text"))})
		elif node is RichTextLabel:
			out.append({"node_path": String(node.get_path()), "text": node.get_parsed_text()})
	for child in node.get_children():
		_collect_text(child, out)


static func _rewrite_paths(value: Variant, scene_path: String) -> Variant:
	if typeof(value) == TYPE_DICTIONARY:
		var output: Dictionary = {}
		for key in value:
			if (
				key == "node_path"
				and typeof(value[key]) == TYPE_STRING
				and String(value[key]).begins_with("$scene")
			):
				output[key] = scene_path + String(value[key]).trim_prefix("$scene")
			else:
				output[key] = _rewrite_paths(value[key], scene_path)
		return output
	if typeof(value) == TYPE_ARRAY:
		var output: Array = []
		for child in value:
			output.append(_rewrite_paths(child, scene_path))
		return output
	return value


static func _project_path(path: String, extension: String) -> Dictionary:
	var guarded := PathGuard.validate(path, "read")
	if not guarded.get("ok", false):
		return guarded
	var normalized := String(guarded.path)
	if (
		not normalized.begins_with("res://")
		or normalized.begins_with("res://addons/")
		or normalized.begins_with("res://.godot/")
		or normalized.get_extension() != extension
	):
		return _fail(
			"permission_denied",
			"QA paths must be project-local .%s outside addons/.godot" % extension
		)
	return guarded


static func _integer(value: Variant, low: int, high: int) -> bool:
	return (
		(typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT)
		and is_finite(float(value))
		and float(value) == floor(float(value))
		and value >= low
		and value <= high
	)


static func _fail(code: String, error: String) -> Dictionary:
	return {"ok": false, "code": code, "error": error}
