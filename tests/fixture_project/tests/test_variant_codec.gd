@tool
extends SceneTree

const Codec := preload("res://addons/gdapi/runtime/variant_codec.gd")

var passed := 0
var failed := 0

func _init() -> void:
	assert_eq(Codec.decode({"type":"Vector2","value":[1,2]}).value, Vector2(1,2), "Vector2")
	assert_eq(Codec.decode({"type":"Vector3","value":[1,2,3]}).value, Vector3(1,2,3), "Vector3")
	assert_eq(Codec.decode({"type":"Color","value":[0.1,0.2,0.3,0.4]}).value, Color(0.1,0.2,0.3,0.4), "Color")
	assert_eq(Codec.decode({"type":"NodePath","value":"root/Child"}).value, NodePath("root/Child"), "NodePath")
	var transform: Transform2D = Codec.decode({"type":"Transform2D","value":[[1,0],[0,1],[5,6]]}).value
	assert_eq(transform, Transform2D(Vector2(1,0), Vector2(0,1), Vector2(5,6)), "Transform2D")
	assert_false(Codec.decode({"type":"Vector2","value":[1]}).ok, "short vector")
	assert_false(Codec.decode({"type":"PackedStringArray","value":["a"]}).ok, "packed array unsupported")
	assert_false(Codec.decode({"type":"UnknownType","value":1}).ok, "unknown type")
	assert_eq(Codec.decode({"plain": 1}).value, {"plain": 1}, "plain dictionary unchanged")
	assert_eq(Codec.from_variant(Vector2(8,9)), {"type":"Vector2","value":[8.0,9.0]}, "Vector2 encode")
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)

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
