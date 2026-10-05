@tool
extends RefCounted

const GdApiPlugin := preload("res://addons/gdapi/plugin.gd")
const AUDIT_CAPACITY := 1000

var passed := 0
var failed := 0


func run(_tree: SceneTree) -> Dictionary:
	test_protected_entries_survive_normal_traffic()
	test_all_protected_buffer_evicts_oldest_entry()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	return {"ok": failed == 0, "passed": passed, "failed": failed}


func test_protected_entries_survive_normal_traffic() -> void:
	var plugin = GdApiPlugin.new()
	plugin.audit_event({"route": "protected-dangerous", "safety": "dangerous", "ok": false})
	plugin.audit_event({"route": "protected-file", "safety": "file", "ok": false})
	for index in 1100:
		(
			plugin
			. audit_event(
				{
					"route": "ordinary",
					"safety": "mutation",
					"ok": false,
					"index": index,
				}
			)
		)

	var entries: Array = plugin.get_audit_since(0, AUDIT_CAPACITY)
	assert_eq(entries.size(), AUDIT_CAPACITY, "normal traffic retains exactly capacity")
	assert_eq(entries[0].route, "protected-dangerous", "dangerous entry remains retained")
	assert_eq(entries[1].route, "protected-file", "file entry remains retained")
	assert_eq(
		entries.filter(func(entry: Dictionary) -> bool: return entry.safety == "mutation").size(),
		AUDIT_CAPACITY - 2,
		"oldest ordinary entries are evicted",
	)
	var sequences: Array = entries.map(func(entry: Dictionary) -> int: return entry.seq)
	var sorted_sequences := sequences.duplicate()
	sorted_sequences.sort()
	assert_eq(sequences, sorted_sequences, "retained sequence order remains increasing")
	assert_eq(entries.back().seq, 1102, "newest sequence is preserved")
	plugin.free()


func test_all_protected_buffer_evicts_oldest_entry() -> void:
	var plugin = GdApiPlugin.new()
	for index in AUDIT_CAPACITY + 1:
		(
			plugin
			. audit_event(
				{
					"route": "protected",
					"safety": "dangerous",
					"ok": false,
					"index": index,
				}
			)
		)

	var entries: Array = plugin.get_audit_since(0, AUDIT_CAPACITY)
	assert_eq(entries.size(), AUDIT_CAPACITY, "protected traffic retains exactly capacity")
	assert_eq(entries[0].seq, 2, "oldest protected entry is evicted")
	assert_eq(entries.back().seq, AUDIT_CAPACITY + 1, "newest protected entry is retained")
	assert_eq(
		entries.filter(func(entry: Dictionary) -> bool: return entry.safety == "dangerous").size(),
		AUDIT_CAPACITY,
		"all retained entries remain protected",
	)
	assert_eq(
		entries.filter(func(entry: Dictionary) -> bool: return entry.ok == false).size(),
		AUDIT_CAPACITY,
		"all retained protected failures remain unsuccessful",
	)
	plugin.free()


func assert_eq(actual, expected, context: String) -> void:
	if actual == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s expected=%s actual=%s" % [context, expected, actual])
