## script/create 路由: 创建新脚本

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const TextEditService := preload("res://addons/gdapi/runtime/services/text_edit.gd")

const ROUTE := "script/create"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "")
	var content: String = req.get_body("content", "")
	var force: bool = req.get_body("force", false)
	if path == "":
		res.error("path is required", "missing_param")
		return
	var result := TextEditService.create_script(path, content, force)
	if not result.ok:
		res.error(result.error, result.code, 403 if result.code == "unsafe_operation" else 400)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("创建 .gd 脚本文件")
		.desc("通过临时文件 + rename 原子写入。已存在需要 force:true。不修改不接 UndoRedo,产生 audit 记录。")
		.param("path", "String", true, "目标 res:// 路径")
		.param("content", "String", true, "完整脚本内容")
		.param("force", "bool", false, "目标已存在时需为 true", "false")
		.example("{\"path\":\"res://scripts/generated.gd\",\"content\":\"extends Node2D\\nvar speed := 10\\n\",\"force\":true}")
		.returns("创建结果", {
			"ok": "bool",
			"changed": "bool",
			"written": "bool",
			"saved": "bool",
			"undoable": "bool, false",
			"path": "String",
			"bytes": "int",
		})
	)
