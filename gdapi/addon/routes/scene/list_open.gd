## scene/list_open 路由: 列出编辑器当前打开的场景

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const SceneEditor := preload("res://addons/gdapi/runtime/services/scene_editor.gd")

const ROUTE := "scene/list_open"


func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	(
		res
		. json(
			{
				"ok": true,
				"paths": SceneEditor.list_open_scenes(),
				"undoable": false,
			}
		)
	)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("列出编辑器当前打开的场景路径")
		. desc("读取 EditorInterface.get_open_scenes(),返回编辑器当前打开的全部场景路径,按字典序稳定排序。")
		. returns(
			"当前场景列表",
			{
				"ok": "bool",
				"paths": "Array[String], 全部已打开场景的 res:// 路径,字典序升序",
				"undoable": "bool, 始终为 false",
			}
		)
	)
