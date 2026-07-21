## scene/close 路由: 关闭当前或指定场景

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const SceneEditor := preload("res://addons/gdapi/runtime/services/scene_editor.gd")

const ROUTE := "scene/close"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "")
	var result := SceneEditor.close_scene(path)
	if not result.ok:
		res.error(result.error, result.code, 400)
		return
	res.json({
		"ok": true,
		"changed": true,
		"undoable": false,
		"path": result.path,
	})


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("关闭当前或指定场景")
		.desc("调用 EditorInterface.close_scene();目前仅支持关闭当前打开的场景。参数 path 可省略,留空表示当前场景。")
		.param("path", "String", false, "要关闭的场景 res:// 路径,默认当前场景")
		.example("{\"path\":\"res://scenes/main.tscn\"}")
		.returns("关闭结果", {
			"ok": "bool",
			"changed": "bool",
			"undoable": "bool, 始终为 false",
			"path": "String, 关闭的场景路径",
		})
	)
