@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Editor := preload("res://addons/gdapi/runtime/services/resource_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Editor.get_property(req.get_body("path", null), req.get_body("property", null))
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("读取资源属性")
		. desc("按资源路径读取真实属性、类型、usage 与可写状态；值使用 VariantCodec。")
		. param("path", "String", true, "res:// 或 user:// 资源路径")
		. param("property", "String", true, "资源真实属性名")
		. returns(
			"result", {"value": "Variant", "type": "String", "usage": "int", "writable": "bool"}
		)
	)
