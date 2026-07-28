## runtime/node/call — 在运行期节点上调用方法(仅限 allowlist)

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/node/call", true)

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("调用运行期节点方法(allowlist)")
		.desc("只有节点元数据 gdapi_callable_methods 中列出的方法名才会被允许;其它方法返回 permission_denied。args 是位置参数数组。")
		.param("node_path", "String", true, "节点路径", "")
		.param("method", "String", true, "方法名", "")
		.param("args", "Array", false, "位置参数,可含 Variant 编码值", "[]")
		.example("{\"node_path\":\"/root/RuntimeMain/ProbeTarget\",\"method\":\"increment\",\"args\":[2]}")
		.returns("调用结果", {
			"result": "Object, Variant 编码后的返回值",
			"method": "String",
		})
	)
