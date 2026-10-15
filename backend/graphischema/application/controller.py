"""Single write path for project updates."""

from __future__ import annotations

from dataclasses import dataclass
from threading import RLock

from ..models import DiagramProject
from ..storage import ProjectStore
from ..validation import ValidationIssue, validate_diagram


@dataclass(frozen=True)
class UpdateResult:
    project: DiagramProject
    revision: str
    issues: list[ValidationIssue]


class HistoryUnavailable(Exception):
    pass


class ApplicationController:
    def __init__(self, store: ProjectStore):
        self.store = store
        self._undo: dict[str, list[DiagramProject]] = {}
        self._redo: dict[str, list[DiagramProject]] = {}
        self._lock = RLock()

    def replace_project(self, project: DiagramProject, expected_revision: str | None = None,
                        *, source: str = "edit", message: str = "Изменение схемы", force_commit: bool = False) -> UpdateResult:
        with self._lock:
            previous = self.store.load()
            workspace = self.store.workspace()
            previous_revision = self.store.revision(previous)
            revision = self.store.save(project, expected_revision=expected_revision, source=source, message=message, force_commit=force_commit)
            if revision != previous_revision and project.project.id == previous.project.id:
                self._undo.setdefault(workspace["id"], []).append(previous)
                self._redo.setdefault(workspace["id"], []).clear()
            return UpdateResult(project=project, revision=revision, issues=validate_diagram(project))

    def undo(self, expected_revision: str | None = None) -> UpdateResult:
        return self._move_history(False, expected_revision)

    def redo(self, expected_revision: str | None = None) -> UpdateResult:
        return self._move_history(True, expected_revision)

    @property
    def history_state(self) -> dict[str, bool]:
        with self._lock:
            key = self.store.workspace()["id"]
            return {"canUndo": bool(self._undo.get(key)), "canRedo": bool(self._redo.get(key))}

    def _move_history(
        self,
        redo: bool,
        expected_revision: str | None,
    ) -> UpdateResult:
        with self._lock:
            key = self.store.workspace()["id"]
            source = (self._redo if redo else self._undo).setdefault(key, [])
            destination = (self._undo if redo else self._redo).setdefault(key, [])
            if not source:
                raise HistoryUnavailable("Нет сохранённого действия для этой команды.")
            current = self.store.load()
            target = source[-1]
            revision = self.store.save(target, expected_revision=expected_revision, source="redo" if redo else "undo",
                                       message="Повтор изменения" if redo else "Отмена изменения")
            source.pop()
            destination.append(current)
            return UpdateResult(project=target, revision=revision, issues=validate_diagram(target))
