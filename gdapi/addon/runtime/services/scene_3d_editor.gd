@tool
class_name GdApiScene3DEditor
extends RefCounted

const NodeEditor := preload("res://addons/gdapi/runtime/services/node_editor.gd")
const EditAction := preload("res://addons/gdapi/runtime/edit_action.gd")
const VariantCodec := preload("res://addons/gdapi/runtime/variant_codec.gd")
const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const TYPES := [
	"DirectionalLight3D",
	"OmniLight3D",
	"SpotLight3D",
	"WorldEnvironment",
	"Camera3D",
	"GridMap",
	"CSGBox3D",
	"CSGSphere3D",
	"CSGCylinder3D",
	"CSGTorus3D",
	"CSGPolygon3D",
	"CSGMesh3D",
	"CSGCombiner3D",
	"MultiMeshInstance3D"
]
const RESOURCE_TYPES := [
	"Environment",
	"Sky",
	"ProceduralSkyMaterial",
	"StandardMaterial3D",
	"BoxMesh",
	"SphereMesh",
	"CylinderMesh",
	"CapsuleMesh",
	"PlaneMesh",
	"QuadMesh",
	"PrismMesh",
	"TorusMesh",
	"PointMesh",
	"ParticleProcessMaterial",
	"GradientTexture1D",
	"GradientTexture2D",
	"Gradient",
	"NoiseTexture2D",
	"FastNoiseLite"
]
const COMMON := [
	"transform", "position", "rotation", "rotation_degrees", "scale", "visible", "top_level"
]
const PROTECTED := [
	"script",
	"resource_path",
	"resource_name",
	"resource_local_to_scene",
	"owner",
	"name",
	"process_mode",
	"use_collision",
	"collision_layer",
	"collision_mask",
	"collision_priority",
	"navigation_layers",
	"mesh_library",
	"multimesh"
]


static func error(message: String, code: String = ErrorCodes.INVALID_PARAM) -> Dictionary:
	return {"ok": false, "code": code, "error": message}


static func create(payload: Dictionary) -> Dictionary:
	var type_value: Variant = payload.get("type", "")
	if not type_value is String or type_value not in TYPES:
		return error("type must be a supported 3D construction type")
	return edit(payload, true, TYPES)


static func set_config(payload: Dictionary) -> Dictionary:
	return edit(payload, false, TYPES)


# Configure an unattached staging node first, then publish one undoable action.
static func edit(payload: Dictionary, creating: bool, allowed_types: Array) -> Dictionary:
	var path: Variant = payload.get("parent_path" if creating else "node_path", "")
	if not path is String:
		return error("node path must be a String")
	var found := NodeEditor.find(path)
	if not found.ok:
		return found
	var target: Node = found.node
	var type: String = str(payload.get("type", "")) if creating else target.get_class()
	if type not in allowed_types:
		return error("unsupported node type: " + type)
	var name_value: Variant = payload.get("name", type)
	if (
		creating
		and (
			not name_value is String
			or name_value.is_empty()
			or name_value.validate_node_name() != name_value
		)
	):
		return error("name must be a nonempty valid node name")
	if creating and target.has_node(NodePath(name_value)):
		return error("child name already exists", ErrorCodes.CONFLICT)
	var staged: Node = ClassDB.instantiate(type)
	if not creating:
		for info in target.get_property_list():
			if (
				int(info.usage) & PROPERTY_USAGE_STORAGE
				and allowed_property(target, str(info.name))
			):
				staged.set(info.name, target.get(info.name))
		if target is GridMap:
			staged.set("mesh_library", target.mesh_library)
			apply_cells(staged, snapshot_cells(target))
		if target is MultiMeshInstance3D:
			staged.set("multimesh", target.multimesh)
	var configured := configure(staged, payload, creating)
	if not configured.ok:
		staged.free()
		return configured
	return commit(
		target, staged, creating, str(name_value), configured.properties, payload.has("cells")
	)


