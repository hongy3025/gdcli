from .conftest import command_doc, exec_error, exec_ok


def test_m5_route_families_are_registered(m5_editor):
    routes = set(exec_ok(m5_editor, "gdapi/routes")["routes"])
    expected = {
        "project/settings/get", "project/settings/set", "project/settings/list", "project/settings/reset",
        "project/input_map/list", "project/input_map/action/add", "project/input_map/action/remove",
        "project/input_map/bind", "project/input_map/unbind", "project/autoload/list",
        "project/autoload/add", "project/autoload/remove", "classdb/classes", "classdb/class",
        "classdb/methods", "classdb/properties", "classdb/signals", "classdb/inheriters", "uid/repair",
        "diagnostics/health", "diagnostics/unused_resources", "diagnostics/cycle_deps", "diagnostics/script_errors",
        "export/presets", "export/run", "export/android/devices", "export/android/deploy",
    }
    assert expected <= routes
    for route in sorted(expected):
        doc = command_doc(m5_editor, route)
        assert doc["summary"] and doc["returns"]["fields"]


def test_m5_read_only_queries_and_safety_contracts(m5_editor):
    assert exec_ok(m5_editor, "classdb/class", {"class": "Node2D"})["parent"] == "CanvasItem"
    assert exec_ok(m5_editor, "diagnostics/cycle_deps", {"roots": ["res://fixtures"]})["items"]
    assert exec_ok(m5_editor, "diagnostics/script_errors", {"roots": ["res://fixtures"]})["items"]
    assert exec_ok(m5_editor, "export/presets")["presets"]
    assert exec_error(m5_editor, "uid/repair", {"roots": ["res://fixtures"], "dry_run": False})["code"] == "unsafe_operation"
    assert exec_error(m5_editor, "export/android/deploy", {"serial": "bad", "force": False})["code"] == "unsafe_operation"
