## script/current 路由: 获取 Script Editor 当前打开的脚本

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const TextEdit := preload("res://addons/gdapi/runtime/services/text_edit.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "script/current"

func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	if not Engine.is_editor_hint():
		res.error("script/current requires editor", ErrorCodes.NOT_SUPPORTED, 400)
		return
	res.json({
		"ok": true,
		"path": TextEdit.current_script(),
		"undoable": false,
	})


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("读取 Script Editor 当前编辑的脚本路径")
		.desc("未打开任何脚本时返回空字符串。")
		.returns("script/current", {
			"ok": "bool",
			"path": "String, 空表示 Script Editor 尚未打开脚本",
			"undoable": "bool, false",
		})
	)
