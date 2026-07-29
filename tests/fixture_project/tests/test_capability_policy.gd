@tool
extends SceneTree

const CapabilityPolicy := preload("res://addons/gdapi/runtime/capability_policy.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")

const POLICY_PATH := "res://.godot/gdapi-policy.json"

var passed := 0
var failed := 0


func _init() -> void:
	_remove_policy()
	test_missing_policy_denies()
	test_force_and_capability_are_both_required()
	test_invalid_policy_shapes_fail_closed()
	test_policy_reloads_to_denial_after_malformed_replacement()
	test_audit_log_redacts_high_risk_payloads_recursively()
	_remove_policy()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)


func test_missing_policy_denies() -> void:
	_remove_policy()
	var policy := CapabilityPolicy.new()
	assert_eq(
		policy.authorize("process", "process/run", {"force": true}).get("code", ""),
		"permission_denied",
		"missing policy denies"
	)


func test_force_and_capability_are_both_required() -> void:
	_write_policy({"version": 1, "capabilities": {"process": {"enabled": true}}})
	var policy := CapabilityPolicy.new()
	assert_eq(
		policy.authorize("process", "process/run", {}).get("code", ""),
		"unsafe_operation",
		"enabled capability still requires force"
	)
	assert_true(
		policy.authorize("process", "process/run", {"force": true}).get("ok", false),
		"enabled capability with force is authorized"
	)


func test_invalid_policy_shapes_fail_closed() -> void:
	for invalid_policy in [
		{"version": 1.5, "capabilities": {"process": {"enabled": true}}},
		{"version": 1, "capabilities": {"process": {"enabled": true}}, "unknown": true},
		{"version": 1, "capabilities": {"unknown": {"enabled": true}}},
		{"version": 1, "capabilities": {"process": {"enabled": "true"}}},
		{"version": 1, "capabilities": {"process": {"enabled": true, "max_timeout_ms": -1}}},
		{"version": 2, "capabilities": {"process": {"enabled": true}}},
	]:
		_write_policy(invalid_policy)
		var policy := CapabilityPolicy.new()
		assert_eq(
			policy.authorize("process", "process/run", {"force": true}).get("code", ""),
			"permission_denied",
			"invalid policy fails closed"
		)


func test_policy_reloads_to_denial_after_malformed_replacement() -> void:
	_write_policy({"version": 1, "capabilities": {"process": {"enabled": true}}})
	var policy := CapabilityPolicy.new()
	assert_true(
		policy.authorize("process", "process/run", {"force": true}).get("ok", false),
		"initial policy authorizes"
	)
	# FileAccess modified timestamps have one-second precision on supported fixture filesystems.
	OS.delay_msec(1100)
	_write_raw("{")
	assert_eq(
		policy.authorize("process", "process/run", {"force": true}).get("code", ""),
		"permission_denied",
		"malformed replacement reloads to denial"
	)


func test_audit_log_redacts_high_risk_payloads_recursively() -> void:
	var clean: Dictionary = AuditLog.summarize(
		{
			"source": "secret_expression()",
			"stdout": "private output",
			"stderr": "private error",
			"environment": {"SAFE_NAME": "still private"},
			"request": {"headers": {"Accept": "application/json", "Authorization": "Bearer secret"}},
			"nested": {"token": "abc"},
			"safe": "value",
		}
	)
	assert_eq(clean.get("source"), "[REDACTED]", "source is redacted")
	assert_eq(clean.get("stdout"), "[REDACTED]", "stdout is redacted")
	assert_eq(clean.get("stderr"), "[REDACTED]", "stderr is redacted")
	assert_eq(clean.get("environment"), "[REDACTED]", "environment is redacted")
	assert_eq(clean.get("request", {}).get("headers"), "[REDACTED]", "nested headers are redacted")
	assert_eq(clean.get("nested", {}).get("token"), "[REDACTED]", "nested token is redacted")
	assert_eq(clean.get("safe"), "value", "safe value remains useful")


func _write_policy(policy: Dictionary) -> void:
	_write_raw(JSON.stringify(policy))


func _write_raw(contents: String) -> void:
	var file := FileAccess.open(POLICY_PATH, FileAccess.WRITE)
	file.store_string(contents)
	file.close()


func _remove_policy() -> void:
	if FileAccess.file_exists(POLICY_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(POLICY_PATH))


func assert_true(value: bool, context: String) -> void:
	assert_eq(value, true, context)


func assert_eq(actual, expected, context: String) -> void:
	if actual == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s expected=%s actual=%s" % [context, expected, actual])
