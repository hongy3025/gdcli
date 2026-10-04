@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/particles/info")


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Observe running GPU particles")
		. desc(
			(
				"Reads actual game-process GPUParticles2D/3D state, material and draw resources; "
				+ "requires an attached running game."
			)
		)
		. param("node_path", "String", true, "Absolute running scene path")
		. example('{"node_path":"/root/RuntimeMain/Particles3D"}')
		. returns(
			"Runtime particle state",
			{
				"node_path": "String",
				"type": "String",
				"emitting": "bool",
				"amount": "int",
				"lifetime": "float",
				"process_material": "Dictionary",
				"properties": "Dictionary",
				"inside_tree": "bool",
				"visible": "bool",
				"process_frame": "int"
			}
		)
	)
