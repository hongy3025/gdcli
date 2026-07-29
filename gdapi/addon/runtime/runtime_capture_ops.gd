## Runtime screenshot and frame capture in the game process.
##
## Validation is intentionally separated from GPU readback so malformed or
## impossible requests fail before waiting for a frame or allocating image data.

@tool
class_name GdApiRuntimeCaptureOps
extends RefCounted

const Protocol := preload("res://addons/gdapi/runtime/runtime_protocol.gd")

const MAX_WIDTH := 1920
const MAX_HEIGHT := 1080
const MAX_FRAMES := 60
const MAX_INTERVAL_MS := 1000
const MAX_OPERATION_TIMEOUT_MS := 25_000
const DEFAULT_OPERATION_TIMEOUT_MS := 5000
const MAX_CAMERA_PATH_LENGTH := 1024
const MAX_ENCODED_BYTES := Protocol.MAX_MESSAGE_BYTES
const PROTOCOL_ENVELOPE_RESERVE := 512

static func viewport(payload: Dictionary) -> Dictionary:
	var validated := validate_viewport_payload(payload)
	if not bool(validated.get("ok", false)):
		return validated
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return _failure("not_found", "scene viewport is unavailable")
	var deadline_msec := Time.get_ticks_msec() + int(validated.timeout_ms)
	await RenderingServer.frame_post_draw
	if _deadline_reached(deadline_msec):
		return _failure("timeout", "viewport capture timed out")
	return _capture_viewport(tree.root, {})

static func camera(payload: Dictionary) -> Dictionary:
	var validated := validate_camera_payload(payload)
	if not bool(validated.get("ok", false)):
		return validated
	var resolved := _resolve_camera(String(validated.node_path))
	if not bool(resolved.get("ok", false)):
		return resolved
	var deadline_msec := Time.get_ticks_msec() + int(validated.timeout_ms)
	await RenderingServer.frame_post_draw
	if _deadline_reached(deadline_msec):
		return _failure("timeout", "camera capture timed out")
	return _capture_viewport(resolved.viewport, {"camera": validated.node_path})

static func frames(payload: Dictionary) -> Dictionary:
	var validated := validate_frames_payload(payload)
	if not bool(validated.get("ok", false)):
		return validated
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return _failure("not_found", "scene viewport is unavailable")
	var source: Viewport = tree.root
	if not String(validated.camera_path).is_empty():
		var resolved := _resolve_camera(String(validated.camera_path))
		if not bool(resolved.get("ok", false)):
			return resolved
		source = resolved.viewport

	var deadline_msec := Time.get_ticks_msec() + int(validated.timeout_ms)
	var frames_arr: Array = []
	for i in int(validated.count):
		if i > 0:
			await tree.create_timer(float(validated.interval_ms) / 1000.0).timeout
			if _deadline_reached(deadline_msec):
				return _failure("timeout", "frame capture timed out")
		await RenderingServer.frame_post_draw
		if _deadline_reached(deadline_msec):
			return _failure("timeout", "frame capture timed out")
		var captured := _capture_viewport(source, {"index": i}, {
			"frames": frames_arr,
			"count": frames_arr.size(),
		})
		if not bool(captured.get("ok", false)):
			return captured
		var frame: Dictionary = captured.result
		frames_arr.append(frame)
		var aggregate := {"frames": frames_arr, "count": frames_arr.size()}
		if not protocol_result_fits(aggregate):
			return _failure("invalid_param", "encoded capture reply exceeds 4 MiB")
	return {"ok": true, "result": {"frames": frames_arr, "count": frames_arr.size()}}

static func validate_viewport_payload(payload: Variant) -> Dictionary:
	if typeof(payload) != TYPE_DICTIONARY:
		return _failure("invalid_param", "capture payload must be an object")
	var timeout := _strict_integer(payload, "timeout_ms", DEFAULT_OPERATION_TIMEOUT_MS, 1,
		MAX_OPERATION_TIMEOUT_MS)
	if not bool(timeout.get("ok", false)):
		return timeout
	return {"ok": true, "timeout_ms": timeout.value}

static func validate_camera_payload(payload: Variant) -> Dictionary:
	var common := validate_viewport_payload(payload)
	if not bool(common.get("ok", false)):
		return common
	if not payload.has("node_path"):
		return _failure("missing_param", "node_path is required")
	var path_result := validate_camera_path(payload.get("node_path"), true)
	if not bool(path_result.get("ok", false)):
		return path_result
	return {"ok": true, "timeout_ms": common.timeout_ms, "node_path": path_result.path}

static func validate_frames_payload(payload: Variant) -> Dictionary:
	var common := validate_viewport_payload(payload)
	if not bool(common.get("ok", false)):
		return common
	var count := _strict_integer(payload, "count", 2, 1, MAX_FRAMES)
	if not bool(count.get("ok", false)):
		return count
	var interval := _strict_integer(payload, "interval_ms", 16, 1, MAX_INTERVAL_MS)
	if not bool(interval.get("ok", false)):
		return interval
	var camera_path := validate_camera_path(payload.get("camera_path", ""), false)
	if not bool(camera_path.get("ok", false)):
		return camera_path
	var theoretical_duration := (int(count.value) - 1) * int(interval.value)
	if theoretical_duration >= int(common.timeout_ms):
		return _failure("invalid_param", "frame duration must be less than timeout_ms")
	return {
		"ok": true,
		"count": count.value,
		"interval_ms": interval.value,
		"timeout_ms": common.timeout_ms,
		"camera_path": camera_path.path,
	}

