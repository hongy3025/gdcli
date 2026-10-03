## runtime/input/action — 注入 Input.action_press / action_release

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/input/action", true)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("触发 InputMap action")
		. mutates()
		. desc("必须先在项目 InputMap 中存在;按下=true 走 action_press,false 走 action_release。")
		. param("action", "String", true, "InputMap action 名,如 ui_accept", "")
		. param("pressed", "bool", false, "true 按下,false 弹起", "true")
		. example('{"action":"ui_accept","pressed":true}')
		. returns(
			"事件结果",
			{
				"changed": "bool",
				"undoable": "bool",
				"event_type": "String",
				"action": "String",
				"pressed": "bool",
			}
		)
	)
