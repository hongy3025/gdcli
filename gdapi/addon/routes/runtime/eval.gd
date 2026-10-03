@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"

const ROUTE := "runtime/eval"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch_versioned(req, res, "eval", Protocol.VERSION_V2, true, ROUTE)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("执行受限的运行时表达式")
		. mutates()
		. desc("使用与 editor/eval 相同的受限语法（源码上限 16 KiB）；运行时未连接时返回 conflict；仅 v2 协议可用。")
		. param("source", "String", true, "受限 Expression 源码")
		. param("inputs", "Dictionary", false, "输入值")
		. returns(
			"表达式结果",
			{"value": "encoded Variant", "type": "String", "elapsed_ms": "int", "undoable": "false"}
		)
		. example('{"source":"1+1"}')
	)
