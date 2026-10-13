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
        self._undo: list[DiagramProject] = []
        self._redo: list[DiagramProject] = []
        self._lock = RLock()

    def replace_project(self, project: DiagramProject, expected_revision: str | None = None) -> UpdateResult:
        with self._lock:
            previous = self.store.load()
            previous_revision = self.store.revision(previous)
            revision = self.store.save(project, expected_revision=expected_revision)
            if revision != previous_revision:
                self._undo.append(previous)
                self._redo.clear()
            return UpdateResult(project=project, revision=revision, issues=validate_diagram(project))

    def undo(self, expected_revision: str | None = None) -> UpdateResult:
        return self._move_history(self._undo, self._redo, expected_revision)

    def redo(self, expected_revision: str | None = None) -> UpdateResult:
        return self._move_history(self._redo, self._undo, expected_revision)

    @property
    def history_state(self) -> dict[str, bool]:
        with self._lock:
            return {"canUndo": bool(self._undo), "canRedo": bool(self._redo)}

    def _move_history(
        self,
        source: list[DiagramProject],
        destination: list[DiagramProject],
        expected_revision: str | None,
    ) -> UpdateResult:
        with self._lock:
            if not source:
                raise HistoryUnavailable("Нет сохранённого действия для этой команды.")
            current = self.store.load()
            target = source[-1]
            revision = self.store.save(target, expected_revision=expected_revision)
            source.pop()
            destination.append(current)
            return UpdateResult(project=target, revision=revision, issues=validate_diagram(target))
