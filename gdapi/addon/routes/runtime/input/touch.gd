## runtime/input/touch — 注入 InputEventScreenTouch

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/input/touch", true)

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("注入 touch 事件")
		.desc("index 是触摸点 id;pressed=true 表示按下,false 弹起。")
		.param("index", "int", false, "触摸点 index,默认 0", "0")
		.param("pressed", "bool", false, "是否按下", "true")
		.param("position", "Array", false, "[x,y]", "[0,0]")
		.example("{\"index\":0,\"pressed\":true,\"position\":[12,14]}")
		.returns("事件结果", {
			"changed": "bool",
			"undoable": "bool",
			"event_type": "String",
			"index": "int",
			"pressed": "bool",
		})
	)
