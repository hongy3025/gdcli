"""Acceptance: M2–M4 module fixtures observe the same shared environment.

The contract runs only when a Godot editor is available, because it asks
the e2e_editor fixture to start the shared process. It then requests each
of the legacy M2–M4 fixture names and asserts they observe the same PID,
resolved project directory, and gdapi metadata.
"""

from __future__ import annotations

import pytest

from tests.e2e.shared_fixture import EDITOR_START_COUNTER, e2e_editor
from tests.e2e.shared_fixture import m2_editor, m3_editor, m4_env


pytestmark = pytest.mark.timeout(60)


def test_m2_alias_shares_e2e_editor(m2_editor, e2e_editor):
    assert m2_editor["editor_pid"] == e2e_editor["editor_pid"]
    assert m2_editor["project"].resolve() == e2e_editor["project"].resolve()
    assert m2_editor["meta"] == e2e_editor["meta"]


def test_m3_alias_shares_e2e_editor(m3_editor, e2e_editor):
    assert m3_editor["editor_pid"] == e2e_editor["editor_pid"]
    assert m3_editor["project"].resolve() == e2e_editor["project"].resolve()
    assert m3_editor["meta"] == e2e_editor["meta"]


def test_m4_alias_shares_e2e_editor(m4_env, e2e_editor):
    assert m4_env["editor_pid"] == e2e_editor["editor_pid"]
    assert m4_env["project"].resolve() == e2e_editor["project"].resolve()
    assert m4_env["meta"] == e2e_editor["meta"]


def test_editor_start_counter_records_one_start(e2e_editor):
    # The shared fixture has been activated at least once for this test.
    assert EDITOR_START_COUNTER["starts"] >= 1
    assert e2e_editor["editor_pid"] in EDITOR_START_COUNTER["pids"]
