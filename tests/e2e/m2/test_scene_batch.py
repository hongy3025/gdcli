"""Real disk transactions across unopened scenes; no second editor fixture."""

from __future__ import annotations

import copy
import hashlib
import os
import stat
from pathlib import Path

import pytest

from .helpers import exec_error, exec_ok

ROOT = "res://scene_batch"
SCENES = [ROOT + "/a.tscn", ROOT + "/nested/b.tscn"]
NAMES = ["BatchA", "BatchB"]


def request(**extra):
    return {
        "scenes": SCENES,
        "selector": {"class": "Node2D", "name": "Target", "node_path": "Target"},
        "operations": [{"op": "set_property", "property": "position", "value": {"type": "Vector2", "value": [90, 80]}}],
        **extra,
    }


def disk(env, scene):
    return Path(env["project"]) / scene.removeprefix("res://")


def contents(env):
    return [disk(env, scene).read_bytes() for scene in SCENES]


def planned(env, body):
    plan = exec_ok(env, "scene/batch/plan", body)
    return {**body, "plan_hash": plan["plan_hash"]}, plan


def apply(env, body=None):
    body, plan = planned(env, body or request())
    assert exec_ok(env, "scene/batch/validate", body)["validated"] is True
    result = exec_ok(env, "scene/batch/apply", body)
    assert result["changed"] is True
    assert result["files"] == len(SCENES)
    return result, plan


def read_open(env, scene, root, relative, property):
    exec_ok(env, "scene/open", {"path": scene})
    try:
        return exec_ok(env, "node/property/get", {"node_path": f"/root/{root}/{relative}", "property": property})["value"]
    finally:
        exec_ok(env, "scene/close", {"path": scene})


def test_two_unopened_scenes_apply_reload_recover(m2_editor):
    before = contents(m2_editor)
    result, plan = apply(m2_editor)
    assert [op["previous"] for op in plan["operations"]] == [
        {"type": "Vector2", "value": [1.0, 2.0]},
        {"type": "Vector2", "value": [5.0, 6.0]},
    ]
    assert {scene["path"]: scene["sha256"] for scene in plan["scenes"]} == {
        scene: hashlib.sha256(content).hexdigest() for scene, content in zip(SCENES, before)
    }
    probe = request(operations=[{"property": "rotation", "value": 0.75}])
    reloaded = exec_ok(m2_editor, "scene/batch/plan", probe)
    assert {scene["path"]: scene["uid"] for scene in reloaded["scenes"]} == {scene["path"]: scene["uid"] for scene in plan["scenes"]}
    assert all(scene["uid"] for scene in plan["scenes"])
    for scene, name in zip(SCENES, NAMES):
        assert read_open(m2_editor, scene, name, "Target", "position") == {"type": "Vector2", "value": [90.0, 80.0]}
        assert read_open(m2_editor, scene, name, "Collision", "shape") == {"type": "Resource", "value": ROOT + "/shape.tres"}
    assert read_open(m2_editor, SCENES[0], NAMES[0], "Shared", "position") == {"type": "Vector2", "value": [11.0, 12.0]}
    assert read_open(m2_editor, SCENES[1], NAMES[1], "Shared", "position") == {"type": "Vector2", "value": [21.0, 22.0]}
    recovered = exec_ok(m2_editor, "scene/batch/recover", {"operation_id": result["operation_id"]})
    assert recovered["restored"] == 2
    assert contents(m2_editor) == before
    assert exec_error(m2_editor, "scene/batch/recover", {"operation_id": result["operation_id"]})["code"] == "conflict"


