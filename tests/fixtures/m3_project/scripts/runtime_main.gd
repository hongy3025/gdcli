extends Node2D

## RuntimeMain — M3 fixture 根节点
##
## 包含可观测子节点 ProbeTarget 与若干 Input 中继节点。
## 启动时直接放置到主场景树中。

@onready var probe_target: Node = $ProbeTarget
@onready var probe_input: Node = $ProbeInput
@onready var probe_input_action: Node = $ProbeInputAction
@onready var probe_finished_signal: Node = $ProbeFinishedSignal

func reset_fixture() -> Dictionary:
	_remove_runtime_children(self)
	probe_target.reset_fixture()
	return {"changed": true, "undoable": false}

func prepare_capture_fixture(mode: String) -> Dictionary:
	var existing := get_node_or_null("CaptureFixtureViewport")
	if existing != null:
		existing.free()
	if not mode in ["camera", "high_entropy", "delayed", "oversized"]:
		return {"ok": false, "error": "unknown fixed capture fixture mode"}
	var viewport := SubViewport.new()
	viewport.name = "CaptureFixtureViewport"
	if mode == "high_entropy":
		viewport.size = Vector2i(1280, 900)
	elif mode == "oversized":
		viewport.size = Vector2i(1921, 1080)
	else:
		viewport.size = Vector2i(96, 54)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.set_meta("gdapi_capture_readback_counter_path",
		NodePath("/root/RuntimeMain/ProbeTarget"))
	if mode == "delayed":
		viewport.set_meta("gdapi_capture_fixture_delay", true)
	if mode == "high_entropy":
		viewport.set_meta("gdapi_capture_fixture_image", _make_high_entropy_image())
	add_child(viewport)

	var background := ColorRect.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.color = Color(0.12, 0.25, 0.55, 1.0)
	viewport.add_child(background)
	var camera := Camera2D.new()
	camera.name = "CaptureFixtureCamera"
	camera.enabled = true
	viewport.add_child(camera)
	return {
		"ok": true,
		"camera_path": "/root/RuntimeMain/CaptureFixtureViewport/CaptureFixtureCamera",
	}

func _make_high_entropy_image() -> Image:
	const WIDTH := 1280
	const HEIGHT := 900
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

func _remove_runtime_children(parent: Node) -> void:
	for child in parent.get_children():
		if child == probe_target or child == probe_input or child == probe_input_action or child == probe_finished_signal:
			_remove_runtime_children(child)
		else:
			child.free()
