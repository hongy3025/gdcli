## GdApiRuntimeRingBuffer 单元测试
##
## 测试有界 ring buffer 的 wraparound、cursor 单调递增、dropped count 等。

@tool
extends SceneTree

const RingBuffer := preload("res://addons/gdapi/runtime/runtime_ring_buffer.gd")

var passed := 0
var failed := 0

func _init() -> void:
	print("Running GdApiRuntimeRingBuffer tests...\n")

	test_init_default_capacity()
	test_append_assigns_unique_cursors()
	test_empty_read()
	test_empty_read_preserves_ahead_cursor()
	test_wraparound_drops_oldest()
	test_eviction_reports_exact_dropped_count()
	test_partial_eviction_reports_exact_dropped_count()
	test_cursor_does_not_repeat()
	test_two_pages_do_not_repeat_entries()
	test_limit_caps_results()
	test_clear_resets_state()

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

func test_init_default_capacity() -> void:
	var buf := RingBuffer.new()
	assert_eq(buf.capacity, 2000, "default capacity 2000")
	assert_eq(buf.size(), 0, "size 0")

func test_append_assigns_unique_cursors() -> void:
	var buf := RingBuffer.new(10)
	var c1 := buf.append("info", "first")
	var c2 := buf.append("info", "second")
	assert_eq(c1, 1, "first cursor")
	assert_eq(c2, 2, "second cursor")

func test_empty_read() -> void:
	var buf := RingBuffer.new(3)
	var page := buf.read(0, 10)
	assert_eq(page.items, [], "empty read has no items")
	assert_eq(page.next_cursor, 0, "empty read cursor remains zero")
	assert_eq(page.dropped, 0, "empty read reports no dropped entries")

func test_empty_read_preserves_ahead_cursor() -> void:
	var buf := RingBuffer.new(3)
	var page := buf.read(41, 10)
	assert_eq(page.items, [], "ahead cursor read has no items")
	assert_eq(page.next_cursor, 41, "ahead cursor remains stable on empty read")
	assert_eq(page.dropped, 0, "ahead cursor read reports no dropped entries")

func test_wraparound_drops_oldest() -> void:
	var buf := RingBuffer.new(3)
	for value in ["a", "b", "c", "d"]:
		buf.append("info", value)
	var page := buf.read(0, 10)
	var messages: Array = []
	for item in page.items:
		messages.append(item.message)
	# After 4 appends with capacity 3, oldest dropped; only b/c/d remain
	assert_eq(messages, ["b", "c", "d"], "wraparound window")

func test_eviction_reports_exact_dropped_count() -> void:
	var buf := RingBuffer.new(3)
	for value in ["a", "b", "c", "d", "e"]:
		buf.append("info", value)
	var page := buf.read(0, 10)
	assert_eq(page.dropped, 2, "cursor zero reports two evicted entries")

func test_partial_eviction_reports_exact_dropped_count() -> void:
	var buf := RingBuffer.new(3)
	for value in ["a", "b", "c", "d", "e"]:
		buf.append("info", value)
	var page := buf.read(1, 10)
	assert_eq(page.dropped, 1, "cursor one reports one unseen evicted entry")
	var caught_up := buf.read(2, 10)
	assert_eq(caught_up.dropped, 0, "cursor before oldest retained entry has no gap")

func test_cursor_does_not_repeat() -> void:
	var buf := RingBuffer.new(3)
	for v in ["a", "b", "c", "d"]:
		buf.append("info", v)
	var first := buf.read(0, 2)
	assert_eq(first.next_cursor, 3, "after first read next_cursor=3 (b.c)")
	var second := buf.read(first.next_cursor, 2)
	assert_eq(second.items.size(), 1, "second read one item (d)")
	assert_eq(second.next_cursor, 4, "after second next_cursor=4")

func test_two_pages_do_not_repeat_entries() -> void:
	var buf := RingBuffer.new(10)
	for value in ["a", "b", "c"]:
		buf.append("info", value)
	var first := buf.read(0, 2)
	var second := buf.read(first.next_cursor, 2)
	assert_eq(first.items.map(func(item): return item.cursor), [1, 2], "first page cursors")
	assert_eq(second.items.map(func(item): return item.cursor), [3], "second page excludes first page")

func test_limit_caps_results() -> void:
	var buf := RingBuffer.new(10)
	for i in range(5):
		buf.append("info", str(i))
	var page := buf.read(0, 2)
	assert_eq(page.items.size(), 2, "limit 2")
	assert_eq(page.items[0].message, "0", "first item")

func test_clear_resets_state() -> void:
	var buf := RingBuffer.new(3)
	for v in ["a", "b"]:
		buf.append("info", v)
	var info := buf.clear()
	assert_eq(info.cleared, 2, "two cleared")
	var page := buf.read(0, 10)
	assert_eq(page.items.size(), 0, "empty after clear")
	assert_eq(page.next_cursor, 0, "clear resets cursor")
	assert_eq(page.dropped, 0, "clear resets dropped count")
