@tool
extends SceneTree

const CaptureOps := preload("res://addons/gdapi/runtime/runtime_capture_ops.gd")
const Protocol := preload("res://addons/gdapi/runtime/runtime_protocol.gd")

class FakeTexture:
	extends RefCounted

	var width: int
	var height: int
	var readback_count := 0
	var width_delay_ms := 0
	var readback_delay_ms := 0

	func _init(p_width: int, p_height: int, p_width_delay_ms: int = 0,
			p_readback_delay_ms: int = 0) -> void:
		width = p_width
		height = p_height
		width_delay_ms = p_width_delay_ms
		readback_delay_ms = p_readback_delay_ms

	func get_width() -> int:
		if width_delay_ms > 0:
			OS.delay_msec(width_delay_ms)
		return width

	func get_height() -> int:
		return height

	func get_image() -> Image:
		readback_count += 1
		if readback_delay_ms > 0:
			OS.delay_msec(readback_delay_ms)
		return Image.create(width, height, false, Image.FORMAT_RGBA8)

var passed := 0
var failed := 0

func _init() -> void:
	print("Running GdApiRuntimeCaptureOps tests...\n")
	test_frames_validation_is_strict_and_bounded()
	test_camera_path_validation_is_strict()
	test_encoded_result_counts_protocol_envelope()
	test_oversized_texture_is_rejected_before_readback()
	test_expired_deadline_stops_before_readback()
	test_expiry_during_readback_never_returns_success()
	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)

func assert_eq(actual: Variant, expected: Variant, context: String = "") -> void:
	if actual == expected:
		passed += 1
		print("  PASS: %s" % context)
	else:
		failed += 1
		print("  FAIL: %s - expected '%s', got '%s'" % [context, expected, actual])

func assert_true(value: bool, context: String = "") -> void:
	assert_eq(value, true, context)

func assert_invalid(result: Dictionary, context: String) -> void:
	assert_eq(result.get("ok", true), false, context + " rejected")
	assert_eq(result.get("code", ""), "invalid_param", context + " code")

func test_frames_validation_is_strict_and_bounded() -> void:
	var valid := CaptureOps.validate_frames_payload({
		"count": 2.0,
		"interval_ms": 16,
		"timeout_ms": 5000,
	})
	assert_true(valid.get("ok", false), "integral JSON float accepted")
	for item in [
		{"payload": {"count": 1.5, "interval_ms": 16, "timeout_ms": 5000}, "name": "fractional count"},
		{"payload": {"count": 61, "interval_ms": 1, "timeout_ms": 5000}, "name": "count above max"},
		{"payload": {"count": 9.223372e18, "interval_ms": 1, "timeout_ms": 5000}, "name": "huge count"},
		{"payload": {"count": NAN, "interval_ms": 1, "timeout_ms": 5000}, "name": "NaN count"},
		{"payload": {"count": INF, "interval_ms": 1, "timeout_ms": 5000}, "name": "infinite count"},
		{"payload": {"count": 1, "interval_ms": -0.000001, "timeout_ms": 5000}, "name": "negative epsilon interval"},
		{"payload": {"count": 1, "interval_ms": INF, "timeout_ms": 5000}, "name": "infinite interval"},
		{"payload": {"count": 1, "interval_ms": 1001, "timeout_ms": 5000}, "name": "interval above max"},
		{"payload": {"count": 1, "interval_ms": 1, "timeout_ms": 1.5}, "name": "fractional timeout"},
		{"payload": {"count": 1, "interval_ms": 1, "timeout_ms": -0.000001}, "name": "negative epsilon timeout"},
		{"payload": {"count": 1, "interval_ms": 1, "timeout_ms": NAN}, "name": "NaN timeout"},
		{"payload": {"count": 1, "interval_ms": 1, "timeout_ms": INF}, "name": "infinite timeout"},
		{"payload": {"count": 1, "interval_ms": 1, "timeout_ms": 25001}, "name": "timeout above max"},
		{"payload": {"count": 2, "interval_ms": 10, "timeout_ms": 10}, "name": "duration at timeout"},
		{"payload": {"count": 60, "interval_ms": 1000, "timeout_ms": 25000}, "name": "duration above timeout"},
	]:
		assert_invalid(CaptureOps.validate_frames_payload(item.payload), item.name)

func test_camera_path_validation_is_strict() -> void:
	assert_true(CaptureOps.validate_camera_path("/root/RuntimeMain/MainCamera", true).get("ok", false),
		"absolute camera path accepted")
	for item in [
		{"value": 17, "name": "non-string camera path"},
		{"value": "RuntimeMain/MainCamera", "name": "relative camera path"},
		{"value": "/root/" + "x".repeat(1025), "name": "oversized camera path"},
	]:
		assert_invalid(CaptureOps.validate_camera_path(item.value, true), item.name)
	assert_true(CaptureOps.validate_camera_path("", false).get("ok", false),
		"empty optional camera path accepted")

func test_encoded_result_counts_protocol_envelope() -> void:
	var small := {"frames": [{"data_base64": "AAAA"}], "count": 1}
	assert_true(CaptureOps.protocol_result_fits(small), "small protocol result fits")
	var oversized := {"data_base64": "x".repeat(Protocol.MAX_MESSAGE_BYTES)}
	assert_eq(CaptureOps.protocol_result_fits(oversized), false, "protocol envelope overflow rejected")

func test_oversized_texture_is_rejected_before_readback() -> void:
	var texture := FakeTexture.new(3840, 2160)
	var result: Dictionary = CaptureOps.capture_texture(texture, {})
	assert_invalid(result, "oversized source texture")
	assert_eq(texture.readback_count, 0, "oversized source performs no CPU readback")

func test_expired_deadline_stops_before_readback() -> void:
	var texture := FakeTexture.new(64, 64, 5)
	var deadline := Time.get_ticks_msec() + 1
	var result: Dictionary = CaptureOps.capture_texture(texture, {}, {}, deadline)
	assert_eq(result.get("code", ""), "timeout", "deadline before readback returns timeout")
	assert_eq(texture.readback_count, 0, "expired deadline performs no CPU readback")

func test_expiry_during_readback_never_returns_success() -> void:
	var texture := FakeTexture.new(64, 64, 0, 5)
	var deadline := Time.get_ticks_msec() + 1
	var result: Dictionary = CaptureOps.capture_texture(texture, {}, {}, deadline)
	assert_eq(result.get("code", ""), "timeout", "expiry during readback returns timeout")
	assert_eq(texture.readback_count, 1, "readback started before deadline only once")
