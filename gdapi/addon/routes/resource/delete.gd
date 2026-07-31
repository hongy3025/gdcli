## resource/delete 路由

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const ResourceEditor := preload("res://addons/gdapi/runtime/services/resource_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "resource/delete"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "")
	if path == "":
		res.error("path is required", "missing_param")
		return
	_send(res, ResourceEditor.delete(path))


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("删除资源文件")
		. desc("reimport 自动更新引用。产生 audit 记录。")
		. param("path", "String", true, "res:// 资源路径")
		. example('{"path":"res://resources/moved.tres"}')
		. returns(
			"delete",
			{
				"ok": "bool",
				"changed": "bool",
				"deleted": "bool",
				"undoable": "bool, false",
				"path": "String",
			}
		)
	)
