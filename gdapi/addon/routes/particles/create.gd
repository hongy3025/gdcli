@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Service := preload("res://addons/gdapi/runtime/services/particle_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Service.create(req.body)
	if not result.ok:
		res.error(result.error, result.code, 400)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("particles/create")
		. desc(
			"GPU particles with ParticleProcessMaterial; "
			+ "2D Texture2D or active 3D draw-pass meshes. "
			+ "Atomic staging validation and one UndoRedo action."
		)
		. mutates()
		. param("parent_path", "String", true, "Absolute edited-scene parent path")
		. param("type", "String", true, "Supported construction node class")
		. param("name", "String", false, "Unique valid child name; defaults to type")
		. param(
			"properties",
			"Dictionary",
			false,
			"Allowlisted node properties; typed VariantCodec values or nested {class,properties} resources"
		)
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
