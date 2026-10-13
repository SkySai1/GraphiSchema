import json
from pathlib import Path
import sqlite3

from graphischema.models import DiagramProject
from graphischema.storage import ProjectStore, RevisionConflict


ROOT = Path(__file__).resolve().parents[1]


def test_store_migrates_legacy_json_and_keeps_version_snapshots(tmp_path: Path) -> None:
    starter = ROOT / "examples" / "starter.json"
    project_file = tmp_path / "current.json"
    legacy = DiagramProject.model_validate_json(starter.read_text())
    legacy.project.title = "Локальная миграция"
    project_file.write_text(legacy.model_dump_json(indent=2), encoding="utf-8")

    store = ProjectStore(tmp_path, starter)
    loaded = store.load()
    assert loaded.project.title == "Локальная миграция"
    assert store.database_file.exists()
    baseline = store.list_versions()[0]

    changed = loaded.model_copy(deep=True)
    changed.project.title = "Сохранённая версия"
    new_revision = store.save(changed, expected_revision=store.revision(loaded))
    assert store.load().project.title == "Сохранённая версия"
    assert len(store.list_versions()) == 2
    assert store.diff_version(baseline["id"])["project"] == ["title"]
    assert store.get_version(baseline["id"]).project.title == "Локальная миграция"

    try:
        store.save(loaded, expected_revision="stale-revision")
    except RevisionConflict:
        pass
    else:
        raise AssertionError("stale revisions must be rejected")

    restored = store.get_version(baseline["id"])
    store.save(restored, expected_revision=new_revision)
    assert store.load().project.title == "Локальная миграция"
    assert len(store.list_versions()) == 3


def test_store_normalizes_old_model_revisions_before_clients_load_them(tmp_path: Path) -> None:
    starter = ROOT / "examples" / "starter.json"
    store = ProjectStore(tmp_path, starter)
    store.load()
    with sqlite3.connect(store.database_file) as connection:
        row = connection.execute("SELECT snapshot FROM current_project WHERE slot = 1").fetchone()
        legacy = json.loads(row[0])
        for container in legacy["containers"]:
            container.pop("padding", None)
        for node in legacy["nodes"]:
            node.pop("width", None)
            node.pop("height", None)
        legacy_snapshot = json.dumps(legacy, ensure_ascii=False)
        connection.execute(
            "UPDATE current_project SET snapshot = ?, revision = ? WHERE slot = 1",
            (legacy_snapshot, "revision-from-old-model"),
        )
        connection.execute(
            "UPDATE versions SET snapshot = ?, revision = ?",
            (legacy_snapshot, "revision-from-old-model"),
        )

    upgraded_store = ProjectStore(tmp_path, starter)
    loaded = upgraded_store.load()
    current_revision = upgraded_store.revision(loaded)
    with sqlite3.connect(upgraded_store.database_file) as connection:
        stored_revision = connection.execute(
            "SELECT revision FROM current_project WHERE slot = 1"
        ).fetchone()[0]
    assert stored_revision == current_revision
    assert upgraded_store.get_project_at_revision(current_revision) == loaded
    assert upgraded_store.get_project_at_revision("revision-from-old-model") == loaded
    assert all(version["revision"] != "revision-from-old-model" for version in upgraded_store.list_versions())
