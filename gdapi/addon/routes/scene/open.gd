## scene/open 路由: 在编辑器中打开 res:// 路径场景

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const SceneEditor := preload("res://addons/gdapi/runtime/services/scene_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "scene/open"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "")
	if path.is_empty():
		res.error("path is required", ErrorCodes.MISSING_PARAM)
		return
	var result := SceneEditor.open_scene(path)
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
		GdApiRouteDoc.make("在编辑器中打开 res:// 路径场景")
		.desc("将指定 res:// 场景加载到当前编辑器,替换当前打开的场景(若有)。目标不存在返回 not_found。")
		.param("path", "String", true, "目标场景的 res:// 路径")
		.example("{\"path\":\"res://scenes/main.tscn\"}")
		.returns("打开结果", {
			"ok": "bool",
			"changed": "bool, 编辑器上下文是否改变",
			"undoable": "bool, 始终为 false",
			"path": "String, 实际打开的 res:// 路径",
		})
	)
