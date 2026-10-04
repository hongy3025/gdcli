@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Service := preload("res://addons/gdapi/runtime/services/scene_batch_service.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var out := Service.get_scene_dependencies(req.body)
	if out.ok:
		res.json(out)
	else:
		res.error(out.error, out.code, ErrorCodes.http_status(out.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("查找场景资源依赖")
		. desc("离线递归扫描 .tscn/.scn，不依赖当前编辑场景；排除生成及 PathGuard 保护根。返回实际场景路径和匹配上下文。")
		. param("root", "String", false, "递归扫描根", "res://")
		. param("scenes", "Array[String]", false, "显式场景列表，替代 root")
		. example('{"root":"res://"}')
		. returns("扫描结果", {"items": "Array[Dictionary]", "warnings": "Array[String]"})
	)
