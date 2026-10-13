"""SQLite project storage with immutable, locally retained snapshots."""

from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sqlite3
from threading import RLock
from typing import Iterator

from .models import DiagramProject


class RevisionConflict(Exception):
    pass


class VersionNotFound(Exception):
    pass


class ProjectStore:
    def __init__(self, data_dir: Path, starter_file: Path):
        self.data_dir = data_dir
        self.project_file = data_dir / "current.json"  # Imported once for migration from early MVP builds.
        self.database_file = data_dir / "graphischema.sqlite3"
        self.starter_file = starter_file
        self._lock = RLock()

    def load(self) -> DiagramProject:
        with self._lock, self._database() as connection:
            row = connection.execute("SELECT snapshot FROM current_project WHERE slot = 1").fetchone()
            if row is None:
                raise RuntimeError("SQLite project store was not initialized")
            return DiagramProject.model_validate_json(row["snapshot"])

    def revision(self, project: DiagramProject | None = None) -> str:
        diagram = project or self.load()
        encoded = json.dumps(diagram.model_dump(mode="json"), sort_keys=True, ensure_ascii=False, separators=(",", ":"))
        return hashlib.sha256(encoded.encode("utf-8")).hexdigest()[:16]

    def save(self, project: DiagramProject, expected_revision: str | None = None) -> str:
        with self._lock, self._database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute("SELECT snapshot, revision FROM current_project WHERE slot = 1").fetchone()
            if row is None:
                connection.rollback()
                raise RuntimeError("SQLite project store was not initialized")
            current_revision = row["revision"]
            if expected_revision is not None and expected_revision != current_revision:
                connection.rollback()
                raise RevisionConflict("Проект уже изменён в другой вкладке. Обновите данные перед сохранением.")

            revision = self.revision(project)
            if revision == current_revision:
                connection.commit()
                return revision
            snapshot = _serialize(project)
            created_at = _timestamp()
            connection.execute(
                "UPDATE current_project SET project_id = ?, snapshot = ?, revision = ?, updated_at = ? WHERE slot = 1",
                (project.project.id, snapshot, revision, created_at),
            )
            connection.execute(
                "INSERT INTO versions(project_id, title, revision, snapshot, created_at) VALUES (?, ?, ?, ?, ?)",
                (project.project.id, project.project.title, revision, snapshot, created_at),
            )
            connection.commit()
            return revision

    def list_versions(self, limit: int = 100) -> list[dict[str, object]]:
        with self._lock, self._database() as connection:
            rows = connection.execute(
                "SELECT id, project_id, title, revision, created_at FROM versions ORDER BY id DESC LIMIT ?",
                (max(1, min(limit, 500)),),
            ).fetchall()
            return [
                {"id": row["id"], "projectId": row["project_id"], "title": row["title"],
                 "revision": row["revision"], "createdAt": row["created_at"]}
                for row in rows
            ]

    def get_version(self, version_id: int) -> DiagramProject:
        with self._lock, self._database() as connection:
            row = connection.execute("SELECT snapshot FROM versions WHERE id = ?", (version_id,)).fetchone()
            if row is None:
                raise VersionNotFound(f"Снимок версии {version_id} не найден.")
            return DiagramProject.model_validate_json(row["snapshot"])

    def diff_version(self, version_id: int) -> dict[str, object]:
        with self._lock, self._database() as connection:
            row = connection.execute(
                "SELECT id, title, revision, snapshot FROM versions WHERE id = ?", (version_id,)
            ).fetchone()
            if row is None:
                raise VersionNotFound(f"Снимок версии {version_id} не найден.")
            current_row = connection.execute("SELECT snapshot, revision FROM current_project WHERE slot = 1").fetchone()
            if current_row is None:
                raise RuntimeError("SQLite project store was not initialized")
            baseline = DiagramProject.model_validate_json(row["snapshot"])
            current = DiagramProject.model_validate_json(current_row["snapshot"])
            return {
                "versionId": row["id"],
                "versionTitle": row["title"],
                "baseRevision": row["revision"],
                "currentRevision": current_row["revision"],
                "project": _changed_fields(baseline.project.model_dump(mode="json"), current.project.model_dump(mode="json")),
                "diagram": _changed_fields(baseline.diagram.model_dump(mode="json"), current.diagram.model_dump(mode="json")),
                "presentation": _changed_fields(baseline.presentation.model_dump(mode="json"), current.presentation.model_dump(mode="json")),
                "containers": _element_diff(baseline.containers, current.containers),
                "nodes": _element_diff(baseline.nodes, current.nodes),
                "edges": _element_diff(baseline.edges, current.edges),
            }

    @contextmanager
    def _database(self) -> Iterator[sqlite3.Connection]:
        self.data_dir.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(self.database_file, timeout=10, isolation_level=None)
        connection.row_factory = sqlite3.Row
        try:
            connection.execute("PRAGMA journal_mode = WAL")
            connection.execute("PRAGMA foreign_keys = ON")
            connection.execute(
                """CREATE TABLE IF NOT EXISTS current_project (
                    slot INTEGER PRIMARY KEY CHECK (slot = 1),
                    project_id TEXT NOT NULL,
                    snapshot TEXT NOT NULL,
                    revision TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )"""
            )
            connection.execute(
                """CREATE TABLE IF NOT EXISTS versions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    project_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    revision TEXT NOT NULL,
                    snapshot TEXT NOT NULL,
                    created_at TEXT NOT NULL
                )"""
            )
            connection.execute("CREATE INDEX IF NOT EXISTS versions_created_at ON versions(id DESC)")
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute("SELECT 1 FROM current_project WHERE slot = 1").fetchone()
            if row is None:
                source = self.project_file if self.project_file.exists() else self.starter_file
                initial = DiagramProject.model_validate_json(source.read_text(encoding="utf-8"))
                revision = self.revision(initial)
                snapshot = _serialize(initial)
                created_at = _timestamp()
                connection.execute(
                    "INSERT INTO current_project(slot, project_id, snapshot, revision, updated_at) VALUES (1, ?, ?, ?, ?)",
                    (initial.project.id, snapshot, revision, created_at),
                )
                connection.execute(
                    "INSERT INTO versions(project_id, title, revision, snapshot, created_at) VALUES (?, ?, ?, ?, ?)",
                    (initial.project.id, initial.project.title, revision, snapshot, created_at),
                )
            connection.commit()
            yield connection
        except Exception:
            if connection.in_transaction:
                connection.rollback()
            raise
        finally:
            connection.close()


def _serialize(project: DiagramProject) -> str:
    return json.dumps(project.model_dump(mode="json"), ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _changed_fields(before: dict[str, object], after: dict[str, object]) -> list[str]:
    return sorted(key for key in set(before) | set(after) if before.get(key) != after.get(key))


def _element_diff(before_items: list, after_items: list) -> dict[str, object]:
    before = {item.id: item.model_dump(mode="json") for item in before_items}
    after = {item.id: item.model_dump(mode="json") for item in after_items}
    modified = sorted(item_id for item_id in before.keys() & after.keys() if before[item_id] != after[item_id])
    return {
        "added": sorted(after.keys() - before.keys()),
        "removed": sorted(before.keys() - after.keys()),
        "modified": modified,
        "details": [
            {"id": item_id, "fields": _changed_fields(before[item_id], after[item_id])}
            for item_id in modified
        ],
    }
