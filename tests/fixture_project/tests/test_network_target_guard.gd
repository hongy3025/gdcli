@tool
extends SceneTree

const Guard := preload("res://addons/gdapi/runtime/services/network_target_guard.gd")
const Service := preload("res://addons/gdapi/runtime/services/network_service.gd")

var passed := 0
var failed := 0


func _init() -> void:
	_test_public_resolution_is_allowed()
	_test_private_and_mapped_addresses_are_denied()
	_test_redirect_limit_is_carried_into_request_spec()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _test_public_resolution_is_allowed() -> void:
	var result := Guard.authorize(
		"http://public.example/path", _policy(), Callable(self, "_resolve_public")
	)
	_assert_true(result.ok, "public resolved host is allowed")
	_assert_eq(result.addresses, ["8.8.8.8"], "resolved address is retained")


func _test_private_and_mapped_addresses_are_denied() -> void:
	var private := Guard.authorize(
		"http://public.example/path", _policy(), Callable(self, "_resolve_private")
	)
	_assert_eq(private.code, "permission_denied", "private resolved address is denied")
	var mapped := Guard.is_public_address("::ffff:127.0.0.1")
	_assert_eq(mapped, false, "mapped loopback is denied")
	_assert_eq(Guard.is_public_address("::1"), false, "IPv6 loopback is denied")


func _test_redirect_limit_is_carried_into_request_spec() -> void:
	var policy := _policy()
	policy["max_redirects"] = 3
	var result := Service.validate(
		{"url": "http://public.example/path", "force": true},
		policy,
		Callable(self, "_resolve_public")
	)
	_assert_true(result.ok, "network request validates")
	_assert_eq(result.get("max_redirects", 0), 3, "redirect policy is carried")


func _policy() -> Dictionary:
	return {
		"schemes": ["http"],
		"hosts": ["public.example"],
		"ports": [80],
		"allow_private": false,
		"max_timeout_ms": 5000,
		"max_response_bytes": 1048576,
		"max_redirects": 0,
	}


func _resolve_public(_host: String) -> Array:
	return ["8.8.8.8"]


func _resolve_private(_host: String) -> Array:
	return ["127.0.0.1"]


func _assert_true(value: bool, context: String) -> void:
	_assert_eq(value, true, context)


func _assert_eq(actual: Variant, expected: Variant, context: String) -> void:
	if actual == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s expected=%s actual=%s" % [context, expected, actual])
