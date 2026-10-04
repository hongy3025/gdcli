@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/theme_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(
		res,
		Editor.set_item(
			req.get_body("path", null),
			"font_size",
			req.get_body("type", "Control"),
			req.get_body("item", null),
			req.get_body("value", null)
		)
	)


func _send(res: GdApiResponse, r: Dictionary) -> void:
	if r.ok:
		res.json(r)
	else:
		res.error(r.error, r.code, ErrorCodes.http_status(r.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("设置 Theme 字号")
		. mutates()
		. desc("修改项目内 .tres Theme 的 font_size item 并保存（不可撤销）。")
		. param("path", "String", true, "Theme 的 res:// 路径")
		. param("type", "String", false, "控件类型名", "Control")
		. param("item", "String", true, "item 名")
		. param("value", "int", true, "字号整数值")
		. example(
			'{"path":"res://resources/theme.tres","type":"Button","item":"font_size","value":16}'
		)
		. returns("theme", {"undoable": "false"})
	)
