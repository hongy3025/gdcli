@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Editor := preload("res://addons/gdapi/runtime/services/navigation_editor.gd")


func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Editor.list_regions()
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 404)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("列出 2D 导航区域")
		. desc("按绝对节点路径稳定排序返回当前场景中的 NavigationRegion2D 及其实际 map RID。")
		. returns("导航区域列表", {"regions": "Array<Dictionary>", "undoable": "bool, false"})
	)
