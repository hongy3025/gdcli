## resource/create 路由

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const ResourceEditor := preload("res://addons/gdapi/runtime/services/resource_editor.gd")

const ROUTE := "resource/create"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "")
	var type: String = req.get_body("type", "")
	var properties: Dictionary = req.get_body("properties", {})
	var force: bool = req.get_body("force", false)
	if path == "" or type == "":
		res.error("path and type are required", "missing_param")
		return
	var result := ResourceEditor.create(path, type, properties, force)
	if not result.ok:
		res.error(result.error, result.code, 403 if result.code == "unsafe_operation" else 400)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("创建并保存 Resource 子类")
		.desc("type 必须是 Resource 子类。properties 通过 VariantCodec 解码,逐个属性 set 后保存。已存在需 force:true。")
		.param("path", "String", true, "目标 res:// 路径")
		.param("type", "String", true, "ClassDB 中可实例化的 Resource 子类")
		.param("properties", "Dictionary<String, Variant>", false, "要设置的属性表")
		.param("force", "bool", false, "覆盖已有文件需为 true", "false")
		.example("{\"path\":\"res://resources/generated.tres\",\"type\":\"Resource\",\"properties\":{\"resource_name\":\"Generated\"}}")
		.returns("create", {
			"ok": "bool",
			"changed": "bool",
			"saved": "bool",
			"undoable": "bool, false",
			"path": "String",
			"class": "String",
		})
	)
