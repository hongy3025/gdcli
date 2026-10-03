## runtime/input/gamepad — 注入 joypad button 或 axis motion

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/input/gamepad", true)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("注入 joypad button / axis")
		. mutates()
		. desc("device 默认 0;kind=button 时 pressed=true 表示按下;kind=axis 时填 axis 索引和 value(-1..1)。")
		. param("device", "int", false, "手柄 device id,默认 0", "0")
		. param("kind", "String", false, "button|axis,默认 button", "button")
		. param("button", "int", false, "kind=button 时必填", "")
		. param("pressed", "bool", false, "kind=button 是否按下", "true")
		. param("axis", "int", false, "kind=axis 时必填 0..3", "")
		. param("value", "float", false, "kind=axis 的轴值 -1..1", "0.0")
		. example('{"device":0,"button":0,"pressed":true}')
		. returns(
			"事件结果",
			{
				"changed": "bool",
				"undoable": "bool",
				"event_type": "String",
				"button": "int, 仅 button",
				"axis": "int, 仅 axis",
				"value": "float, 仅 axis",
			}
		)
	)
