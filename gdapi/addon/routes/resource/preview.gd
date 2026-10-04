@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Editor := preload("res://addons/gdapi/runtime/services/resource_editor.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := await Editor.preview(
		req.get_body("path", null),
		req.get_body("width", 0),
		req.get_body("height", 0),
		req.get_body("deadline_ms", 5000)
	)
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("生成资源 PNG 预览")
		. desc(
			(
				"Texture2D 直接读取真实 Image；其他资源由 EditorResourcePreview 生成，"
				+ "超时/无生成器返回明确错误。最近邻缩放；"
				+ "双尺寸为零时最长边不超过 256，单尺寸保留比例。"
			)
		)
		. param("path", "String", true, "res:// 或 user:// 资源路径")
		. param("width", "int", false, "输出宽度，0 自动；上限 4096", 0)
		. param("height", "int", false, "输出高度，0 自动；上限 4096", 0)
		. param("deadline_ms", "int", false, "编辑器预览生成期限 1-30000ms", 5000)
		. example('{"path":"res://resources/tile.svg"}')
		. returns(
			"result",
			{
				"png_base64": "String",
				"format": "png",
				"width": "int",
				"height": "int",
				"source": "String"
			}
		)
	)
