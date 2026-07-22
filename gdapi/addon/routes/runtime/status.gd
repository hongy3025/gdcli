## runtime/status — 查询运行期 broker 状态
##
## 提供 stopped / connecting / connected 三态、session_id、pending 计数、
## 当前协议版本号。
## 该 route 一定同步回复;不依赖任何运行期游戏进程。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const RuntimeBroker := preload("res://addons/gdapi/runtime/runtime_broker.gd")

## 处理 status 请求
##
## 即使 broker 未注册也返回 ok:true 加默认 stopped state,
## 便于 runtime/* 子系统缺席时不报"找不到 route"错误。
##
## @param _req 请求对象,不需要特定参数
## @param res 响应对象
func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	var broker: Variant = RuntimeBroker.instance()
	if broker == null:
		res.json({
			"ok": true,
			"state": "stopped",
			"protocol_version": 1,
			"session_id": -1,
			"pending": 0,
			"broker_registered": false,
		})
		return
	var status: Dictionary = broker.status()
	status["ok"] = true
	status["broker_registered"] = true
	res.json(status)

## 返回该路由的帮助文档
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("查询运行期 broker 状态")
		.desc("返回 stopped|connecting|connected 三态,运行 protocol_version,以及当前等待中的回调数量。不需要任何 payload。")
		.returns("状态结果", {
			"ok": "bool",
			"state": "String, stopped|connecting|connected",
			"protocol_version": "int, 当前为 1",
			"session_id": "int, EditorDebuggerSession 的 id;未连接时为 -1",
			"pending": "int, 当前等待回复的请求数",
			"broker_registered": "bool, broker 是否已注册到 Engine meta",
			"session_started_at": "float, 当前 broker 首次 attach 的 unix 时间戳;从未 attach 时为 0",
		})
	)
