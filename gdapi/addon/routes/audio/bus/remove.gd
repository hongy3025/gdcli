@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/audio_editor.gd")
func handle(req: GdApiRequest, res: GdApiResponse) -> void: _send(res, Editor.remove_bus(req.get_body("name", null), req.get_body("force", false)))
func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok: res.json(result)
	else: res.error(result.error, result.code, 403 if result.code == "unsafe_operation" or result.code == "permission_denied" else 400)
func doc() -> GdApiRouteDoc: return GdApiRouteDoc.make("删除音频总线").param("name", "String", true, "总线名", "").param("force", "bool", false, "删除需要 true", "false").example("{\"name\":\"SFX\",\"force\":true}").returns("bus", {"changed":"bool", "undoable":"false"})
