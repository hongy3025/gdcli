@tool
extends SceneTree

const Transport := preload("res://addons/gdapi/runtime/runtime_transport_file_probe.gd")

var passed := 0
var failed := 0

func _init() -> void:
	print("Running GdApiRuntimeTransportFileProbe tests...")

	test_probe_id_is_unique_hex()
	test_root_dir_under_dot_godot()
	test_start_writes_hello_file()
	test_inbox_request_triggers_callback()

	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	if failed > 0:
		quit(1)
	else:
		quit(0)

func assert_eq(actual, expected, context: String = "") -> void:
	if actual == expected:
		passed += 1
		print("  PASS: %s" % context)
	else:
		failed += 1
		print("  FAIL: %s - expected '%s', got '%s'" % [context, expected, actual])

func assert_true(value: bool, context: String = "") -> void:
	assert_eq(value, true, context)

func _make_root() -> String:
	return ProjectSettings.globalize_path("res://.godot/gdapi_runtime_test")

func _cleanup(root: String) -> void:
	var dir := DirAccess.open(root)
	if dir == null:
		return
	for name in dir.get_files():
		dir.remove(name)
	for sub in dir.get_directories():
		var sub_dir := DirAccess.open(root.path_join(sub))
		if sub_dir != null:
			for n in sub_dir.get_files():
				sub_dir.remove(n)
			sub_dir.remove(sub)
	DirAccess.remove_absolute(root)

func test_probe_id_is_unique_hex() -> void:
	var a := Transport.new()
	var b := Transport.new()
	var ida := a.probe_id()
	var idb := b.probe_id()
	assert_eq(ida.length(), 8, "probe id length 8")
	assert_eq(idb.length(), 8, "probe id length 8")
	assert_true(ida != idb, "probe ids are unique")

func test_root_dir_under_dot_godot() -> void:
	var t := Transport.new()
	var root := t.root_path()
	assert_true(root.ends_with(".godot/gdapi_runtime") or root.contains("/.godot/gdapi_runtime"),
		"root under .godot/gdapi_runtime, got %s" % root)

func test_start_writes_hello_file() -> void:
	var root := _make_root()
	var t := Transport.new(0, root)
	t.start()
	var hello_path := root.path_join(t.probe_id()).path_join("hello.json")
	assert_true(FileAccess.file_exists(hello_path), "hello.json written")
	var f := FileAccess.open(hello_path, FileAccess.READ)
	var content := f.get_as_text()
	f.close()
	assert_true(content.contains("\"event\":\"hello\""), "hello event payload")
	assert_true(content.contains("\"protocol_version\":1"), "protocol_version present")
	t.stop()
	_cleanup(root)

func test_inbox_request_triggers_callback() -> void:
	var root := _make_root()
	var t := Transport.new(0, root)
	var received: Array = []
	t.set_request_handler(func(msg: Dictionary) -> Dictionary:
		received.append(msg)
		return {"ok": true, "result": {"echo": msg.get("id", -1)}}
	)
	t.start()
	# 模拟编辑器写 inbox 请求
	var probe_dir := root.path_join(t.probe_id())
	DirAccess.make_dir_recursive_absolute(probe_dir.path_join("inbox"))
	var req_path := probe_dir.path_join("inbox").path_join("42.json")
	var rf := FileAccess.open(req_path, FileAccess.WRITE)
	rf.store_string(JSON.stringify({
		"version": 1, "id": 42, "kind": "request",
		"op": "runtime/status", "payload": {}
	}))
	rf.close()
	# 推进 tick
	t.tick(Time.get_ticks_msec())
	# 验证回调被调用 + reply 落盘
	assert_eq(received.size(), 1, "request handler invoked once")
	var out_path := probe_dir.path_join("outbox").path_join("42.json")
	assert_true(FileAccess.file_exists(out_path), "outbox reply written")
	t.stop()
	_cleanup(root)
