## resource/search 路由

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const ResourceEditor := preload("res://addons/gdapi/runtime/services/resource_editor.gd")

const ROUTE := "resource/search"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var filter_text: String = req.get_body("filter", "")
	var offset: int = int(req.get_body("offset", 0))
	var limit: int = int(req.get_body("limit", 100))
	var result := ResourceEditor.search(filter_text, offset, limit)
	if not result.ok:
		res.error(result.error, result.code, 400)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("通过 EditorFileSystem 搜索资源")
		.desc("filter 按路径子串匹配(大小写不敏感),limit 1-1000。")
		.param("filter", "String", false, "路径子串", "")
		.param("offset", "int", false, "分页偏移", "0")
		.param("limit", "int", false, "1-1000", "100")
		.example("{\"filter\":\"player\",\"offset\":0,\"limit\":100}")
		.returns("分页", {
			"ok": "bool",
			"items": "Array<String>, res:// 路径",
			"total": "int",
			"offset": "int",
			"limit": "int",
			"undoable": "bool, false",
		})
	)
