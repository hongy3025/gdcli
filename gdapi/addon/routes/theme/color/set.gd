@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/theme_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(
		res,
		Editor.set_item(
			req.get_body("path", null),
			"color",
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
		. make("设置 Theme 颜色")
		. desc("修改项目内 .tres Theme 的 color item 并保存（不可撤销）。")
		. param("path", "String", true, "Theme 的 res:// 路径")
		. param("type", "String", false, "控件类型名", "Control")
		. param("item", "String", true, "item 名")
		. param("value", "Variant", true, "Color 编码值")
		. example(
			(
				'{"path":"res://themes/main.tres","type":"Button",'
				+ '"item":"font_color","value":{"type":"Color","value":[1.0,0.0,0.0]}}'
			)
		)
		. returns("theme", {"undoable": "false"})
	)
