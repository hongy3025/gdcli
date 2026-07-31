## scene/current/save 路由: 保存当前编辑场景

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const SceneEditor := preload("res://addons/gdapi/runtime/services/scene_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "scene/current/save"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "")
	var result := SceneEditor.save_scene(path)
	if not result.ok:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))
		return
	(
		res
		. json(
			{
				"ok": true,
				"changed": true,
				"saved": true,
				"undoable": false,
				"path": result.path,
			}
		)
	)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("保存当前编辑场景")
		. desc("调用 EditorInterface.save_scene() 或 save_scene_as(target)。目标存在时直接覆盖。")
		. param("path", "String", false, "另存为的 res:// 路径,默认保存到当前路径")
		. example('{"path":"res://scenes/main.tscn"}')
		. returns(
			"保存结果",
			{
				"ok": "bool",
				"changed": "bool, 是否产生文件变更",
				"saved": "bool, 是否已写入磁盘",
				"undoable": "bool, 始终为 false",
				"path": "String, 实际保存的 res:// 路径",
			}
		)
	)
