@tool
extends SceneTree

const Service := preload("res://addons/gdapi/runtime/services/bulk_deploy_service.gd")


class FakeBridge:
	extends RefCounted
	var devices_result: Dictionary = {"ok": true, "devices": []}
	var deploy_results: Dictionary = {}
	var deploy_calls: Array = []

	func devices() -> Dictionary:
		return devices_result

	func deploy(body: Dictionary) -> Dictionary:
		deploy_calls.append(String(body.get("serial", "")))
		return deploy_results.get(String(body.get("serial", "")), {"ok": true})


var passed := 0
var failed := 0


func _init() -> void:
	print("Running bulk deploy service tests...")
	call_deferred("_run")


func _run() -> void:
	await test_stale_device_snapshot_rejects_before_deploy()
	await test_stale_artifact_rejects_before_deploy()
	await test_partial_failure_reports_sorted_terminal_states()
	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)


func assert_eq(actual: Variant, expected: Variant, context: String) -> void:
	if actual == expected:
		passed += 1
		print("  PASS: %s" % context)
	else:
		failed += 1
		print("  FAIL: %s - expected '%s', got '%s'" % [context, expected, actual])


func _body() -> Dictionary:
	return {
		"serials": ["ok", "offline", "fail"],
		"apk_path": "res://bulk-deploy-test.apk",
		"package": "org.example.game",
		"activity": "org.example.game.Main",
	}


func _write_artifact(contents: String) -> void:
	var file := FileAccess.open("res://bulk-deploy-test.apk", FileAccess.WRITE)
	file.store_string(contents)
	file.close()


func _remove_artifact() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path("res://bulk-deploy-test.apk"))


func _devices() -> Array:
	return [
		{"serial": "ok", "state": "device"},
		{"serial": "offline", "state": "offline"},
		{"serial": "fail", "state": "device"},
	]


func test_stale_device_snapshot_rejects_before_deploy() -> void:
	_write_artifact("v1")
	var fake := FakeBridge.new()
	fake.devices_result = {"ok": true, "devices": _devices()}
	var body := _body()
	var plan := Service.plan(body, fake)
	fake.devices_result = {"ok": true, "devices": [{"serial": "ok", "state": "device"}]}
	body["plan_hash"] = plan.plan_hash
	var result := Service.apply(body, fake)
	assert_eq(result.code, "conflict", "device snapshot change rejects apply")
	assert_eq(fake.deploy_calls.size(), 0, "stale device plan deploys nothing")
	_remove_artifact()


func test_stale_artifact_rejects_before_deploy() -> void:
	_write_artifact("v1")
	var fake := FakeBridge.new()
	fake.devices_result = {"ok": true, "devices": _devices()}
	var body := _body()
	var plan := Service.plan(body, fake)
	_write_artifact("v2")
	body["plan_hash"] = plan.plan_hash
	var result := Service.apply(body, fake)
	assert_eq(result.code, "conflict", "artifact change rejects apply")
	assert_eq(fake.deploy_calls.size(), 0, "stale artifact plan deploys nothing")
	_remove_artifact()


func test_partial_failure_reports_sorted_terminal_states() -> void:
	_write_artifact("v1")
	var fake := FakeBridge.new()
	fake.devices_result = {"ok": true, "devices": _devices()}
	fake.deploy_results = {"ok": {"ok": true}, "fail": {"ok": false, "code": "godot_error"}}
	var body := _body()
	var plan := Service.plan(body, fake)
	body["plan_hash"] = plan.plan_hash
	var result := Service.apply(body, fake)
	assert_eq(
		result.devices.map(func(item): return item.serial),
		["fail", "offline", "ok"],
		"partial failure devices are sorted"
	)
	assert_eq(
		result.devices.map(func(item): return item.status),
		["failed", "offline", "deployed"],
		"partial failure reports terminal states"
	)
	assert_eq(result.changed, true, "partial success reports changed")
	_remove_artifact()