def test_single_scene_multi_property_and_instance_override(m2_editor):
    body = request(scenes=[SCENES[0]], operations=[
        {"property": "position", "value": {"type": "Vector2", "value": [7, 8]}},
        {"property": "rotation", "value": 0.5},
        {"selector": {"node_path": "Shared/Nested"}, "property": "position", "value": {"type": "Vector2", "value": [31, 32]}},
    ])
    before = contents(m2_editor)
    bound, plan = planned(m2_editor, body)
    assert len(plan["operations"]) == 3
    result = exec_ok(m2_editor, "scene/batch/apply", bound)
    assert result["files"] == 1
    assert contents(m2_editor)[1] == before[1]
    assert read_open(m2_editor, SCENES[0], NAMES[0], "Target", "rotation") == pytest.approx(0.5)
    assert read_open(m2_editor, SCENES[0], NAMES[0], "Shared/Nested", "position") == {"type": "Vector2", "value": [31.0, 32.0]}
    # The source instance remains untouched, not flattened/replaced by the override.
    assert read_open(m2_editor, ROOT + "/base.tscn", "Shared", "Nested", "position") == {"type": "Vector2", "value": [3.0, 4.0]}
    references = exec_ok(m2_editor, "scene/project/references", {"scenes": [SCENES[0]]})["items"]
    assert any(row["kind"] == "instance" and row["node_path"] == "Shared" and row["target"] == ROOT + "/base.tscn" for row in references)
    assert any(row["kind"] == "connection" and row["signal"] == "visibility_changed" and row["target"] == "Twin" for row in references)
    exec_ok(m2_editor, "scene/batch/recover", {"operation_id": result["operation_id"]})
    assert contents(m2_editor) == before


@pytest.mark.parametrize("property,value,code", [
    ("position", "wrong-type", "invalid_param"),
    ("position", {"type": "Vector2", "value": [1]}, "invalid_param"),
    ("script", {"type": "Resource", "value": "res://scripts/player.gd"}, "permission_denied"),
    ("script/source_code", "extends Node", "permission_denied"),
    ("owner", None, "permission_denied"),
    ("not_a_property", 1, "not_found"),
])
def test_invalid_property_plan_never_changes_disk(m2_editor, property, value, code):
    before = contents(m2_editor)
    body = request(operations=[{"property": property, "value": value}])
    assert exec_error(m2_editor, "scene/batch/plan", body)["code"] == code
    assert contents(m2_editor) == before


def test_plan_hash_binds_parameters_external_edits_and_dependencies(m2_editor):
    bound, _ = planned(m2_editor, request())
    before = contents(m2_editor)
    changed = copy.deepcopy(bound)
    changed["operations"][0]["value"]["value"] = [91, 80]
    assert exec_error(m2_editor, "scene/batch/apply", changed)["code"] == "conflict"
    assert contents(m2_editor) == before
    second = disk(m2_editor, SCENES[1])
    second.write_bytes(before[1] + b"\n; external editor change\n")
    external = contents(m2_editor)
    assert exec_error(m2_editor, "scene/batch/validate", bound)["code"] == "conflict"
    assert exec_error(m2_editor, "scene/batch/apply", bound)["code"] == "conflict"
    assert contents(m2_editor) == external
    second.write_bytes(before[1])
    shape = disk(m2_editor, ROOT + "/shape.tres")
    shape.write_text(shape.read_text(encoding="utf-8").replace("12, 18", "13, 18"), encoding="utf-8")
    assert exec_error(m2_editor, "scene/batch/apply", bound)["code"] == "conflict"
    assert contents(m2_editor) == before


@pytest.mark.skipif(os.name != "nt", reason="Windows read-only attribute transaction boundary")
def test_windows_read_only_second_file_prevents_any_write(m2_editor):
    bound, _ = planned(m2_editor, request())
    before = contents(m2_editor)
    second = disk(m2_editor, SCENES[1])
    second.chmod(stat.S_IREAD)
    try:
        assert exec_error(m2_editor, "scene/batch/apply", bound)["code"] == "permission_denied"
        assert contents(m2_editor) == before
    finally:
        second.chmod(stat.S_IREAD | stat.S_IWRITE)


