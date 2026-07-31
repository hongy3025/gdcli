@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Editor := preload("res://addons/gdapi/runtime/services/navigation_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Editor.bake(req.get_body("region_path", null), req.get_body("path", null))
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("烘焙并保存 2D 导航网格")
		. desc("复制选定 NavigationRegion2D 的导航多边形到项目内 .tres；文件写入不可撤销。")
		. param("region_path", "String", true, "NavigationRegion2D 的绝对节点路径", "")
		. param("path", "String", true, "项目内 .tres 输出路径", "")
		. example(
			'{"region_path":"/root/NavigationDomain/Region","path":"res://navigation/baked.tres"}'
		)
		. returns("烘焙结果", {"path": "String", "saved": "bool", "undoable": "bool, false"})
	)
