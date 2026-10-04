@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Editor := preload("res://addons/gdapi/runtime/services/theme_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Editor.items(
		req.get_body("path", null), req.get_body("data_type", ""), req.get_body("type", "")
	)
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("列举 Theme 真实项目")
		. desc(
			"枚举本地 Theme 数据与编码值，可按 data_type/color/constant/font/font_size/icon/stylebox 和控件类型过滤；不包含虚构默认项。"
		)
		. param("path", "String", true, "项目内 .tres Theme 路径")
		. param("data_type", "String", false, "空值列举全部域", "")
		. param("type", "String", false, "空值列举全部已定义类型", "")
		. example('{"path":"res://resources/theme.tres"}')
		. returns("result", {"items": "Array<Dictionary>", "types": "Array<String>"})
	)
