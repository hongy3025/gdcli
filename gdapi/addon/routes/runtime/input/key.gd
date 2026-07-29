## runtime/input/key — 注入一个 InputEventKey

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/input/key", true)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("注入 InputEventKey")
		. desc("keycode 是 Godot 4.7 keycode 整数(SPACE=32)。pressed=true 按下,false 弹起。")
		. param("keycode", "int", true, "Key code 整数", "")
		. param("pressed", "bool", false, "是否按下,默认 true", "true")
		. example('{"keycode":32,"pressed":true}')
		. returns(
			"事件结果",
			{
				"changed": "bool",
				"undoable": "bool, 固定为 false",
				"event_type": "String, key",
				"keycode": "int",
				"pressed": "bool",
			}
		)
	)
