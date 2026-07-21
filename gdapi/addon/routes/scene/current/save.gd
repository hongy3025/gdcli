## scene/current/save 路由: 保存当前编辑场景

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const SceneEditor := preload("res://addons/gdapi/runtime/services/scene_editor.gd")

const ROUTE := "scene/current/save"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "")
	var force: bool = req.get_body("force", false)
	var result := SceneEditor.save_scene(path, force)
	if not result.ok:
		res.error(result.error, result.code, 403 if result.code == "unsafe_operation" else 400)
		return
	res.json({
		"ok": true,
		"changed": true,
		"saved": true,
		"undoable": false,
		"path": result.path,
	})


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("保存当前编辑场景")
		.desc("调用 EditorInterface.save_scene() 或 save_scene_as(target)。当 path 与当前路径不同且目标已存在时,必须 force:true。")
		.param("path", "String", false, "另存为的 res:// 路径,默认保存到当前路径")
		.param("force", "bool", false, "覆盖已有文件时为 true", "false")
		.example("{\"path\":\"res://scenes/main.tscn\",\"force\":true}")
		.returns("保存结果", {
			"ok": "bool",
			"changed": "bool, 是否产生文件变更",
			"saved": "bool, 是否已写入磁盘",
			"undoable": "bool, 始终为 false",
			"path": "String, 实际保存的 res:// 路径",
		})
	)
