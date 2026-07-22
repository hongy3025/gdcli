## 运行时截图/截帧实现
##
## 使用 RenderingServer.frame_post_draw 等待当前帧渲染完成，
## 然后读取 viewport.get_texture().get_image() 后 save_png_to_buffer。
## viewport/camera 单帧,frames 多次采样。

@tool
class_name GdApiRuntimeCaptureOps
extends RefCounted

const MAX_DIMENSION := 1920
const MAX_FRAMES := 60
const MAX_ENCODED_BYTES := 4 * 1024 * 1024

## viewport:截主视口一帧
static func viewport(payload: Dictionary) -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return {"ok": false, "code": "not_found", "error": "scene tree unavailable"}
	var root: Window = tree.root
	if root == null:
		return {"ok": false, "code": "not_found", "error": "scene root unavailable"}
	await RenderingServer.frame_post_draw
	var image: Image = root.get_texture().get_image()
	if image == null:
		return {"ok": false, "code": "godot_error", "error": "viewport image is null"}
	image = _fit_to_limits(image)
	var png_bytes: PackedByteArray = image.save_png_to_buffer()
	if png_bytes.size() > MAX_ENCODED_BYTES:
		return {"ok": false, "code": "invalid_param", "error": "encoded PNG exceeds 4 MiB"}
	return {
		"ok": true,
		"result": {
			"mime": "image/png",
			"width": image.get_width(),
			"height": image.get_height(),
			"sha256": png_bytes_to_sha256(png_bytes),
			"data_base64": Marshalls.raw_to_base64(png_bytes),
		},
	}

## camera:按 node_path 找 Camera2D/3D,使用其 viewport 截图
static func camera(payload: Dictionary) -> Dictionary:
	var node_path: String = String(payload.get("node_path", ""))
	if node_path.is_empty():
		return {"ok": false, "code": "missing_param", "error": "node_path is required"}
	var tree := Engine.get_main_loop() as SceneTree
	var root: Node = tree.root
	var lookup_node: Node = root.get_node_or_null(NodePath(node_path))
	if lookup_node == null:
		return {"ok": false, "code": "not_found", "error": "camera node not found"}
	var viewport: Viewport = null
	if lookup_node is Camera2D:
		viewport = (lookup_node as Camera2D).get_viewport()
	elif lookup_node is Camera3D:
		viewport = (lookup_node as Camera3D).get_viewport()
	else:
		return {"ok": false, "code": "invalid_param", "error": "node_path does not point to a Camera2D or Camera3D"}
	if viewport == null:
		return {"ok": false, "code": "not_found", "error": "camera has no viewport"}
	await RenderingServer.frame_post_draw
	var image: Image = viewport.get_texture().get_image()
	if image == null:
		return {"ok": false, "code": "godot_error", "error": "viewport image is null"}
	image = _fit_to_limits(image)
	var png_bytes: PackedByteArray = image.save_png_to_buffer()
	return {
		"ok": true,
		"result": {
			"mime": "image/png",
			"width": image.get_width(),
			"height": image.get_height(),
			"sha256": png_bytes_to_sha256(png_bytes),
			"data_base64": Marshalls.raw_to_base64(png_bytes),
			"camera": node_path,
		},
	}

## frames:逐帧采集
static func frames(payload: Dictionary) -> Dictionary:
	var count: int = clampi(int(payload.get("count", 2)), 1, MAX_FRAMES)
	var interval_ms: int = clampi(int(payload.get("interval_ms", 16)), 1, 1000)
	var camera_path: String = String(payload.get("camera_path", ""))
	var tree := Engine.get_main_loop() as SceneTree
	var frames_arr: Array = []
	var cam_viewport: Viewport = null
	if not camera_path.is_empty():
		var cam_node: Node = tree.root.get_node_or_null(NodePath(camera_path))
		if cam_node is Camera2D:
			cam_viewport = (cam_node as Camera2D).get_viewport()
		elif cam_node is Camera3D:
			cam_viewport = (cam_node as Camera3D).get_viewport()
	for i in count:
		if cam_viewport != null:
			await RenderingServer.frame_post_draw
		else:
			await tree.create_timer(interval_ms / 1000.0).timeout
		var source: Viewport = cam_viewport if cam_viewport != null else tree.root
		var image: Image = source.get_texture().get_image()
		if image == null:
			frames_arr.append({"error": "viewport image is null"})
			continue
		var png_bytes: PackedByteArray = image.save_png_to_buffer()
		frames_arr.append({
			"index": i,
			"width": image.get_width(),
			"height": image.get_height(),
			"sha256": png_bytes_to_sha256(png_bytes),
			"data_base64": Marshalls.raw_to_base64(png_bytes),
		})
	return {
		"ok": true,
		"result": {
			"frames": frames_arr,
			"count": frames_arr.size(),
		},
	}

## 等比例缩放到不超 1920x1080
static func _fit_to_limits(image: Image) -> Image:
	var w: int = image.get_width()
	var h: int = image.get_height()
	if w <= MAX_DIMENSION and h <= MAX_DIMENSION:
		return image
	var scale_w: float = float(MAX_DIMENSION) / float(w)
	var scale_h: float = float(MAX_DIMENSION) / float(h)
	var scale: float = min(scale_w, scale_h)
	image.resize(max(1, int(w * scale)), max(1, int(h * scale)), Image.INTERPOLATE_BILINEAR)
	return image

## 利用 Crypto 类算 sha256
static func png_bytes_to_sha256(png_bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(png_bytes)
	return ctx.finish().hex_encode()