static func validate_camera_path(value: Variant, required: bool) -> Dictionary:
	if typeof(value) != TYPE_STRING:
		return _failure("invalid_param", "camera path must be a string")
	var path := String(value)
	if path.is_empty():
		if required:
			return _failure("missing_param", "camera path is required")
		return {"ok": true, "path": ""}
	if path.length() > MAX_CAMERA_PATH_LENGTH:
		return _failure("invalid_param", "camera path is too long")
	if not path.begins_with("/root/") or path.contains("..") or path.contains("//"):
		return _failure("invalid_param", "camera path must be an absolute /root path")
	return {"ok": true, "path": path}

static func fit_dimensions(width: int, height: int) -> Vector2i:
	if width <= 0 or height <= 0:
		return Vector2i.ZERO
	if width <= MAX_WIDTH and height <= MAX_HEIGHT:
		return Vector2i(width, height)
	var scale := min(float(MAX_WIDTH) / float(width), float(MAX_HEIGHT) / float(height))
	return Vector2i(maxi(1, int(floor(width * scale))), maxi(1, int(floor(height * scale))))

## Check the complete protocol reply, including a conservative id/generation envelope.
static func protocol_result_fits(result: Variant) -> bool:
	var envelope := Protocol.reply(9_223_372_036_854_775_807, true, result, "", "",
		"g".repeat(128))
	return JSON.stringify(envelope).to_utf8_buffer().size() <= MAX_ENCODED_BYTES

static func _resolve_camera(node_path: String) -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return _failure("not_found", "scene tree is unavailable")
	var node := tree.root.get_node_or_null(NodePath(node_path))
	if node == null:
		return _failure("not_found", "camera node not found")
	var viewport: Viewport = null
	if node is Camera2D:
		viewport = (node as Camera2D).get_viewport()
	elif node is Camera3D:
		viewport = (node as Camera3D).get_viewport()
	else:
		return _failure("invalid_param", "camera path must point to Camera2D or Camera3D")
	if viewport == null:
		return _failure("not_found", "camera viewport is unavailable")
	return {"ok": true, "viewport": viewport}

## GPU readback cannot be avoided for a screenshot. Texture dimensions are checked
## first, then the returned Image is resized before PNG/base64 allocation.
static func _capture_viewport(viewport_node: Viewport, metadata: Dictionary,
		current_result: Dictionary = {}) -> Dictionary:
	if viewport_node == null:
		return _failure("not_found", "viewport is unavailable")
	var texture := viewport_node.get_texture()
	if texture == null:
		return _failure("godot_error", "viewport texture is unavailable")
	var texture_size := fit_dimensions(texture.get_width(), texture.get_height())
	if texture_size == Vector2i.ZERO:
		return _failure("godot_error", "viewport texture has invalid dimensions")
	var image := texture.get_image()
	if image == null or image.is_empty():
		return _failure("godot_error", "viewport image is unavailable")
	var target_size := fit_dimensions(image.get_width(), image.get_height())
	if target_size == Vector2i.ZERO:
		return _failure("godot_error", "viewport image has invalid dimensions")
	if image.get_width() != target_size.x or image.get_height() != target_size.y:
		image.resize(target_size.x, target_size.y, Image.INTERPOLATE_BILINEAR)
	var png_bytes := image.save_png_to_buffer()
	if png_bytes.is_empty():
		return _failure("godot_error", "viewport PNG encoding failed")
	var estimated_base64 := ((png_bytes.size() + 2) / 3) * 4
	var occupied := _protocol_size(current_result)
	if estimated_base64 + occupied + PROTOCOL_ENVELOPE_RESERVE > MAX_ENCODED_BYTES:
		return _failure("invalid_param", "encoded capture reply exceeds 4 MiB")
	var item: Dictionary = {
		"mime": "image/png",
		"width": image.get_width(),
		"height": image.get_height(),
		"sha256": png_bytes_to_sha256(png_bytes),
		"data_base64": Marshalls.raw_to_base64(png_bytes),
	}
	item.merge(metadata, true)
	if not protocol_result_fits(item if current_result.is_empty() else {
		"frames": current_result.get("frames", []) + [item],
		"count": int(current_result.get("count", 0)) + 1,
	}):
		return _failure("invalid_param", "encoded capture reply exceeds 4 MiB")
	return {"ok": true, "result": item}

static func _protocol_size(result: Variant) -> int:
	var envelope := Protocol.reply(9_223_372_036_854_775_807, true, result, "", "",
		"g".repeat(128))
	return JSON.stringify(envelope).to_utf8_buffer().size()

static func _strict_integer(payload: Dictionary, key: String, default_value: int,
		minimum: int, maximum: int) -> Dictionary:
	if not payload.has(key):
		return {"ok": true, "value": default_value}
	var raw: Variant = payload[key]
	if typeof(raw) == TYPE_INT:
		if raw < minimum or raw > maximum:
			return _failure("invalid_param", "%s is outside the allowed range" % key)
		return {"ok": true, "value": int(raw)}
	if typeof(raw) == TYPE_FLOAT:
		var number := float(raw)
		if not is_finite(number) or number != floor(number):
			return _failure("invalid_param", "%s must be a finite integer" % key)
		if number < float(minimum) or number > float(maximum):
			return _failure("invalid_param", "%s is outside the allowed range" % key)
		return {"ok": true, "value": int(number)}
	return _failure("invalid_param", "%s must be an integer" % key)

static func _deadline_reached(deadline_msec: int) -> bool:
	return Time.get_ticks_msec() >= deadline_msec

static func _failure(code: String, error: String) -> Dictionary:
	return {"ok": false, "code": code, "error": error}

static func png_bytes_to_sha256(png_bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(png_bytes)
	return context.finish().hex_encode()
