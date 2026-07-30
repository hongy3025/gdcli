from .conftest import exec_ok


def _paths(items):
    return {item["path"] for item in items}


def test_diagnostics_match_m5_fixture_findings(m5_editor):
    unused = exec_ok(m5_editor, "diagnostics/unused_resources", {
        "roots": ["res://fixtures"],
    })
    assert _paths(unused["items"]) == {"res://fixtures/unused.tres"}

    cycles = exec_ok(m5_editor, "diagnostics/cycle_deps", {
        "roots": ["res://fixtures"],
    })
    assert any(set(item["cycle"]) == {
        "res://fixtures/cycle_a.tres", "res://fixtures/cycle_b.tres",
    } for item in cycles["items"])

    errors = exec_ok(m5_editor, "diagnostics/script_errors", {
        "roots": ["res://fixtures"],
    })
    assert _paths(errors["items"]) == {"res://fixtures/broken.gd"}
