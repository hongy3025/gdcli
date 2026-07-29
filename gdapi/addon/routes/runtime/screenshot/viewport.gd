## runtime/screenshot/viewport — 截主视口当前帧
##
## 等 RenderingServer.frame_post_draw 后从 viewport.get_texture().get_image() 中读取。

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/screenshot/viewport", false)

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("截主视口当前帧")
		.desc("等 RenderingServer.frame_post_draw 后取 SceneTree.root viewport 纹理,缩放不超过 1920x1080,返回 PNG 的 base64 编码加 sha256。")
		.returns("截图结果", {
			"mime": "String, 固定 image/png",
			"width": "int",
			"height": "int",
			"sha256": "String, 编码后的 PNG sha256",
			"data_base64": "String, PNG 字节的 base64",
		})
	)
