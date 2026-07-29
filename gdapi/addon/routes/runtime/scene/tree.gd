## runtime/scene/tree — 列出运行期当前场景树
##
## 把 SceneTree.root 序列化为嵌套字典,max_depth 限制递归层数。

@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


## 处理请求:仅一个 max_depth 参数
##
## @param req 请求对象,可选 max_depth(默认 16,最大 32)
## @param res 响应对象
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/scene/tree")


## 返回该路由的帮助文档
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("查询运行期场景树")
		. desc("把 SceneTree.root 序列化为嵌套字典;默认 max_depth=16,可设置 1..32。")
		. param("max_depth", "int", false, "最大递归深度,默认 16", "16")
		. example('{"max_depth":2}')
		. returns(
			"场景树",
			{
				"root": "Object, 含 name/type/path/children",
			}
		)
	)
