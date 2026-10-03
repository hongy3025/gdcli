@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const Editor := preload("res://addons/gdapi/runtime/services/audio_editor.gd")


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	_send(res, Editor.play(req.get_body("node_path", null)))


func _send(res: GdApiResponse, result: Dictionary) -> void:
	if result.ok:
		res.json(result)
	else:
		res.error(result.error, result.code, 400)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("播放音频")
		. desc(
			"在编辑器当前打开的场景中调用 AudioStreamPlayer.play()（作用于编辑器节点，" + "不是运行中的游戏），并回读节点真实的 playing 状态。"
		)
		. param("node_path", "String", true, "AudioStreamPlayer 路径", "")
		. example('{"node_path":"AudioPlayer"}')
		. returns("play", {"playing": "bool, AudioStreamPlayer.playing 回读值", "undoable": "false"})
	)
