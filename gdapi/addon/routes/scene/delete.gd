@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const SceneEditor := preload("res://addons/gdapi/runtime/services/scene_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const ROUTE := "scene/delete"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	res.audit_summary(
		"dangerous", {"path": req.get_body("path", ""), "dry_run": req.get_body("dry_run", false)}
	)
	var result := SceneEditor.delete_scene(
		str(req.get_body("path", "")),
		bool(req.get_body("dry_run", false)),
		bool(req.get_body("close_open", false))
	)
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Delete an unreferenced scene safely; no force or policy gate")
		. mutates()
		. param("path", "String", true, "Scene file path")
		. param("dry_run", "bool", false, "Report dependencies and conflicts without deleting")
		. param(
			"close_open",
			"bool",
			false,
			"Close current clean scene before deletion; other open tabs are conflicts"
		)
		. example('{"path":"res://scenes/runtime_qa_scene.tscn","dry_run":true}')
		. returns(
			"Operation result",
			{"ok": "bool", "changed": "bool for mutations", "undoable": "bool for mutations"}
		)
	)