static func configure(node: Node, payload: Dictionary, creating: bool) -> Dictionary:
	var raw: Variant = payload.get("properties", {})
	if not raw is Dictionary:
		return error("properties must be a Dictionary")
	var prepared := prepare_properties(node, raw)
	if not prepared.ok:
		return prepared
	var values: Dictionary = prepared.values
	if node is WorldEnvironment and creating and not values.has("environment"):
		var environment := Environment.new()
		environment.background_mode = Environment.BG_SKY
		var sky := Sky.new()
		sky.sky_material = ProceduralSkyMaterial.new()
		environment.sky = sky
		values.environment = environment
	if payload.has("mesh_library"):
		if not node is GridMap:
			return error("mesh_library is only valid for GridMap")
		var library := build_library(payload.mesh_library)
		if not library.ok:
			return library
		values.mesh_library = library.value
	elif creating and node is GridMap:
		values.mesh_library = MeshLibrary.new()
	if payload.has("multimesh"):
		if not node is MultiMeshInstance3D:
			return error("multimesh is only valid for MultiMeshInstance3D")
		var built := build_multimesh(payload.multimesh)
		if not built.ok:
			return built
		values.multimesh = built.value
	elif creating and node is MultiMeshInstance3D:
		var built := build_multimesh({"mesh": {"class": "BoxMesh"}, "instances": []})
		values.multimesh = built.value
	if node is GPUParticles2D or node is GPUParticles3D:
		if creating and not values.has("process_material"):
			var material := ParticleProcessMaterial.new()
			material.particle_flag_disable_z = node is GPUParticles2D
			values.process_material = material
		if creating and node is GPUParticles2D and not values.has("texture"):
			var texture := GradientTexture2D.new()
			texture.gradient = Gradient.new()
			values.texture = texture
		if creating and node is GPUParticles3D and not values.has("draw_pass_1"):
			values.draw_pass_1 = QuadMesh.new()
	var applied := apply_properties(node, values)
	if not applied.ok:
		return applied
	if node is GPUParticles2D or node is GPUParticles3D:
		if not node.process_material is ParticleProcessMaterial:
			return error("process_material must be a ParticleProcessMaterial")
		if node is GPUParticles2D and not node.texture is Texture2D:
			return error("GPUParticles2D requires a Texture2D")
		if node is GPUParticles3D:
			for pass_index in node.draw_passes:
				if not node.get("draw_pass_" + str(pass_index + 1)) is Mesh:
					return error("each active GPUParticles3D draw pass requires a Mesh")
	if payload.has("cells"):
		if not node is GridMap:
			return error("cells is only valid for GridMap")
		var cells := prepare_cells(payload.cells, node.mesh_library)
		if not cells.ok:
			return cells
		apply_cells(node, cells.value)
	elif node is GridMap and values.has("mesh_library"):
		for cell in snapshot_cells(node):
			if cell.item not in node.mesh_library.get_item_list():
				return error("new mesh_library does not contain an existing cell item")
	return {"ok": true, "properties": values}


