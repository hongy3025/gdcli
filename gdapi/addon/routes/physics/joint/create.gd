@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/physics_editor.gd")
func handle(req: GdApiRequest, res: GdApiResponse) -> void: _send(res, Editor.create_joint(req.get_body("parent_path", null), req.get_body("type", null), req.get_body("name", "Joint")))
func _send(res: GdApiResponse, r: Dictionary) -> void:
	if r.ok: res.json(r)
	else: res.error(r.error, r.code, 501 if r.code == "not_supported" else 400)
func doc() -> GdApiRouteDoc: return GdApiRouteDoc.make("创建 2D 物理关节").returns("joint", {"undoable":"true"})
