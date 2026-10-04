## runtime/input/mouse — 注入 InputEventMouseButton 或 InputEventMouseMotion

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/input/mouse", true)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("注入 InputEventMouseButton / Motion")
		. mutates()
		. desc("kind=button 必填 button(1..8) 和 position;kind=motion 只填 position。")
		. param("kind", "String", false, "button|motion,默认 button", "button")
		. param("button", "int", false, "kind=button 时必填 1..8", "")
		. param("pressed", "bool", false, "kind=button 时是否按下", "true")
		. param("position", "Array", false, "viewport 坐标 [x,y]", "[0,0]")
		. example('{"kind":"button","button":1,"pressed":true,"position":[8,9]}')
		. returns(
			"事件结果",
			{
				"changed": "bool",
				"undoable": "bool",
				"event_type": "String",
				"button": "int, 仅 button 类型",
				"pressed": "bool, 仅 button 类型",
			}
		)
	)
