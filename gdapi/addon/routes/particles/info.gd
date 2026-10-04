@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Service := preload("res://addons/gdapi/runtime/services/particle_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Service.info(req.body)
	if not result.ok:
		res.error(result.error, result.code, 400)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("particles/info")
		. desc(
			(
				"Reads edited-scene GPU particle parameters, "
				+ "ParticleProcessMaterial and actual texture/draw-pass resources."
			)
		)
		. param("node_path", "String", true, "Absolute edited-scene node path")
		. example('{"node_path":"/root/Main/Particles"}')
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
