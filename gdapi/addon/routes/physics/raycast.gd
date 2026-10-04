@tool
extends "res://addons/gdapi/runtime/game_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch_game(req, res, "m4/physics/raycast")


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("执行 2D 物理射线检测")
		. desc("仅在正在运行的 2D 场景中查询 World2D；内部 operation 固定为 m4/physics/raycast。")
		. param("from", "Vector2", true, "射线起点", "")
		. param("to", "Vector2", true, "射线终点", "")
		. param("collision_mask", "int", false, "碰撞层掩码，默认全部", "")
		. example('{"from":{"x":0,"y":100},"to":{"x":320,"y":100}}')
		. returns(
			"命中结果",
			{
				"hit": "bool",
				"position": "Vector2，命中时存在",
				"normal": "Vector2，命中时存在",
				"collider_path": "String，命中时存在"
			}
		)
	)
