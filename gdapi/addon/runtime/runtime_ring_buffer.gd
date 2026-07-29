## 运行时 ring buffer
##
## 容量有界的日志/错误/事件存储;按 cursor 增量读,不会被重复或漏掉。
## 写入新条目超过容量时,丢弃最早条目,并把 drop 数通过 read() 的
## "dropped" 字段暴露给调用方。

@tool
class_name GdApiRuntimeRingBuffer
extends RefCounted

## 容量,超过则覆盖最早的条目
var capacity: int = 2000

## 当前已分配的下一个 cursor
var _next_cursor: int = 1

## 内部顺序数组:[{cursor:int, level:String, message:String, details:Dictionary, ts:float}]
var _items: Array = []


## 构造器
## @param initial_capacity 容量,默认 2000
func _init(initial_capacity: int = 2000) -> void:
	if initial_capacity > 0:
		capacity = initial_capacity


## 追加一条;返回这条的 cursor
##
## @param level 日志级别 ("info","warn","error")
## @param message 日志消息
## @param details 业务字段,可选
## @return 这条日志的 cursor
func append(level: String, message: String, details: Dictionary = {}) -> int:
	var cursor: int = _next_cursor
	_next_cursor += 1
	(
		_items
		. append(
			{
				"cursor": cursor,
				"level": level,
				"message": message,
				"details": details,
				"ts": Time.get_unix_time_from_system(),
			}
		)
	)
	if _items.size() > capacity:
		var drop: int = _items.size() - capacity
		_items = _items.slice(drop)
	return cursor


## 增量读取
##
## @param after_cursor 上次读取之后的下一个 cursor;0 表示从最开始读
## @param limit 条目上限,内部 clamp 到 [1, 500]
## @return 含 items / next_cursor / dropped
func read(after_cursor: int, limit: int = 100) -> Dictionary:
	var bounded: int = clampi(int(limit), 1, 500)
	var results: Array = []
	if _items.is_empty():
		return {
			"items": results,
			"next_cursor": int(after_cursor),
			"dropped": 0,
		}
	for entry in _items:
		var cursor: int = int(entry.cursor)
		if cursor <= int(after_cursor):
			continue
		results.append(entry.duplicate())
		if results.size() >= bounded:
			break
	var next_cursor: int = int(after_cursor)
	if not results.is_empty():
		next_cursor = int(results[results.size() - 1].cursor)
	var oldest: int = int(_items[0].cursor)
	var dropped: int = maxi(0, oldest - (int(after_cursor) + 1))
	return {
		"items": results,
		"next_cursor": next_cursor,
		"dropped": dropped,
	}


## 清空,返回 cleared / next_cursor
func clear() -> Dictionary:
	var cleared: int = _items.size()
	_items.clear()
	_next_cursor = 1
	return {"cleared": cleared, "next_cursor": 0}


## 当前缓存大小
func size() -> int:
	return _items.size()
