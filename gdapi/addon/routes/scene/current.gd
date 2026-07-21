## scene/current 路由: 返回当前编辑场景信息

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const SceneEditor := preload("res://addons/gdapi/runtime/services/scene_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "scene/current"

func handle(_req: GdApiRequest, _res: GdApiResponse) -> void:
	var root := SceneEditor.current_root()
	if root == null:
		_res.error("no scene is currently open", ErrorCodes.NOT_FOUND, 404)
		return
	var path := SceneEditor.current_path()
	_res.json({
		"ok": true,
		"path": path,
		"name": root.name,
		"type": root.get_class(),
		"edited": root.scene_file_path == "" or _is_unsaved(),
		"undoable": false,
	})


func _is_unsaved() -> bool:
	if not Engine.is_editor_hint():
		return false
	# EditorPlugin 上的场景加载/未保存检测超出 route handler 范围,这里返回 false.
	return false

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("返回当前编辑场景信息")
		.desc("读取 EditorInterface 的当前编辑场景,返回 path、name 和 type。未打开任何场景时返回 not_found。")
		.returns("当前场景信息", {
			"ok": "bool",
			"path": "String, 当前场景的 res:// 路径",
			"name": "String, 根节点名",
			"type": "String, 根节点类名",
			"edited": "bool, 是否未保存的临时场景(目前恒为 false)",
			"undoable": "bool, 始终为 false",
		})
	)
