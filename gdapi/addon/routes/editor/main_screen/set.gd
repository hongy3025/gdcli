## editor/main_screen/set 路由: 切换主编辑器面板

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "editor/main_screen/set"

const ALLOWED_SCREENS := ["2D", "3D", "Script", "AssetLib", "Game", "Asset", "Library"]

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var screen: String = req.get_body("screen", "")
	if screen == "":
		res.error("screen is required", ErrorCodes.MISSING_PARAM)
		return
	if screen not in ALLOWED_SCREENS:
		res.error("screen must be one of: " + str(ALLOWED_SCREENS), ErrorCodes.INVALID_PARAM)
		return
	if not Engine.is_editor_hint():
		res.error("editor only", ErrorCodes.NOT_SUPPORTED, 400)
		return
	EditorInterface.set_main_screen_editor(screen)
	res.json({
		"ok": true,
		"changed": true,
		"undoable": false,
		"screen": screen,
	})


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("切换 Godot 编辑器主面板")
		.desc("通过 EditorInterface.set_main_screen_editor 切换,只接受 2D/3D/Script/AssetLib 等内置标识。")
		.param("screen", "String", true, "主面板标识,允许 2D, 3D, Script, AssetLib 等")
		.example("{\"screen\":\"Script\"}")
		.returns("切换结果", {
			"ok": "bool",
			"changed": "bool",
			"screen": "String",
			"undoable": "bool, false",
		})
	)
