## resource/move 路由

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const ResourceEditor := preload("res://addons/gdapi/runtime/services/resource_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "resource/move"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var from_path: String = req.get_body("from", "")
	var to_path: String = req.get_body("to", "")
	if from_path == "" or to_path == "":
		res.error("from and to are required", "missing_param")
		return
	var result := ResourceEditor.move(from_path, to_path)
	if not result.ok:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("在编辑器文件系统中移动资源")
		. mutates()
		. desc("通过 EditorFileSystem.move_file 重命名/移动文件并触发 reimport。目标存在时由 EditorFileSystem 处理。")
		. param("from", "String", true, "源 res:// 路径")
		. param("to", "String", true, "目标 res:// 路径")
		. example('{"from":"res://resources/generated.tres","to":"res://resources/moved.tres"}')
		. returns(
			"move",
			{
				"ok": "bool",
				"changed": "bool",
				"moved": "bool",
				"undoable": "bool, false",
				"from": "String",
				"to": "String",
			}
		)
	)
