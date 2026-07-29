## 运行时协议消息模型
##
## 定义编辑器 ↔ 运行游戏双向消息的 wire format 和校验规则。
## 不依赖 Godot 类，可被编辑器插件和游戏进程同时加载。
##
## 设计要点：
## - 只定义消息 schema 和常量，不持有运行期状态；
## - 拒绝已被推迟到 M6 的高风险 op，避免协议层留口子；
## - 消息体积上限为 4 MiB，超出后服务端必须分页或降级；
## - request 和 reply 必须有匹配的整数 id，event 不需要应答。

@tool
class_name GdApiRuntimeProtocol
extends RefCounted

## 协议主版本号。客户端与服务端必须匹配。
const VERSION := 1

## 单条消息序列化后最大字节数；超出后 validate_message 返回 invalid_param。
## 4 MiB 涵盖当前所有 payload（含 base64 screenshot/frames）。
const MAX_MESSAGE_BYTES := 4 * 1024 * 1024

## 在协议 v1 永久拒绝的 op。M6 引入这些能力时必须提升 VERSION。
## 这些名字以独立常量导出，方便 runtime_probe 和其它模块复用。
const DENIED_OPS := {
	"eval": true,
	"process/run": true,
	"network/http_request": true,
}


## 构造一个 protocol v1 request 消息
##
## @param id 由调用方分配的正整数；客户端必须保证唯一性
## @param op 路由名，如 "runtime/status"、"runtime/node/get"
## @param payload 业务字段字典；缺省或 null 都会被规范化为空字典
## @return 完整消息字典，可直接 JSON.stringify
static func request(
	id: int, op: String, payload: Variant = null, generation: String = ""
) -> Dictionary:
	var normalized: Dictionary = {}
	if typeof(payload) == TYPE_DICTIONARY:
		normalized = payload
	var message := {
		"version": VERSION,
		"id": int(id),
		"kind": "request",
		"op": op,
		"payload": normalized,
	}
	if not generation.is_empty():
		message["generation"] = generation
	return message


## 构造一个 protocol v1 reply 消息
##
## @param id 与对应 request 的 id 相同
## @param ok 是否成功
## @param result 成功时携带的业务字段（可选）
## @param error 失败时携带的错误消息字符串（可选）
## @param code 失败时的稳定错误码（可选）
## @return 完整消息字典
static func reply(
	id: int,
	ok: bool,
	result: Variant = null,
	error: String = "",
	code: String = "",
	generation: String = ""
) -> Dictionary:
	var message: Dictionary = {
		"version": VERSION,
		"id": int(id),
		"kind": "reply",
		"ok": ok,
	}
	if ok:
		if result != null:
			message["result"] = result
	else:
		message["error"] = error
		if code != "":
			message["code"] = code
	if not generation.is_empty():
		message["generation"] = generation
	return message


## 构造一个 protocol v1 event 消息（服务端主动推送，无需应答）
##
## @param id 用于追溯来源；可以为空字符串但推荐填一个正整数
## @param event 事件名，如 "log" 或 "frame"
## @param result 事件字段字典
## @return 完整消息字典
static func event(id: int, event: String, result: Dictionary) -> Dictionary:
	return {
		"version": VERSION,
		"id": int(id),
		"kind": "event",
		"event": event,
		"result": result,
	}


## 校验任意消息是否满足 protocol v1 schema
##
## 返回 {"ok":true} 时表示消息合法，可继续处理；
## 否则返回 {"ok":false,"code":..., "error":...}。
## 所有检查是"快速失败"——遇到第一个错误立即返回，不收集多个。
##
## @param value 任意 Variant（通常是 JSON 解析出来的字典）
## @return 校验结果字典
static func validate_message(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return _error("invalid_param", "runtime message must be an object")

	var dict: Dictionary = value

	if int(dict.get("version", -1)) != VERSION:
		return _error("not_supported", "runtime protocol version is unsupported")

	var raw_id: Variant = dict.get("id", null)
	if typeof(raw_id) != TYPE_INT:
		return _error("invalid_param", "runtime message id must be an integer")
	var id_int: int = int(raw_id)

	var kind: String = String(dict.get("kind", ""))
	if kind != "request" and kind != "reply" and kind != "event":
		return _error("invalid_param", "runtime message kind is invalid")
	var generation: Variant = dict.get("generation", null)
	if generation != null and typeof(generation) != TYPE_STRING:
		return _error("invalid_param", "runtime message generation must be a string")
	if kind != "event" and id_int < 1:
		return _error("invalid_param", "runtime message id must be a positive integer")
	if kind == "event" and id_int < 0:
		return _error("invalid_param", "runtime event id must not be negative")

	if kind == "request":
		var op: String = String(dict.get("op", ""))
		if op.is_empty():
			return _error("invalid_param", "runtime request op is required")
		if DENIED_OPS.has(op):
			return _error("permission_denied", "operation is unavailable in runtime protocol v1")

	var payload: Variant = dict.get("payload", null)
	if typeof(payload) != TYPE_DICTIONARY and payload != null:
		return _error("invalid_param", "runtime message payload must be an object when present")

	# 体积检查放在最后，避免在大 payload 上做无效的类型校验开销
	if message_size_bytes(dict) > MAX_MESSAGE_BYTES:
		return _error("invalid_param", "runtime message exceeds 4 MiB")

	return {"ok": true}


## Return the exact UTF-8 wire size used by the protocol bound.
static func message_size_bytes(value: Variant) -> int:
	return JSON.stringify(value).to_utf8_buffer().size()


## Return true only when the serialized value exceeds the protocol limit.
static func message_exceeds_limit(value: Variant) -> bool:
	return message_size_bytes(value) > MAX_MESSAGE_BYTES


## Route-side request validation uses the same protocol envelope as broker/probe.
static func validate_request(op: String, payload: Dictionary) -> Dictionary:
	return validate_message(request(1, op, payload))


## 判断一个 op 是否被当前协议拒绝（仅在 validate_message 内部使用，
## 但暴露给 runtime_probe 等需要主动跳过的场景）
##
## @param op op 名字符串
## @return true 表示 op 在协议 v1 中不可用
static func is_denied_op(op: String) -> bool:
	return DENIED_OPS.has(op)


## 内部用错误构造器
static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
