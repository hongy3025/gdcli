from .conftest import exec_error, exec_ok


def test_classdb_queries_are_sorted_filtered_and_paginated(m5_editor):
    result = exec_ok(m5_editor, "classdb/classes", {
        "filter": "Node", "offset": 0, "limit": 5,
    })
    assert result["items"] == sorted(result["items"])
    assert len(result["items"]) == 5
    assert exec_ok(m5_editor, "classdb/class", {"class": "Node2D"})["parent"] == "CanvasItem"
    methods = exec_ok(m5_editor, "classdb/methods", {
        "class": "Node2D", "filter": "get_", "limit": 10,
    })["items"]
    assert methods == sorted(methods, key=lambda item: item["name"])
    assert all("get_" in item["name"] for item in methods)



def test_classdb_member_routes_preserve_not_found(m5_editor):
    for route in ("methods", "properties", "signals", "inheriters"):
        error = exec_error(m5_editor, f"classdb/{route}", {"class": "DefinitelyMissingClass"})
        assert error["code"] == "not_found"