## scene/list_open 路由: 列出编辑器当前打开的场景

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const SceneEditor := preload("res://addons/gdapi/runtime/services/scene_editor.gd")

const ROUTE := "scene/list_open"

func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	res.json({
		"ok": true,
		"paths": SceneEditor.list_open_scenes(),
		"undoable": false,
	})


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("列出编辑器当前打开的场景路径")
		.desc("目前 Godot 编辑器仅持有单一当前编辑场景,该 route 返回一个长度为 0 或 1 的路径数组。")
		.returns("当前场景列表", {
			"ok": "bool",
			"paths": "Array[String], 当前场景 res:// 路径",
			"undoable": "bool, 始终为 false",
		})
	)
