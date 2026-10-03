@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Editor := preload("res://addons/gdapi/runtime/services/resource_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Editor.set_property(
		req.get_body("path", null), req.get_body("property", null), req.get_body("value", null)
	)
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("保存资源属性")
		. desc("仅修改可存储、非只读 .tres/.res 属性；保护 script/source；保存后重载核对，失败回滚内存和文件。")
		. mutates()
		. param("path", "String", true, "res:// 或 user:// 资源路径")
		. param("property", "String", true, "资源真实属性名")
		. param("value", "Variant", true, "VariantCodec typed 值")
		. returns(
			"result", {"value": "Variant", "changed": "bool", "saved": "bool", "undoable": "false"}
		)
	)
