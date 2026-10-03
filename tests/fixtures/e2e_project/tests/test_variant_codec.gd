@tool
extends SceneTree

const Codec := preload("res://addons/gdapi/runtime/variant_codec.gd")

var passed := 0
var failed := 0


func _init() -> void:
	assert_eq(Codec.decode({"type": "Vector2", "value": [1, 2]}).value, Vector2(1, 2), "Vector2")
	assert_eq(
		Codec.decode({"type": "Vector3", "value": [1, 2, 3]}).value, Vector3(1, 2, 3), "Vector3"
	)
	assert_eq(
		Codec.decode({"type": "Color", "value": [0.1, 0.2, 0.3, 0.4]}).value,
		Color(0.1, 0.2, 0.3, 0.4),
		"Color"
	)
	assert_eq(
		Codec.decode({"type": "NodePath", "value": "root/Child"}).value,
		NodePath("root/Child"),
		"NodePath"
	)
	var transform: Transform2D = (
		Codec.decode({"type": "Transform2D", "value": [[1, 0], [0, 1], [5, 6]]}).value
	)
	assert_eq(transform, Transform2D(Vector2(1, 0), Vector2(0, 1), Vector2(5, 6)), "Transform2D")
	assert_false(Codec.decode({"type": "Vector2", "value": [1]}).ok, "short vector")
	assert_false(
		Codec.decode({"type": "PackedStringArray", "value": ["a"]}).ok, "packed array unsupported"
	)
	assert_false(Codec.decode({"type": "UnknownType", "value": 1}).ok, "unknown type")
	assert_eq(Codec.decode({"plain": 1}).value, {"plain": 1}, "plain dictionary unchanged")
	assert_eq(
		Codec.from_variant(Vector2(8, 9)),
		{"type": "Vector2", "value": [8.0, 9.0]},
		"Vector2 encode"
	)
	test_compound_values_round_trip()
	test_transform3d_compact_wire_value_is_native()
	test_invalid_nested_component_returns_error()
	test_invalid_numeric_values_are_rejected()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)


func test_compound_values_round_trip() -> void:
	var values := [
		Rect2(Vector2(-3, 4), Vector2(5, 6)),
		Rect2i(Vector2i(-7, 8), Vector2i(9, 10)),
		Basis(Vector3(2, 0, 0), Vector3(0, 3, 0), Vector3(0, 0, 4)),
		Transform3D(Basis.from_euler(Vector3(0.2, 0.4, 0.6)), Vector3(5, -6, 7)),
		AABB(Vector3(-1, -2, -3), Vector3(4, 5, 6)),
	]
	for value in values:
		var decoded := Codec.decode(Codec.from_variant(value))
		assert_true(decoded.ok, "compound decode succeeds")
		if decoded.ok:
			assert_eq(decoded.value, value, "compound preserves its native value")


func test_transform3d_compact_wire_value_is_native() -> void:
	var decoded := Codec.decode(
		{"type": "Transform3D", "value": [[[2, 0, 0], [0, 3, 0], [0, 0, 4]], [5, 6, 7]]}
	)
	assert_true(decoded.ok, "compact Transform3D decoded")
	if decoded.ok:
		var transformed: Vector3 = decoded.value * Vector3(1, 1, 1)
		assert_eq(transformed, Vector3(7, 9, 11), "decoded transform applies scale and translation")


func test_invalid_nested_component_returns_error() -> void:
	assert_false(
		(
			Codec
			. decode(
				{
					"type": "Basis",
					"value": [{"type": "Vector2", "value": [1, 0]}, [0, 1, 0], [0, 0, 1]]
				}
			)
			. ok
		),
		"Basis rejects a Vector2 component before native construction"
	)
	assert_false(
		Codec.decode({"type": "AABB", "value": [[1, 2, 3], ["bad", 4, 5]]}).ok,
		"AABB rejects nonnumeric nested vectors"
	)
	assert_false(
		Codec.decode({"type": "Transform3D", "value": [[], [1, 2, 3]]}).ok,
		"Transform3D propagates malformed basis"
	)


func assert_true(value: bool, context: String) -> void:
	assert_eq(value, true, context)


func assert_false(value: bool, context: String) -> void:
	assert_eq(value, false, context)


func assert_eq(actual, expected, context: String) -> void:
	if actual == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s expected=%s actual=%s" % [context, expected, actual])


func test_invalid_numeric_values_are_rejected() -> void:
	assert_false(
		Codec.decode({"type": "Vector3", "value": [1, "bad", 3]}).ok,
		"numeric strings are not silently converted"
	)
	assert_false(
		Codec.decode({"type": "Color", "value": [1, 0, 0, NAN]}).ok, "nonfinite alpha is rejected"
	)
	assert_false(
		Codec.decode({"type": "Vector2i", "value": [1.5, 2]}).ok,
		"fractional integer vector components are rejected"
	)
	assert_false(
		Codec.decode({"type": "Vector2i", "value": [2147483648, 2]}).ok,
		"integer vector overflow is rejected"
	)
	assert_false(Codec.decode({"type": 17, "value": [1, 2]}).ok, "type marker must be a String")
