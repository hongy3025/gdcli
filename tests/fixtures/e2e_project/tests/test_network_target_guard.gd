@tool
extends SceneTree

const Guard := preload("res://addons/gdapi/runtime/services/network_target_guard.gd")

var passed := 0
var failed := 0


func _init() -> void:
	_test_scheme_allowlist()
	_test_structural_rejections()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _test_scheme_allowlist() -> void:
	_assert_true(Guard.authorize("https://example.com/").ok, "https allowed")
	_assert_true(Guard.authorize("http://example.com:8080/x").ok, "http with port allowed")
	var ftp := Guard.authorize("ftp://example.com/")
	_assert_eq(ftp.code, "permission_denied", "non-http scheme denied")


func _test_structural_rejections() -> void:
	_assert_eq(Guard.authorize("example.com").code, "invalid_param", "scheme required")
	_assert_eq(
		Guard.authorize("http://user:pass@example.com/").code, "invalid_param", "credentials denied"
	)
	_assert_eq(Guard.authorize("http://example.com/#frag").code, "invalid_param", "fragment denied")
	_assert_eq(Guard.authorize("http://:1/").code, "invalid_param", "empty host denied")
	_assert_eq(Guard.authorize("http://example.com:70000/").code, "invalid_param", "port range")


func _assert_true(value: bool, context: String) -> void:
	_assert_eq(value, true, context)


func _assert_eq(actual: Variant, expected: Variant, context: String) -> void:
	if actual == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s expected=%s actual=%s" % [context, expected, actual])
