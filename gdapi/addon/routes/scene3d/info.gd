@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Service := preload("res://addons/gdapi/runtime/services/scene_3d_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Service.info(req.body)
	if not result.ok:
		res.error(result.error, result.code, 400)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("scene3d/info")
		. desc("Reads actual edited-scene 3D node parameters and embedded construction resources.")
		. param("node_path", "String", true, "Absolute edited-scene node path")
		. example('{"node_path":"/root/Node3D/Camera3D"}')
		. returns(
			"Configured state",
			{
				"ok": "bool",
				"node_path": "String",
				"type": "String",
				"properties": "Dictionary, resource state encoded recursively"
			}
		)
	)