def test_apply_mid_transaction_failure_rolls_back_all_writes(m2_editor):
    bound, _ = planned(m2_editor, request())
    before = contents(m2_editor)
    marker = Path(m2_editor["project"]) / ".gdapi-debug-apply-fail"
    marker.write_text("1", encoding="utf-8")
    try:
        failure = exec_error(m2_editor, "scene/batch/apply", bound)
        assert failure["code"] == "godot_error"
        assert failure["details"]["rollback_failures"] == []
        assert contents(m2_editor) == before
    finally:
        marker.unlink()


def test_recovery_conflict_and_mid_transaction_failure_leave_applied_state(m2_editor):
    before = contents(m2_editor)
    result, _ = apply(m2_editor)
    applied = contents(m2_editor)
    second = disk(m2_editor, SCENES[1])
    second.write_bytes(applied[1] + b"\n; post-apply edit\n")
    conflicting = contents(m2_editor)
    assert exec_error(m2_editor, "scene/batch/recover", {"operation_id": result["operation_id"]})["code"] == "conflict"
    assert contents(m2_editor) == conflicting
    second.write_bytes(applied[1])
    marker = Path(m2_editor["project"]) / ".gdapi-debug-recover-fail"
    marker.write_text("1", encoding="utf-8")
    try:
        failed = exec_error(m2_editor, "scene/batch/recover", {"operation_id": result["operation_id"]})
        assert failed["code"] == "godot_error"
        assert failed["details"]["rollback_failures"] == []
        assert contents(m2_editor) == applied
    finally:
        marker.unlink()
    exec_ok(m2_editor, "scene/batch/recover", {"operation_id": result["operation_id"]})
    assert contents(m2_editor) == before


def test_unsaved_open_scene_is_rejected_without_losing_editor_changes(m2_editor):
    bound, _ = planned(m2_editor, request())
    before = contents(m2_editor)
    exec_ok(m2_editor, "scene/open", {"path": SCENES[1]})
    try:
        exec_ok(m2_editor, "node/property/set", {"node_path": "/root/BatchB/Target", "property": "position", "value": {"type": "Vector2", "value": [123, 456]}})
        assert exec_error(m2_editor, "scene/batch/apply", bound)["code"] == "conflict"
        assert contents(m2_editor) == before
        assert exec_ok(m2_editor, "node/property/get", {"node_path": "/root/BatchB/Target", "property": "position"})["value"] == {"type": "Vector2", "value": [123.0, 456.0]}
        # Restore the editor value before closing, so no modal save prompt is needed.
        exec_ok(m2_editor, "node/property/set", {"node_path": "/root/BatchB/Target", "property": "position", "value": {"type": "Vector2", "value": [5, 6]}})
        exec_ok(m2_editor, "scene/current/save")
    finally:
        exec_ok(m2_editor, "scene/close", {"path": SCENES[1]})


def test_project_scan_reports_real_nodepath_connection_instance_dependencies(m2_editor):
    nodes = exec_ok(m2_editor, "scene/project/find_nodes", {"root": ROOT, "class": "RemoteTransform2D"})["items"]
    assert {(row["path"], row["node_path"], row["class"]) for row in nodes} == {(scene, "Reference", "RemoteTransform2D") for scene in SCENES}
    references = exec_ok(m2_editor, "scene/project/references", {"root": ROOT, "node_path": "Target"})["items"]
    assert {(row["path"], row["property"], row["value"], row["target"]) for row in references if row["kind"] == "property"} == {(scene, "remote_path", "../Target", "Target") for scene in SCENES}
    assert any(row["kind"] == "connection" and row["node_path"] == "Target" and row["target"] == "Twin" for row in references)
    dependencies = exec_ok(m2_editor, "scene/project/dependencies", {"scenes": SCENES})["items"]
    assert {(row["path"], row["dependency"]) for row in dependencies} == {(scene, ROOT + suffix) for scene in SCENES for suffix in ["/base.tscn", "/shape.tres"]}
    assert all(row["sha256"] == hashlib.sha256(disk(m2_editor, row["dependency"]).read_bytes()).hexdigest() for row in dependencies)
    protected = request()
    protected.pop("scenes")
    protected["root"] = "res://addons/gdapi"
    assert exec_error(m2_editor, "scene/batch/plan", protected)["code"] == "permission_denied"


