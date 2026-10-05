from pathlib import Path
import shutil
from uuid import uuid4

import pytest

from .conftest import exec_error, exec_ok


ROOT = "res://analysis"
SCENE = ROOT + "/deep.tscn"
FLOW = ROOT + "/flow.gd"


def analyze(env, kind, **body):
    return exec_ok(env, "diagnostics/" + kind, {"roots": [ROOT], "limit": 500, **body})


def source_line(env, path, snippet):
    lines = (Path(env["project"]) / path.removeprefix("res://")).read_text(
        encoding="utf-8"
    ).splitlines()
    return next(i for i, line in enumerate(lines, 1) if snippet in line)


def test_scene_metrics_include_real_depth_instances_and_inheritance(m5_editor):
    result = analyze(m5_editor, "scene_complexity", thresholds={"node_count": 4, "max_depth": 3})
    scenes = {item["path"]: item for item in result["items"]}
    deep = scenes[SCENE]
    assert deep["node_count"] == 5
    assert deep["max_depth"] == 4
    assert deep["type_counts"] == {"Node": 2, "Node2D": 1, "Timer": 1, "Marker2D": 1}
    assert deep["script_count"] == 2
    assert deep["connection_count"] == 1
    assert set(deep["resource_references"]) == {
        ROOT + "/base.gd", FLOW, ROOT + "/data.tres",
    }
    assert deep["resource_reference_count"] == 3
    assert deep["within_thresholds"] is False
    assert deep["exceeded"] == [
        {"metric": "node_count", "actual": 5, "threshold": 4},
        {"metric": "max_depth", "actual": 4, "threshold": 3},
    ]
    assert scenes[ROOT + "/instance.tscn"]["node_count"] == 6
    assert scenes[ROOT + "/instance.tscn"]["max_depth"] == 5
    assert scenes[ROOT + "/instance.tscn"]["connection_count"] == 1
    assert scenes[ROOT + "/inherited.tscn"]["node_count"] == 6
    assert scenes[ROOT + "/inherited.tscn"]["max_depth"] == 4
    selected = analyze(m5_editor, "scene_complexity", path=SCENE, thresholds={"node_count": 5})
    assert selected["total"] == 1
    assert selected["items"][0]["within_thresholds"] is True


def test_signal_flow_has_real_endpoints_and_explicit_dynamic_unknowns(m5_editor):
    result = analyze(m5_editor, "signal_flow", path=SCENE)
    assert result["runtime_complete"] is False
    serialized = [item for item in result["items"] if item["kind"] == "scene_connection"]
    assert len(serialized) == 1
    edge = serialized[0]
    assert (edge["source"], edge["signal"], edge["target"], edge["method"], edge["scene"]) == (
        ".", "pulse", ".", "_on_pulse", SCENE,
    )
    assert edge["status"] == "resolved"
    assert {(item["path"], item["target"]) for item in result["signals"]} == {(FLOW, "pulse")}
    connects = [item for item in result["items"] if item["kind"] == "connect"]
    resolved = [item for item in connects if item["status"] == "resolved"]
    assert [(item["source"], item["target"], item["method"], item["scene"]) for item in resolved] == [
        (".", ".", "_on_pulse", SCENE),
    ]
    assert sum(item["status"] == "unknown" for item in connects) == 1
    emits = [item for item in result["items"] if item["kind"] == "emit"]
    assert [item["signal"] for item in emits if item["status"] == "resolved"] == ["pulse", "pulse"]
    assert sum(item["status"] == "unknown" for item in emits) == 1
    assert result["unknown_count"] == 2
    assert all(item["reason"] for item in result["items"] if item["status"] == "unknown")


def test_script_references_preserve_locations_and_ignore_comment_string_code(m5_editor):
    result = analyze(m5_editor, "script_references", path=SCENE)
    assert result["runtime_complete"] is False
    refs = result["items"]
    resource_refs = [item for item in refs if item["kind"] in {"load", "preload"}]
    assert [(item["kind"], item["target"], item["status"]) for item in resource_refs] == [
        ("preload", ROOT + "/data.tres", "resolved"),
        ("load", ROOT + "/base.gd", "resolved"),
        ("load", "", "unknown"),
    ]
    for item in resource_refs:
        assert item["path"] == FLOW
        snippet = {
            ("preload", "resolved"): "const DATA = preload",
            ("load", "resolved"): "var loaded = load",
            ("load", "unknown"): "var computed = load",
        }[item["kind"], item["status"]]
        assert item["line"] == source_line(m5_editor, FLOW, snippet)
    assert any(item["kind"] == "extends" and item["target"] == ROOT + "/base.gd" for item in refs)
    assert any(item["kind"] == "class_name" and item["target"] == "AnalysisFixtureFlow" for item in refs)
    calls = [item for item in refs if item["kind"] == "function_reference"]
    assert any(item["target"] == "_on_pulse" and item["status"] == "resolved" for item in calls)
    assert any(item["target"] == "base_method" and item["status"] == "unknown" for item in calls)
    attachments = [item for item in refs if item["kind"] == "scene_script"]
    assert {(item["source"], item["target"]) for item in attachments} == {
        (".", FLOW), ("Branch/Leaf", ROOT + "/base.gd"),
    }
    assert all(item["path"] == SCENE and item["line"] > 0 for item in attachments)
    assert not any("only.tres" in item["target"] or item.get("signal") == "fake_signal" for item in refs)


