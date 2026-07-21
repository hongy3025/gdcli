## scene/tree 路由: 返回当前或指定场景的节点树

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const SceneEditor := preload("res://addons/gdapi/runtime/services/scene_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "scene/tree"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "")
	var max_depth: int = int(req.get_body("max_depth", 32))
	if max_depth < 1 or max_depth > 128:
		res.error("max_depth must be between 1 and 128", ErrorCodes.INVALID_PARAM)
		return
	var root: Node = null
	if path == "":
		root = SceneEditor.current_root()
		if root == null:
			res.error("no scene is currently open", ErrorCodes.NOT_FOUND, 404)
			return
	else:
		var resolve := SceneEditor.resolve(path)
		if not resolve.ok:
			res.error(resolve.error, resolve.code, 404)
			return
		var packed: PackedScene = load(resolve.path) as PackedScene
		if packed == null:
			res.error("failed to load scene: " + resolve.path, ErrorCodes.GODOT_ERROR, 500)
			return
		root = packed.instantiate()
	res.json({
		"ok": true,
		"path": SceneEditor.current_path() if path == "" else path,
		"root": SceneEditor.describe_tree(root, max_depth),
		"undoable": false,
	})
	if path != "" and root != null:
		root.queue_free()


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("返回场景节点树")
		.desc("递归描述当前编辑场景或指定 res:// 场景的节点树。path 省略时查询当前场景,否则瞬时实例化指定场景获取树。")
		.param("path", "String", false, "场景 res:// 路径,默认当前场景")
		.param("max_depth", "int", false, "递归最大深度,1-128", "32")
		.example("{\"max_depth\":4}")
		.returns("树结构", {
			"ok": "bool",
			"path": "String, 实际查询的 res:// 路径",
			"root": "Dictionary 递归节点描述 {name,path,type,scene_file_path,children}",
			"undoable": "bool, 始终为 false",
		})
	)
