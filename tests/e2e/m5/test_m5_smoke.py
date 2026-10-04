from e2e.route_manifests import M5_ROUTES

from .conftest import command_doc, exec_error, exec_ok


def test_m5_route_families_are_registered(m5_editor):
    routes = set(exec_ok(m5_editor, "gdapi/routes")["routes"])
    assert M5_ROUTES <= routes
    for route in sorted(M5_ROUTES):
        doc = command_doc(m5_editor, route)
        assert doc["summary"] and doc["returns"]["fields"]


def test_m5_queries_uid_apply_and_safety_contracts(m5_editor):
    assert exec_ok(m5_editor, "classdb/class", {"class": "Node2D"})["parent"] == "CanvasItem"
    assert exec_ok(m5_editor, "diagnostics/cycle_deps", {"roots": ["res://fixtures"]})["items"]
    assert exec_ok(m5_editor, "diagnostics/script_errors", {"roots": ["res://fixtures"]})["items"]
    assert exec_ok(m5_editor, "export/presets")["presets"]
    assert exec_ok(m5_editor, "uid/repair", {"roots": ["res://fixtures"], "dry_run": False})["ok"] is True
