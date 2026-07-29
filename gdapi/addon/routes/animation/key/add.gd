@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/animation_editor.gd")
const Codec := preload("res://addons/gdapi/runtime/variant_codec.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var decoded := Codec.decode(req.get_body("value", null))
	if not decoded.ok:
		res.error(decoded.error, "invalid_param", 400)
		return
	_send(
		res,
		Editor.add_key(
			req.get_body("player_path", ""),
			req.get_body("name", ""),
			int(req.get_body("track_index", -1)),
			float(req.get_body("time", -1.0)),
			decoded.value
		)
	)


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("添加动画 key")
		. desc("在指定 AnimationPlayer 动画 track 的时间点添加类型化 key；编辑器修改支持 UndoRedo。")
		. param("player_path", "String", true, "AnimationPlayer 路径", "")
		. param("name", "String", true, "动画名", "")
		. param("track_index", "int", true, "track 索引", "")
		. param("time", "float", true, "秒", "")
		. param("value", "Variant", true, "key 值", "")
		. example(
			'{"player_path":"AnimationPlayer","name":"idle","track_index":0,"time":0.5,"value":{"x":10,"y":20}}'
		)
		. returns("key 结果", {"key_index": "int", "undoable": "bool, true"})
	)
