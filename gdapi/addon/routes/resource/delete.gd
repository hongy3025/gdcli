## resource/delete 路由

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const ResourceEditor := preload("res://addons/gdapi/runtime/services/resource_editor.gd")

const ROUTE := "resource/delete"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "")
	var force: bool = req.get_body("force", false)
	if path == "":
		res.error("path is required", "missing_param")
		return
	var result := ResourceEditor.delete(path, force)
	if not result.ok:
		res.error(result.error, result.code, 403 if result.code == "unsafe_operation" else 400)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("删除资源文件")
		.desc("M2 范围内总是要求 force:true;reimport 自动更新引用。产生 audit 记录。")
		.param("path", "String", true, "res:// 资源路径")
		.param("force", "bool", false, "必须为 true", "false")
		.example("{\"path\":\"res://resources/moved.tres\",\"force\":true}")
		.returns("delete", {
			"ok": "bool",
			"changed": "bool",
			"deleted": "bool",
			"undoable": "bool, false",
			"path": "String",
		})
	)
