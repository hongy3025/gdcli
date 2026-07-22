## runtime/input/key — 注入一个 InputEventKey

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var ops := load("res://addons/gdapi/runtime/runtime_input_ops.gd")
	var result: Dictionary = ops.key(req.body)
	if not bool(result.get("ok", false)):
		res.error(String(result.get("error", "key failed")), String(result.get("code", "godot_error")), 500)
		return
	res.json(result.get("result", {}))

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("注入 InputEventKey")
		.desc("keycode 是 Godot 4.7 keycode 整数(SPACE=32)。pressed=true 按下,false 弹起。")
		.param("keycode", "int", true, "Key code 整数", "")
		.param("pressed", "bool", false, "是否按下,默认 true", "true")
		.example("{\"keycode\":32,\"pressed\":true}")
		.returns("事件结果", {
			"changed": "bool",
			"undoable": "bool, 固定为 false",
			"event_type": "String, key",
			"keycode": "int",
			"pressed": "bool",
		})
	)
