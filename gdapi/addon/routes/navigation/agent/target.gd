@tool
extends "res://addons/gdapi/runtime/game_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch_game(req, res, "m4/navigation/agent/target", true)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("设置运行期 2D 导航 agent 目标")
		. desc("只接受 NavigationAgent2D 与 Vector2 目标；运行期 mutation 不可撤销。")
		. param("agent_path", "String", true, "NavigationAgent2D 的绝对节点路径", "")
		. param("target", "Vector2", true, "目标位置", "")
		. example('{"agent_path":"/root/NavigationDomain/Agent","target":{"x":100,"y":0}}')
		. returns(
			"目标设置结果",
			{"changed": "bool", "undoable": "false", "agent_path": "String", "target": "Vector2"}
		)
	)