static func allowed_property(target: Object, property: String) -> bool:
	if property in PROTECTED or property.begins_with("_") or property.contains("/"):
		return false
	if target is Resource:
		return true
	if property in COMMON:
		return true
	if target is Light3D:
		return (
			property.begins_with("light_")
			or property.begins_with("shadow_")
			or property.begins_with("directional_")
			or property.begins_with("omni_")
			or property.begins_with("spot_")
		)
	if target is WorldEnvironment:
		return property in ["environment", "camera_attributes", "compositor"]
	if target is Camera3D:
		return (
			property
			in [
				"projection",
				"fov",
				"size",
				"near",
				"far",
				"keep_aspect",
				"frustum_offset",
				"h_offset",
				"v_offset",
				"current",
				"cull_mask",
				"environment",
				"attributes"
			]
		)
	if target is GridMap:
		return (
			property
			in [
				"cell_size",
				"cell_octant_size",
				"cell_center_x",
				"cell_center_y",
				"cell_center_z",
				"cell_scale"
			]
		)
	if target is CSGShape3D:
		return (
			property
			in [
				"operation",
				"snap",
				"material",
				"mesh",
				"width",
				"height",
				"depth",
				"size",
				"radius",
				"inner_radius",
				"outer_radius",
				"radial_segments",
				"rings",
				"sides",
				"cone",
				"smooth_faces",
				"flip_faces",
				"polygon",
				"mode",
				"spin_degrees",
				"spin_sides",
				"path_node",
				"path_interval",
				"path_rotation",
				"path_local",
				"path_continuous_u",
				"path_u_distance",
				"path_joined"
			]
		)
	if target is GPUParticles2D or target is GPUParticles3D:
		return (
			property
			in [
				"amount",
				"amount_ratio",
				"lifetime",
				"emitting",
				"one_shot",
				"preprocess",
				"speed_scale",
				"explosiveness",
				"randomness",
				"fixed_fps",
				"interpolate",
				"fract_delta",
				"local_coords",
				"draw_order",
				"process_material",
				"texture",
				"draw_passes",
				"draw_pass_1",
				"draw_pass_2",
				"draw_pass_3",
				"draw_pass_4",
				"visibility_rect",
				"visibility_aabb",
				"trail_enabled",
				"trail_lifetime"
			]
		)
	return false


static func prepare_properties(target: Object, properties: Dictionary) -> Dictionary:
	var values := {}
	for key in properties:
		if not key is String or not allowed_property(target, key):
			return error(
				"property is outside the construction allowlist: " + str(key),
				ErrorCodes.PERMISSION_DENIED
			)
		var meta := {}
		for info in target.get_property_list():
			if str(info.name) == key and int(info.usage) & PROPERTY_USAGE_STORAGE:
				meta = info
		if meta.is_empty():
			return error("property does not exist: " + key, ErrorCodes.NOT_FOUND)
		var decoded := decode_value(properties[key])
		if not decoded.ok:
			return decoded
		var value: Variant = decoded.value
		var expected: int = int(meta.type)
		if expected == TYPE_FLOAT and typeof(value) in [TYPE_FLOAT, TYPE_INT]:
			value = float(value)
		elif (
			expected == TYPE_INT
			and typeof(value) in [TYPE_FLOAT, TYPE_INT]
			and float(value) == floor(float(value))
		):
			value = int(value)
		elif typeof(value) != expected:
			return error("wrong value type for " + key)
		if expected == TYPE_OBJECT:
			var compatible := value is Resource
			if compatible and not str(meta.hint_string).is_empty():
				compatible = false
				for resource_class in str(meta.hint_string).split(","):
					compatible = compatible or value.is_class(resource_class)
			if not compatible:
				return error("wrong resource class for " + key)
		if (
			expected == TYPE_INT
			and int(meta.hint) == PROPERTY_HINT_ENUM
			and not str(meta.hint_string).is_empty()
		):
			var enum_values := []
			var enum_index := 0
			for label in str(meta.hint_string).split(","):
				var parts := label.split(":")
				if parts.size() > 1:
					enum_index = int(parts[1])
				enum_values.append(enum_index)
				enum_index += 1
			if value not in enum_values:
				return error("invalid enum value for " + key)
		if expected in [TYPE_FLOAT, TYPE_INT] and int(meta.hint) == PROPERTY_HINT_RANGE:
			var bounds: PackedStringArray = str(meta.hint_string).split(",")
			if bounds.size() >= 2:
				if (
					(float(value) < float(bounds[0]) and "or_less" not in bounds)
					or (float(value) > float(bounds[1]) and "or_greater" not in bounds)
				):
					return error("value outside range for " + key)
		if (
			(
				key
				in [
					"amount",
					"lifetime",
					"near",
					"far",
					"radius",
					"width",
					"height",
					"depth",
					"cell_scale"
				]
			)
			and float(value) <= 0
		):
			return error(key + " must be positive")
		if key in ["preprocess", "speed_scale", "fixed_fps", "trail_lifetime"] and float(value) < 0:
			return error(key + " must be nonnegative")
		if key == "cell_size" and (value.x <= 0 or value.y <= 0 or value.z <= 0):
			return error("cell_size components must be positive")
		if key == "size" and (target is PrimitiveMesh or target is CSGBox3D):
			if (
				(value is Vector3 and (value.x <= 0 or value.y <= 0 or value.z <= 0))
				or (value is Vector2 and (value.x <= 0 or value.y <= 0))
			):
				return error("mesh size components must be positive")
		values[key] = value
	return {"ok": true, "values": values}


