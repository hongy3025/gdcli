@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/assert/screen_text")


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Assert visible runtime Control text")
		. desc(
			(
				"Reads visible Label, Button, RichTextLabel, LineEdit and TextEdit text "
				+ "in the running scene; no OCR or fabricated text."
			)
		)
		. param("text", "String", true, "Expected text")
		. param("node_path", "String", false, "Subtree root; default /root")
		. param("match", "String", false, "contains (default) or equals")
		. param("timeout_ms", "int", false, "1..25000 ms polling deadline")
		. example('{"text":"Ready"}')
		. returns(
			"Text match",
			{"matched": "bool", "node_path": "String", "text": "String", "source": "Control.text"}
		)
	)
