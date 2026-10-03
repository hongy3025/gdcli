@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Service := preload("res://addons/gdapi/runtime/services/scene_3d_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Service.create(req.body)
	if not result.ok:
		res.error(result.error, result.code, 400)
		return
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("scene3d/create")
		. desc(
			"Atomic staging validation, one UndoRedo action, resources embedded in saved scenes; "
			+ "excludes physics/navigation."
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
		. param(
			"mesh_library",
			"Dictionary",
			false,
			"GridMap: {items:[{id,name,mesh,transform}]} replaces library"
		)
		. param(
			"cells",
			"Array",
			false,
			"GridMap: replaces cells with {position:Vector3i,item,orientation:0..23}"
		)
		. param(
			"multimesh",
			"Dictionary",
			false,
			"MultiMeshInstance3D: {mesh,instances:[{transform:Transform3D,color:Color,"
			+ "custom_data:Color}],visible_instance_count}"
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