static func apply_properties(target: Object, values: Dictionary) -> Dictionary:
	for key in values:
		target.set(key, values[key])
	for key in values:
		var actual: Variant = target.get(key)
		if (
			actual != values[key]
			and not (
				typeof(actual) == TYPE_FLOAT
				and typeof(values[key]) == TYPE_FLOAT
				and is_equal_approx(actual, values[key])
			)
		):
			return error("Godot rejected or clamped property: " + key)
		values[key] = actual
	if target is Camera3D and target.near >= target.far:
		return error("camera near must be less than far")
	return {"ok": true}


static func decode_value(raw: Variant, depth: int = 0) -> Dictionary:
	if depth > 16 or not finite_json(raw):
		return error("invalid, nonfinite or excessively nested value")
	if raw is Dictionary and raw.has("class"):
		return build_resource(raw, depth + 1)
	if raw is Dictionary and raw.get("type", "") == "Resource":
		if not raw.get("value") is String:
			return error("Resource requires a path String")
		var guard := PathGuard.validate(raw.value, "read")
		if not guard.ok:
			return guard
		if not ResourceLoader.exists(guard.path):
			return error("resource not found: " + guard.path, ErrorCodes.NOT_FOUND)
		var loaded: Resource = load(guard.path)
		if (
			loaded == null
			or loaded is Script
			or loaded is PackedScene
			or loaded.get_script() != null
		):
			return error("resource is not a construction asset")
		return {"ok": true, "value": loaded}
	var normalized: Variant = raw
	if raw is Dictionary and raw.has("type"):
		if raw.type in ["PackedColorArray", "PackedFloat32Array"]:
			if not raw.get("value") is Array:
				return error("packed data requires an Array")
			var entries := []
			for entry in raw.value:
				if raw.type == "PackedColorArray":
					var color := decode_value({"type": "Color", "value": entry})
					if not color.ok:
						return color
					entries.append(color.value)
				elif typeof(entry) in [TYPE_FLOAT, TYPE_INT]:
					entries.append(float(entry))
				else:
					return error("packed float components must be numbers")
			return {
				"ok": true,
				"value":
				(
					PackedColorArray(entries)
					if raw.type == "PackedColorArray"
					else PackedFloat32Array(entries)
				)
			}
		if raw.type in ["PackedVector2Array", "PackedVector3Array"]:
			if not raw.get("value") is Array:
				return error("packed vectors require an Array")
			var vectors := []
			for entry in raw.value:
				var decoded := decode_value(
					{
						"type": "Vector2" if raw.type == "PackedVector2Array" else "Vector3",
						"value": entry
					}
				)
				if not decoded.ok:
					return decoded
				vectors.append(decoded.value)
			return {
				"ok": true,
				"value":
				(
					PackedVector2Array(vectors)
					if raw.type == "PackedVector2Array"
					else PackedVector3Array(vectors)
				)
			}
		var sizes := {
			"Vector2": 2,
			"Vector2i": 2,
			"Vector3": 3,
			"Vector3i": 3,
			"Vector4": 4,
			"Vector4i": 4,
			"Color": 4
		}
		if raw.type in sizes:
			var array: Variant = raw.get("value")
			if not array is Array or array.size() != sizes[raw.type]:
				return error("invalid vector/color shape")
			for number in array:
				if (
					typeof(number) not in [TYPE_INT, TYPE_FLOAT]
					or (str(raw.type).ends_with("i") and float(number) != floor(float(number)))
				):
					return error("vector components must be valid numbers")
		elif raw.type not in ["NodePath", "Basis", "Transform3D", "Rect2", "AABB"]:
			return error("unsupported construction Variant type")
	var result := VariantCodec.decode(normalized)
	return result if result.ok else error(result.error)


