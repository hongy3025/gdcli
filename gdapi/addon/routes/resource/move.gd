## resource/move 路由

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const ResourceEditor := preload("res://addons/gdapi/runtime/services/resource_editor.gd")

const ROUTE := "resource/move"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var from_path: String = req.get_body("from", "")
	var to_path: String = req.get_body("to", "")
	var force: bool = req.get_body("force", false)
	if from_path == "" or to_path == "":
		res.error("from and to are required", "missing_param")
		return
	var result := ResourceEditor.move(from_path, to_path, force)
	if not result.ok:
		res.error(result.error, result.code, 403 if result.code == "unsafe_operation" else 400)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("在编辑器文件系统中移动资源")
		.desc("通过 EditorFileSystem.move_file 重命名/移动文件并触发 reimport。覆盖需 force:true。")
		.param("from", "String", true, "源 res:// 路径")
		.param("to", "String", true, "目标 res:// 路径")
		.param("force", "bool", false, "覆盖已有文件需为 true", "false")
		.example("{\"from\":\"res://resources/generated.tres\",\"to\":\"res://resources/moved.tres\",\"force\":true}")
		.returns("move", {
			"ok": "bool",
			"changed": "bool",
			"moved": "bool",
			"undoable": "bool, false",
			"from": "String",
			"to": "String",
		})
	)
