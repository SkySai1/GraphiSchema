"""Three-way merge for concurrent edits to a canonical diagram project."""

from __future__ import annotations

from typing import Any

from pydantic import ValidationError

from .models import DiagramProject


_MISSING = object()
_CONFLICT = object()


def merge_projects(
    base: DiagramProject,
    local: DiagramProject,
    remote: DiagramProject,
) -> DiagramProject | None:
    """Merge independent local and remote edits, returning None on overlap."""
    merged = _merge_value(
        base.model_dump(mode="json"),
        local.model_dump(mode="json"),
        remote.model_dump(mode="json"),
    )
    if merged is _CONFLICT:
        return None
    try:
        return DiagramProject.model_validate(merged)
    except ValidationError:
        return None


def _merge_value(base: Any, local: Any, remote: Any) -> Any:
    if local == base:
        return remote
    if remote == base:
        return local
    if local == remote:
        return local

    if isinstance(local, dict) and isinstance(remote, dict):
        if base is _MISSING:
            base = {}
        if not isinstance(base, dict):
            return _CONFLICT
        merged: dict[str, Any] = {}
        keys = base.keys() | local.keys() | remote.keys()
        for key in keys:
            value = _merge_value(
                base.get(key, _MISSING),
                local.get(key, _MISSING),
                remote.get(key, _MISSING),
            )
            if value is _CONFLICT:
                return _CONFLICT
            if value is not _MISSING:
                merged[key] = value
        return merged

    if _is_identified_array(local) and _is_identified_array(remote):
        base_items = {} if base is _MISSING else _identified_items(base)
        local_items = _identified_items(local)
        remote_items = _identified_items(remote)
        if base_items is None or local_items is None or remote_items is None:
            return _CONFLICT
        order: list[str] = []
        for item in [*remote, *local]:
            item_id = item["id"]
            if item_id not in order:
                order.append(item_id)
        merged_items: list[dict[str, Any]] = []
        for item_id in order:
            item = _merge_value(
                base_items.get(item_id, _MISSING),
                local_items.get(item_id, _MISSING),
                remote_items.get(item_id, _MISSING),
            )
            if item is _CONFLICT:
                return _CONFLICT
            if item is not _MISSING:
                merged_items.append(item)
        return merged_items

    return _CONFLICT


def _is_identified_array(value: Any) -> bool:
    return isinstance(value, list) and all(
        isinstance(item, dict) and isinstance(item.get("id"), str)
        for item in value
    )


def _identified_items(value: Any) -> dict[str, dict[str, Any]] | None:
    if not _is_identified_array(value):
        return None
    items = {item["id"]: item for item in value}
    if len(items) != len(value):
        return None
    return items
