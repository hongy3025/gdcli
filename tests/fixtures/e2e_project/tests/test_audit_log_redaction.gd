@tool
extends SceneTree

const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")

var passed := 0
var failed := 0


func _init() -> void:
	test_audit_log_redacts_high_risk_payloads_recursively()
	test_audit_log_redacts_url_userinfo_everywhere()
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


func test_audit_log_redacts_url_userinfo_everywhere() -> void:
	var secret_url := "https://user:URL_PASSWORD_SENTINEL@example.com:443/path?query=value"
	var safe_url := "https://[REDACTED]@example.com:443/path?query=value"
	var summary: Dictionary = (
		AuditLog
		. summarize(
			{
				"url": secret_url,
				"nested": [secret_url, {"message": "rejected " + secret_url}],
				secret_url: "safe",
				"plain": "https://example.com/path?query=value",
				"email": "user@example.com",
			}
		)
	)
	assert_eq(summary.url, safe_url, "URL userinfo is redacted")
	assert_eq(summary.nested[0], safe_url, "URL userinfo in arrays is redacted")
	assert_eq(summary.nested[1].message, "rejected " + safe_url, "URL in error text is redacted")
	assert_eq(summary.get(safe_url.left(64)), "safe", "URL dictionary keys are redacted")
	assert_eq(summary.plain, "https://example.com/path?query=value", "plain URL is preserved")
	assert_eq(summary.email, "user@example.com", "non-URL text is preserved")
	assert_eq(str(summary).contains("URL_PASSWORD_SENTINEL"), false, "no secret is readable")
	var large: Dictionary = {}
	for index in range(17):
		large[secret_url + str(index)] = index
	var bounded: Dictionary = AuditLog.summarize(large)
	assert_eq(str(bounded).contains("URL_PASSWORD_SENTINEL"), false, "bounded keys redact URLs")


func assert_eq(actual, expected, context: String) -> void:
	if actual == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s expected=%s actual=%s" % [context, expected, actual])