static func finite_json(value: Variant, depth: int = 0) -> bool:
	if depth > 16:
		return false
	if typeof(value) == TYPE_FLOAT:
		return is_finite(value)
	if value is Array or value is Dictionary:
		for key in value:
			if not finite_json(value[key] if value is Dictionary else key, depth + 1):
				return false
	return true


static func build_resource(spec: Dictionary, depth: int = 0) -> Dictionary:
	if depth > 16 or not spec.get("class") is String or spec.get("class") not in RESOURCE_TYPES:
		return error("unsupported construction resource class")
	if not spec.get("properties", {}) is Dictionary:
		return error("resource properties must be a Dictionary")
	var resource: Resource = ClassDB.instantiate(spec["class"])
	var prepared := prepare_properties(resource, spec.get("properties", {}))
	if not prepared.ok:
		return prepared
	var applied := apply_properties(resource, prepared.values)
	if not applied.ok:
		return applied
	return {"ok": true, "value": resource}


static func build_library(raw: Variant) -> Dictionary:
	if not raw is Dictionary or not raw.get("items", []) is Array:
		return error("mesh_library requires items Array")
	var library := MeshLibrary.new()
	for item in raw.get("items", []):
		if (
			not item is Dictionary
			or not integer(item.get("id"))
			or int(item.id) < 0
			or library.has_item(int(item.id))
		):
			return error("MeshLibrary item ids must be unique nonnegative integers")
		var mesh := decode_value(item.get("mesh"))
		if not mesh.ok:
			return mesh
		if not mesh.value is Mesh:
			return error("MeshLibrary item mesh must be a Mesh")
		var transform := decode_value(
			item.get("transform", VariantCodec.from_variant(Transform3D.IDENTITY))
		)
		if not transform.ok or not transform.get("value") is Transform3D:
			return error("MeshLibrary transform must be a Transform3D")
		if not item.get("name", "") is String:
			return error("MeshLibrary item name must be a String")
		library.create_item(int(item.id))
		library.set_item_name(int(item.id), item.get("name", ""))
		library.set_item_mesh(int(item.id), mesh.value)
		library.set_item_mesh_transform(int(item.id), transform.value)
	return {"ok": true, "value": library}


static func integer(value: Variant) -> bool:
	return (
		typeof(value) in [TYPE_INT, TYPE_FLOAT]
		and is_finite(float(value))
		and float(value) == floor(float(value))
	)


static func prepare_cells(raw: Variant, library: MeshLibrary) -> Dictionary:
	if not raw is Array or library == null:
		return error("cells require an Array and a MeshLibrary")
	var cells := []
	var seen := {}
	for entry in raw:
		if not entry is Dictionary:
			return error("each cell must be a Dictionary")
		var decoded := decode_value(entry.get("position"))
		if not decoded.ok or not decoded.get("value") is Vector3i:
			return error("cell position must be Vector3i")
		var position: Vector3i = decoded.value
		if (
			absi(position.x) > 32767
			or absi(position.y) > 32767
			or absi(position.z) > 32767
			or seen.has(position)
		):
			return error("cell positions must be unique signed 16-bit coordinates")
		if not integer(entry.get("item")) or int(entry.item) not in library.get_item_list():
			return error("cell item is not present in MeshLibrary")
		var orientation: Variant = entry.get("orientation", 0)
		if not integer(orientation) or int(orientation) < 0 or int(orientation) > 23:
			return error("cell orientation must be an integer in 0..23")
		seen[position] = true
		cells.append(
			{"position": position, "item": int(entry.item), "orientation": int(orientation)}
		)
	return {"ok": true, "value": cells}


