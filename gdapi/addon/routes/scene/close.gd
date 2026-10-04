## scene/close 路由: 关闭当前场景(不支持按路径关闭非当前场景)

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
	(
		res
		. json(
			{
				"ok": true,
				"changed": true,
				"undoable": false,
				"path": result.path,
			}
		)
	)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("关闭当前场景")
		. mutates()
		. desc(
			(
				"调用 EditorInterface.close_scene(),仅支持关闭当前编辑场景。"
				+ "Godot 4.7 未提供按路径关闭已打开场景的 API,因此 path 只能省略或等于当前场景;"
				+ "传入其他已打开场景的路径会返回 not_found。"
			)
		)
		. param("path", "String", false, "要关闭的场景 res:// 路径,只能省略或等于当前场景")
		. example('{"path":"res://scenes/main.tscn"}')
		. returns(
			"关闭结果",
			{
				"ok": "bool",
				"changed": "bool",
				"undoable": "bool, 始终为 false",
				"path": "String, 被关闭的场景路径",
			}
		)
	)
