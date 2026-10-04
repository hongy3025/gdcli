@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Editor := preload("res://addons/gdapi/runtime/services/theme_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Editor.set_item(
		req.get_body("path", null),
		"font",
		req.get_body("type", "Control"),
		req.get_body("item", null),
		req.get_body("value", null)
	)
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("设置 Theme 字体")
		. desc("设置 VariantCodec Resource 表达的 Font；保存并磁盘重载核对，失败恢复文件。")
		. mutates()
		. param("path", "String", true, "项目内 .tres Theme 路径")
		. param("type", "String", false, "控件类型或 Theme 类型变体", "Control")
		. param("item", "String", true, "item 名")
		. param("value", "Variant", true, "Font Resource 编码值")
		. example(
			'{"path":"res://resources/theme.tres","item":"font","value":{"class":"SystemFont"}}'
		)
		. returns("result", {"undoable": "false"})
	)