static func build_multimesh(raw: Variant) -> Dictionary:
	if not raw is Dictionary or not raw.get("instances") is Array:
		return error("multimesh requires mesh and instances Array")
	var mesh := decode_value(raw.get("mesh"))
	if not mesh.ok:
		return mesh
	if not mesh.value is Mesh:
		return error("multimesh mesh must be a Mesh")
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_colors = true
	multi.use_custom_data = true
	multi.mesh = mesh.value
	multi.instance_count = raw.instances.size()
	var visible: Variant = raw.get("visible_instance_count", -1)
	if not integer(visible) or int(visible) < -1 or int(visible) > multi.instance_count:
		return error("visible_instance_count must be -1 or within instance_count")
	multi.visible_instance_count = int(visible)
	for index in multi.instance_count:
		var entry: Variant = raw.instances[index]
		if not entry is Dictionary:
			return error("each instance must be a Dictionary")
		var transform := decode_value(
			entry.get("transform", VariantCodec.from_variant(Transform3D.IDENTITY))
		)
		var color := decode_value(entry.get("color", VariantCodec.from_variant(Color.WHITE)))
		var custom := decode_value(
			entry.get("custom_data", VariantCodec.from_variant(Color(0, 0, 0, 0)))
		)
		if (
			not transform.ok
			or not transform.get("value") is Transform3D
			or not color.ok
			or not color.get("value") is Color
			or not custom.ok
			or not custom.get("value") is Color
		):
			return error("instance requires Transform3D transform and Color color/custom_data")
		multi.set_instance_transform(index, transform.value)
		multi.set_instance_color(index, color.value)
		multi.set_instance_custom_data(index, custom.value)
	return {"ok": true, "value": multi}


static func snapshot_cells(node: GridMap) -> Array:
	var cells := []
	for position in node.get_used_cells():
		cells.append(
			{
				"position": position,
				"item": node.get_cell_item(position),
				"orientation": node.get_cell_item_orientation(position)
			}
		)
	return cells


static func apply_cells(node: GridMap, cells: Array) -> void:
	node.clear()
	for cell in cells:
		node.set_cell_item(cell.position, cell.item, cell.orientation)


func restore_cells(node: GridMap, cells: Array) -> void:
	apply_cells(node, cells)


static func commit(
	target: Node,
	staged: Node,
	creating: bool,
	name: String,
	properties: Dictionary,
	cells_changed: bool
) -> Dictionary:
	var manager := EditAction.undo_redo()
	if manager == null:
		staged.free()
		return error("EditorUndoRedoManager unavailable", ErrorCodes.NOT_SUPPORTED)
	var owner: Node = EditorInterface.get_edited_scene_root()
	var published: Node = staged if creating else target
	manager.create_action("gdcli: configure " + staged.get_class(), UndoRedo.MERGE_DISABLE, owner)
	if creating:
		staged.name = name
		manager.add_do_method(target, "add_child", staged, true)
		manager.add_do_method(staged, "set_owner", owner)
		if staged is Camera3D:
			manager.add_do_property(staged, "current", staged.current)
		manager.add_do_reference(staged)
		manager.add_undo_method(target, "remove_child", staged)
	else:
		for key in properties:
			manager.add_do_property(target, key, staged.get(key))
			manager.add_undo_property(target, key, target.get(key))
		if cells_changed:
			var holder := GdApiScene3DEditor.new()
			manager.add_do_method(holder, "restore_cells", target, snapshot_cells(staged))
			manager.add_undo_method(holder, "restore_cells", target, snapshot_cells(target))
			manager.add_do_reference(holder)
	if staged is Camera3D and (creating or properties.has("current")):
		var cameras := owner.find_children("*", "Camera3D", true, false)
		if owner is Camera3D:
			cameras.append(owner)
		for camera in cameras:
			if camera != published:
				manager.add_undo_property(camera, "current", camera.get("current"))
	manager.commit_action()
	var verified := true
	for key in properties:
		verified = verified and published.get(key) == staged.get(key)
	if creating:
		verified = verified and staged.get_parent() == target and staged.owner == owner
	elif cells_changed:
		verified = verified and snapshot_cells(target) == snapshot_cells(staged)
	if not creating:
		staged.free()
	if not verified:
		manager.get_history_undo_redo(manager.get_object_history_id(owner)).undo()
		return error("construction read-back failed; action rolled back", ErrorCodes.GODOT_ERROR)
	var result := inspect(published)
	result.changed = true
	result.undoable = true
	return result


