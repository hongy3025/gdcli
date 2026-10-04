@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Editor := preload("res://addons/gdapi/runtime/services/theme_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Editor.get_item(
		req.get_body("path", null),
		"icon",
		req.get_body("type", "Control"),
		req.get_body("item", null)
	)
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("读取 Theme icon")
		. desc("读回本地或基类型/类型变体继承的真实值。缺失返回 has:false/value:null，不把默认 fallback 误报为已设置。")
		. param("path", "String", true, "项目内 .tres Theme 路径")
		. param("type", "String", false, "控件类型或 Theme 类型变体", "Control")
		. param("item", "String", true, "item 名")
		. example('{"path":"res://resources/theme.tres","item":"icon"}')
		. returns(
			"result",
			{
				"value": "Variant",
				"has": "bool",
				"local_has": "bool",
				"inherited": "bool",
				"resolved_type": "String"
			}
		)
	)
