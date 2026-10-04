@tool
extends SceneTree

const Guard := preload("res://addons/gdapi/runtime/services/network_target_guard.gd")
const NetworkService := preload("res://addons/gdapi/runtime/services/network_service.gd")

var passed := 0
var failed := 0


func _init() -> void:
	_test_scheme_allowlist()
	_test_structural_rejections()
	_test_origin_components()
	_test_redirect_uri_references()
	_test_equivalent_ipv6_origins()
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


func _test_origin_components() -> void:
	var default_http := Guard.authorize("HTTP://EXAMPLE.COM?request=1")
	_assert_eq(default_http.scheme, "http", "origin scheme is case insensitive")
	_assert_eq(default_http.host.to_lower(), "example.com", "query is not part of origin host")
	_assert_eq(default_http.port, 80, "http effective port")
	_assert_eq(
		default_http.url,
		"http://EXAMPLE.COM/?request=1",
		"authority-only URL is normalized with a path"
	)
	var default_https := Guard.authorize("https://example.com/")
	var explicit_https := Guard.authorize("https://example.com:443/")
	_assert_eq(default_https.port, explicit_https.port, "explicit default port has same origin")
	_assert_eq(default_https.port, 443, "https effective port")
	_assert_eq(Guard.authorize("http://example.com:8080/").port, 8080, "nondefault origin port")


func _test_redirect_uri_references() -> void:
	var current := "http://127.0.0.1:8080/dir/start?old=1"
	_assert_eq(
		NetworkService._resolve_redirect_url(current, "next"),
		"http://127.0.0.1:8080/dir/next",
		"relative path resolves against the current directory"
	)
	_assert_eq(
		NetworkService._resolve_redirect_url(current, "?next=2"),
		"http://127.0.0.1:8080/dir/start?next=2",
		"query-only reference replaces the query"
	)
	_assert_eq(
		NetworkService._resolve_redirect_url(current, "/a//b"),
		"http://127.0.0.1:8080/a//b",
		"repeated path slashes are preserved"
	)


func _test_equivalent_ipv6_origins() -> void:
	var compressed := Guard.authorize("http://[::1]:8080/start")
	var expanded := Guard.authorize("http://[0:0:0:0:0:0:0:1]:8080/next")
	_assert_true(compressed.ok and expanded.ok, "equivalent IPv6 literals are authorized")
	_assert_eq(
		compressed.canonical_host,
		expanded.canonical_host,
		"equivalent IPv6 literals have identical canonical hosts"
	)
	_assert_true(
		NetworkService._same_origin(compressed, expanded),
		"equivalent IPv6 literals remain same-origin"
	)


func _assert_true(value: bool, context: String) -> void:
	_assert_eq(value, true, context)


func _assert_eq(actual: Variant, expected: Variant, context: String) -> void:
	if actual == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s expected=%s actual=%s" % [context, expected, actual])
