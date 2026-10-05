extends Node2D

const CaptureOps := preload("res://addons/gdapi/runtime/runtime_capture_ops.gd")


class CaptureBoundaryTexture:
	extends RefCounted

	var width: int
	var height: int
	var width_delay_ms: int
	var readback_count := 0

	func _init(p_width: int, p_height: int, p_width_delay_ms: int = 0) -> void:
		width = p_width
		height = p_height
		width_delay_ms = p_width_delay_ms

	func get_width() -> int:
		if width_delay_ms > 0:
			OS.delay_msec(width_delay_ms)
		return width

	func get_height() -> int:
		return height

	func get_image() -> Image:
		readback_count += 1
		return Image.create(width, height, false, Image.FORMAT_RGBA8)


## RuntimeMain — M3 fixture 根节点
##
## 包含可观测子节点 ProbeTarget 与若干 Input 中继节点。
## 启动时直接放置到主场景树中。


func prepare_capture_fixture(mode: String) -> Dictionary:
	if not mode in ["camera", "high_entropy", "oversized"]:
		return {"ok": false, "error": "unknown fixed capture fixture mode"}
	var existing := get_node_or_null("CaptureFixtureViewport")
	if existing != null:
		existing.free()
	var viewport := SubViewport.new()
	viewport.name = "CaptureFixtureViewport"
	if mode == "high_entropy":
		viewport.size = Vector2i(1024, 600)
	elif mode == "oversized":
		viewport.size = Vector2i(1921, 1080)
	else:
		viewport.size = Vector2i(96, 54)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)

	if mode == "high_entropy":
		var noise := TextureRect.new()
		noise.texture = ImageTexture.create_from_image(_make_high_entropy_image())
		noise.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		noise.stretch_mode = TextureRect.STRETCH_SCALE
		noise.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		viewport.add_child(noise)
		noise.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	else:
		var background := ColorRect.new()
		background.color = Color(0.12, 0.25, 0.55, 1.0)
		viewport.add_child(background)
		background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var camera := Camera2D.new()
	camera.name = "CaptureFixtureCamera"
	camera.position = Vector2(viewport.size) / 2.0
	camera.enabled = true
	viewport.add_child(camera)
	return {
		"ok": true,
		"camera_path": "/root/RuntimeMain/CaptureFixtureViewport/CaptureFixtureCamera",
	}


func probe_capture_boundary(mode: String) -> Dictionary:
	if not mode in ["oversized", "expired"]:
		return {"ok": false, "error": "unknown fixed capture boundary mode"}
	var texture: CaptureBoundaryTexture
	var deadline_msec := -1
	if mode == "oversized":
		texture = CaptureBoundaryTexture.new(1921, 1080)
	else:
		texture = CaptureBoundaryTexture.new(96, 54, 5)
		deadline_msec = Time.get_ticks_msec() + 1
	var capture_result := CaptureOps.capture_texture(texture, {}, {}, deadline_msec)
	return {
		"ok": true,
		"capture_ok": bool(capture_result.get("ok", false)),
		"code": String(capture_result.get("code", "")),
		"readbacks": texture.readback_count,
	}


func _make_high_entropy_image() -> Image:
	const WIDTH := 1024
	const HEIGHT := 600
	var bytes := PackedByteArray()
	bytes.resize(WIDTH * HEIGHT * 3)
	var state: int = 0x13579BDF
	for i in bytes.size():
		state ^= (state << 13) & 0xffffffff
		state ^= state >> 17
		state ^= (state << 5) & 0xffffffff
		state &= 0xffffffff
		bytes[i] = state & 0xff
	return Image.create_from_data(WIDTH, HEIGHT, false, Image.FORMAT_RGB8, bytes)
