@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Service := preload("res://addons/gdapi/runtime/services/particle_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Service.set_config(req.body)
	if not result.ok:
		res.error(result.error, result.code, 400)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("particles/set")
		. desc(
			(
				"GPU particles with ParticleProcessMaterial; "
				+ "2D Texture2D or active 3D draw-pass meshes. "
				+ "Atomic staging validation and one UndoRedo action."
			)
		)
		. mutates()
		. param("node_path", "String", true, "Absolute edited-scene node path")
		. param(
			"properties",
			"Dictionary",
			false,
			"Allowlisted node properties; typed VariantCodec values or nested {class,properties} resources"
		)
		. example('{"node_path":"/root/Main/Particles","properties":{"amount":64}}')
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
