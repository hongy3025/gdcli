@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/audio_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(
		res,
		Editor.create_player(
			req.get_body("parent_path", "/root/AudioDomain"),
			req.get_body("name", null),
			req.get_body("stream_path", null)
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
		. make("创建音频播放器")
		. mutates()
		. param("parent_path", "String", false, "父节点", "/root/AudioDomain")
		. param("name", "String", true, "节点名", "")
		. param("stream_path", "String", true, "AudioStream 资源路径", "")
		. example('{"name":"Player","stream_path":"res://resources/tone.tres"}')
		. returns("player", {"changed": "bool", "undoable": "true", "node_path": "String"})
	)