def test_binary_scene_scans_mutates_and_recovers(m2_editor):
    binary = ROOT + "/binary.scn"
    exec_ok(m2_editor, "scene/save", {"scene_path": SCENES[0], "new_path": binary})
    before = disk(m2_editor, binary).read_bytes()
    body, _ = planned(m2_editor, request(scenes=[binary]))
    result = exec_ok(m2_editor, "scene/batch/apply", body)
    assert result["files"] == 1
    nodes = exec_ok(m2_editor, "scene/project/find_nodes", {"root": ROOT, "selector": {"name": "Target"}})["items"]
    assert binary in {row["path"] for row in nodes}
    assert read_open(m2_editor, binary, "BatchA", "Target", "position") == {"type": "Vector2", "value": [90.0, 80.0]}
    exec_ok(m2_editor, "scene/batch/recover", {"operation_id": result["operation_id"]})
    assert disk(m2_editor, binary).read_bytes() == before


def test_recovery_backup_corruption_does_not_restore_first_scene(m2_editor):
    result, _ = apply(m2_editor)
    after = contents(m2_editor)
    stage = Path(m2_editor["project"]) / ".godot" / "gdapi-scene-batch" / result["operation_id"]
    backup = stage / "backup-1.tscn"
    saved = backup.read_bytes()
    backup.write_bytes(saved + b"\n; corrupt backup\n")
    try:
        assert exec_error(m2_editor, "scene/batch/recover", {"operation_id": result["operation_id"]})["code"] == "conflict"
        assert contents(m2_editor) == after
    finally:
        backup.write_bytes(saved)
    exec_ok(m2_editor, "scene/batch/recover", {"operation_id": result["operation_id"]})


def test_scan_excludes_generated_subdirectories(m2_editor):
    generated = disk(m2_editor, ROOT + "/.generated")
    generated.mkdir()
    # A corrupt generated scene must never be loaded or reported as a match.
    (generated / "broken.tscn").write_text("not a PackedScene", encoding="utf-8")
    rows = exec_ok(m2_editor, "scene/project/find_nodes", {"root": ROOT, "selector": {"name": "Target"}})
    assert {row["path"] for row in rows["items"]} == set(SCENES)
    assert any(ROOT + "/.generated" in warning for warning in rows["warnings"])


def test_target_resource_hash_and_resource_replacement_recovery(m2_editor):
    target = ROOT + "/alternate_shape.tres"
    target_file = disk(m2_editor, target)
    target_file.write_text('[gd_resource type="CircleShape2D" format=3]\n\n[resource]\nradius = 19.0\n', encoding="utf-8")
    before = contents(m2_editor)
    body = request(selector={"node_path": "Collision"}, operations=[{"property": "shape", "value": {"type": "Resource", "value": target}}])
    bound, _ = planned(m2_editor, body)
    target_file.write_text('[gd_resource type="CircleShape2D" format=3]\n\n[resource]\nradius = 20.0\n', encoding="utf-8")
    assert exec_error(m2_editor, "scene/batch/apply", bound)["code"] == "conflict"
    assert contents(m2_editor) == before
    rebound, _ = planned(m2_editor, body)
    result = exec_ok(m2_editor, "scene/batch/apply", rebound)
    for scene, name in zip(SCENES, NAMES):
        assert read_open(m2_editor, scene, name, "Collision", "shape") == {"type": "Resource", "value": target}
    exec_ok(m2_editor, "scene/batch/recover", {"operation_id": result["operation_id"]})
    assert contents(m2_editor) == before
