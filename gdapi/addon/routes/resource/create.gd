## resource/create 路由

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const ResourceEditor := preload("res://addons/gdapi/runtime/services/resource_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "resource/create"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "")
	var type: String = req.get_body("type", "")
	var properties: Dictionary = req.get_body("properties", {})
	if path == "" or type == "":
		res.error("path and type are required", "missing_param")
		return
	var result := ResourceEditor.create(path, type, properties)
	if not result.ok:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("创建并保存 Resource 子类")
		. mutates()
		. desc("type 必须是 Resource 子类。properties 通过 VariantCodec 解码,逐个属性 set 后保存。目标存在直接覆盖。")
		. param("path", "String", true, "目标 res:// 路径")
		. param("type", "String", true, "ClassDB 中可实例化的 Resource 子类")
		. param("properties", "Dictionary<String, Variant>", false, "要设置的属性表")
		. example(
			(
				'{"path":"res://resources/generated.tres","type":"Resource",'
				+ '"properties":{"resource_name":"Generated"}}'
			)
		)
		. returns(
			"create",
			{
				"ok": "bool",
				"changed": "bool",
				"saved": "bool",
				"undoable": "bool, false",
				"path": "String",
				"class": "String",
			}
		)
	)
