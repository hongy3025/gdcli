@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const SceneEditor := preload("res://addons/gdapi/runtime/services/scene_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "scene/instantiate"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := SceneEditor.instantiate_scene(
		str(req.get_body("path", "")),
		str(req.get_body("parent_path", "")),
		str(req.get_body("name", ""))
	)
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Instantiate a linked PackedScene with UndoRedo")
		. mutates()
		. param("path", "String", true, "PackedScene path")
		. param("parent_path", "String", true, "Edited-scene parent path")
		. example('{"path":"res://scenes/runtime_qa_scene.tscn","parent_path":"/root/Main"}')
		. param("name", "String", false, "Unique instance-root name")
		. returns(
			"Operation result",
			{"ok": "bool", "changed": "bool for mutations", "undoable": "bool for mutations"}
		)
	)
