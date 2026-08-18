@tool
extends SceneTree

const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")

var passed := 0
var failed := 0


func _init() -> void:
	test_audit_log_redacts_high_risk_payloads_recursively()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)


func test_audit_log_redacts_high_risk_payloads_recursively() -> void:
	var clean: Dictionary = (
		AuditLog
		. summarize(
			{
				"source": "secret_expression()",
				"stdout": "private output",
				"stderr": "private error",
				"environment": {"SAFE_NAME": "still private"},
				"request":
				{"headers": {"Accept": "application/json", "Authorization": "Bearer secret"}},
				"nested": {"token": "abc"},
				"safe": "value",
			}
		)
	)
	assert_eq(clean.get("source"), "[REDACTED]", "source is redacted")
	assert_eq(clean.get("stdout"), "[REDACTED]", "stdout is redacted")
	assert_eq(clean.get("stderr"), "[REDACTED]", "stderr is redacted")
	assert_eq(clean.get("environment"), "[REDACTED]", "environment is redacted")
	assert_eq(clean.get("request", {}).get("headers"), "[REDACTED]", "nested headers are redacted")
	assert_eq(clean.get("nested", {}).get("token"), "[REDACTED]", "nested token is redacted")
	assert_eq(clean.get("safe"), "value", "safe value remains useful")


func assert_eq(actual, expected, context: String) -> void:
	if actual == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s expected=%s actual=%s" % [context, expected, actual])
