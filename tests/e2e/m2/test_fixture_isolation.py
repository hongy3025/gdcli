"""Verify that the M2 harness gives every test a private project copy."""

from __future__ import annotations

from .helpers import exec_ok, tree_digest


def test_fixture_is_a_private_copy(m2_editor):
    project = m2_editor["project"]
    source = m2_editor["fixture_root"]
    assert project != source
    marker = project / "generated.txt"
    marker.write_text("private", encoding="utf-8")
    assert not (source / "generated.txt").exists()


def test_editor_starts_with_main_scene(m2_editor):
    result = exec_ok(m2_editor, "scene/current")
    assert result["path"] == "res://scenes/main.tscn"


def test_digests_are_stable_across_runs(m2_editor):
    digest = tree_digest(m2_editor["project"])
    assert len(digest) == 64
    again = tree_digest(m2_editor["project"])
    assert again == digest
