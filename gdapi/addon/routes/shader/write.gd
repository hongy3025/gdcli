@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/shader_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(
		res,
		Editor.write(
			req.get_body("path", null), req.get_body("source", null), req.get_body("force", false)
		)
	)


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(
			result.error,
			result.code,
			403 if result.code == "unsafe_operation" or result.code == "permission_denied" else 400
		)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("创建或覆盖项目 Shader")
		. param("path", "String", true, "res:// .gdshader 目标", "")
		. param("source", "String", true, "完整 shader 源码", "")
		. param("force", "bool", false, "覆盖已有文件需要 true", false)
		. example(
			'{"path":"res://shaders/basic.gdshader","source":"shader_type canvas_item;","force":true}'
		)
		. returns("写入结果", {"path": "String", "written": "bool", "undoable": "bool, false"})
	)