def test_analysis_recomputes_after_removing_reference_and_adding_node(m5_editor):
    project = Path(m5_editor["project"])
    relative = "analysis_cases/" + uuid4().hex
    work = project / relative
    work.mkdir(parents=True)
    script = work / "flow.gd"
    scene = work / "deep.tscn"
    script_path = "res://" + relative + "/flow.gd"
    scene_path = "res://" + relative + "/deep.tscn"
    script_source = (project / "analysis/flow.gd").read_text(encoding="utf-8").replace(
        "class_name AnalysisFixtureFlow\n", "",
    )
    scene_source = (project / "analysis/deep.tscn").read_text(encoding="utf-8").replace(
        FLOW, script_path,
    )
    try:
        script.write_text(script_source, encoding="utf-8")
        scene.write_text(scene_source, encoding="utf-8")
        before = analyze(m5_editor, "scene_complexity", path=scene_path)["items"][0]
        refs_before = analyze(m5_editor, "script_references", path=script_path)["items"]
        assert any(item["kind"] == "preload" for item in refs_before)
        script.write_text(script_source.replace(
            'const DATA = preload("res://analysis/data.tres")', 'const DATA = null',
        ), encoding="utf-8")
        refs = analyze(m5_editor, "script_references", path=script_path)["items"]
        assert not any(item["kind"] == "preload" for item in refs)
        scene.write_text(scene_source + '\n[node name="Deeper" type="Node" parent="Branch/Leaf/Timer/Tip"]\n', encoding="utf-8")
        metrics = analyze(m5_editor, "scene_complexity", path=scene_path)["items"][0]
        assert metrics["node_count"] == before["node_count"] + 1
        assert metrics["max_depth"] == before["max_depth"] + 1
        assert metrics["type_counts"]["Node"] == before["type_counts"]["Node"] + 1
        connection = '[connection signal="pulse" from="." to="." method="_on_pulse"]'
        scene.write_text(scene_source.replace(connection, ""), encoding="utf-8")
        metrics = analyze(m5_editor, "scene_complexity", path=scene_path)["items"][0]
        assert metrics["connection_count"] == before["connection_count"] - 1
        flow = analyze(m5_editor, "signal_flow", path=scene_path)
        assert not any(item["kind"] == "scene_connection" for item in flow["items"])
    finally:
        shutil.rmtree(work)


def test_project_statistics_use_source_bytes_and_loader_types(m5_editor):
    result = analyze(m5_editor, "project_statistics", roots=[ROOT, SCENE])
    paths = [path for path in (Path(m5_editor["project"]) / "analysis").iterdir()
             if path.suffix in {".gd", ".tres", ".tscn"}]
    assert result["file_count"] == len(paths) == 6
    assert result["bytes"] == sum(path.stat().st_size for path in paths)
    assert result["script_count"] == 2
    assert result["scene_count"] == 3
    assert result["resource_count"] == 6
    assert result["type_counts"] == {"GDScript": 2, "Resource": 1, "PackedScene": 3}
    assert result["extension_counts"] == {"gd": 2, "tres": 1, "tscn": 3}
    protected = analyze(m5_editor, "project_statistics", path="res://addons")
    assert protected["file_count"] == 0
    included = analyze(m5_editor, "project_statistics", path="res://addons", include_addons=True)
    assert included["script_count"] > 0
    assert included["bytes"] > 0
    generated = analyze(m5_editor, "project_statistics", path="res://.godot")
    assert generated["file_count"] == 0


@pytest.mark.parametrize("kind", ["signal_flow", "scene_complexity", "script_references", "project_statistics"])
def test_analysis_propagates_path_and_input_errors(m5_editor, kind):
    route = "diagnostics/" + kind
    assert exec_error(m5_editor, route, {"roots": ["../../escape"]})["code"] == "invalid_path"
    assert exec_error(m5_editor, route, {"roots": [ROOT + "/missing"]})["code"] == "not_found"
    assert exec_error(m5_editor, route, {"roots": "not-an-array"})["code"] == "invalid_param"
    assert exec_error(m5_editor, route, {"include_addons": "yes"})["code"] == "invalid_param"


def test_complexity_rejects_invalid_thresholds(m5_editor):
    for thresholds in [{"node_count": -1}, {"node_count": "large"}, {"invented": 1}, []]:
        assert exec_error(m5_editor, "diagnostics/scene_complexity", {
            "path": SCENE, "thresholds": thresholds,
        })["code"] == "invalid_param"