static func info(payload: Dictionary) -> Dictionary:
	if not payload.get("node_path", "") is String:
		return error("node_path must be a String")
	var found := NodeEditor.find(payload.get("node_path", ""))
	if not found.ok:
		return found
	if found.node.get_class() not in TYPES:
		return error("node is not a supported 3D construction type")
	return inspect(found.node)


static func inspect(node: Node) -> Dictionary:
	var properties := {}
	for meta in node.get_property_list():
		var key := str(meta.name)
		if int(meta.usage) & PROPERTY_USAGE_STORAGE and allowed_property(node, key):
			properties[key] = encode_value(node.get(key))
	var root: Node = (
		EditorInterface.get_edited_scene_root()
		if Engine.is_editor_hint()
		else (Engine.get_main_loop() as SceneTree).root
	)
	var path := (
		"/root/" + str(root.name)
		if node == root
		else "/root/" + str(root.name) + "/" + str(root.get_path_to(node))
	)
	if not Engine.is_editor_hint():
		path = str(node.get_path())
	var result := {
		"ok": true, "node_path": path, "type": node.get_class(), "properties": properties
	}
	if node is GridMap:
		var items := []
		if node.mesh_library != null:
			for id in node.mesh_library.get_item_list():
				items.append(
					{
						"id": id,
						"name": node.mesh_library.get_item_name(id),
						"mesh": encode_value(node.mesh_library.get_item_mesh(id)),
						"transform":
						VariantCodec.from_variant(node.mesh_library.get_item_mesh_transform(id))
					}
				)
		result.mesh_library = {"items": items}
		var cells := snapshot_cells(node)
		for cell in cells:
			cell.position = VariantCodec.from_variant(cell.position)
		result.cells = cells
	if node is MultiMeshInstance3D and node.multimesh != null:
		var multi: MultiMesh = node.multimesh
		var instances := []
		for index in multi.instance_count:
			instances.append(
				{
					"transform": VariantCodec.from_variant(multi.get_instance_transform(index)),
					"color":
					(
						VariantCodec.from_variant(multi.get_instance_color(index))
						if multi.use_colors
						else null
					),
					"custom_data":
					(
						VariantCodec.from_variant(multi.get_instance_custom_data(index))
						if multi.use_custom_data
						else null
					)
				}
			)
		result.multimesh = {
			"mesh": encode_value(multi.mesh),
			"instances": instances,
			"visible_instance_count": multi.visible_instance_count
		}
	return result


static func encode_value(value: Variant, depth: int = 0) -> Variant:
	if value is PackedColorArray:
		var entries := []
		for color in value:
			entries.append(VariantCodec.from_variant(color).value)
		return {"type": "PackedColorArray", "value": entries}
	if value is PackedFloat32Array:
		return {"type": "PackedFloat32Array", "value": Array(value)}
	if value is PackedVector2Array or value is PackedVector3Array:
		var entries := []
		for vector in value:
			entries.append(VariantCodec.from_variant(vector).value)
		return {
			"type": "PackedVector2Array" if value is PackedVector2Array else "PackedVector3Array",
			"value": entries
		}
	if value is Resource:
		if depth >= 8:
			return {"class": value.get_class(), "path": value.resource_path}
		var properties := {}
		for meta in value.get_property_list():
			var key := str(meta.name)
			if int(meta.usage) & PROPERTY_USAGE_STORAGE and allowed_property(value, key):
				properties[key] = encode_value(value.get(key), depth + 1)
		return {"class": value.get_class(), "path": value.resource_path, "properties": properties}
	return VariantCodec.from_variant(value)
