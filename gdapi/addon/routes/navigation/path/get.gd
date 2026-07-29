@tool
extends "res://addons/gdapi/runtime/game_route.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch_game(req, res, "m4/navigation/path/get")

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("查询 2D 导航路径")
		.desc("在运行期选定 NavigationRegion2D 的实际 map 上查询路径。")
		.param("region_path", "String", true, "NavigationRegion2D 的绝对节点路径", "")
		.param("from", "Vector2", true, "起点", "")
		.param("to", "Vector2", true, "终点", "")
		.example("{\"region_path\":\"/root/NavigationDomain/Region\",\"from\":{\"x\":0,\"y\":0},\"to\":{\"x\":100,\"y\":0}}")
		.returns("导航路径", {"points": "按顺序排列的 Vector2 数组", "region_path": "String"})
	)
