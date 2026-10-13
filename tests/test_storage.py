from pathlib import Path

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
