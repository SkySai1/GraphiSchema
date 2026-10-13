"""FastAPI entry point for the local editor."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Query, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

from .application.controller import ApplicationController, HistoryUnavailable
from .dot import to_dot
from .dot_editor import DOTEditError, MAX_DOT_BYTES, apply_dot
from .layout import LayoutError as GeometryError, compute_layout
from .models import DiagramProject
from .ollama import (
    DEFAULT_ENDPOINT,
    OllamaConnection,
    OllamaError,
    OllamaReviewRequest,
    OllamaTaskRequest,
    apply_operations,
    check_connection,
    edit_operations,
    generate_project,
    review_project,
)
from .rendering import LayoutError as RenderError, render_png, render_svg
from .storage import ProjectStore, RevisionConflict, VersionNotFound
from .validation import validate_diagram


ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = Path(os.environ.get("GRAPHI_SCHEMA_DATA_DIR", ROOT / "data"))
STORE = ProjectStore(DATA_DIR, ROOT / "examples" / "starter.json")
CONTROLLER = ApplicationController(STORE)
app = FastAPI(title="GraphiSchema", version="0.1.0", description="Локальный редактор архитектурных диаграмм")


class DOTPreviewRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    dot: str = Field(min_length=1, max_length=MAX_DOT_BYTES)


@app.get("/", include_in_schema=False)
def root() -> dict[str, str]:
    return {"app": "GraphiSchema", "client": "native macOS AppKit", "docs": "/docs"}


@app.get("/api/health")
def health() -> dict[str, str]:
    return {"status": "ok", "app": "GraphiSchema"}


@app.get("/api/diagram")
def get_diagram() -> dict[str, Any]:
    project = STORE.load()
    return {"diagram": project.model_dump(mode="json"), "revision": STORE.revision(project)}


@app.put("/api/diagram")
def put_diagram(project: DiagramProject, if_match: str | None = Header(default=None, alias="If-Match")) -> dict[str, Any]:
    try:
        result = CONTROLLER.replace_project(project, expected_revision=if_match)
    except RevisionConflict as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return {"diagram": result.project.model_dump(mode="json"), "revision": result.revision}


@app.post("/api/validate")
def validate(project: DiagramProject) -> dict[str, Any]:
    return {"valid": True, "issues": [issue.__dict__ for issue in validate_diagram(project)]}


@app.get("/api/dot", response_class=Response)
def get_dot() -> Response:
    return Response(to_dot(STORE.load()), media_type="text/vnd.graphviz; charset=utf-8")


@app.post("/api/dot/preview")
def preview_dot(request: DOTPreviewRequest, if_match: str | None = Header(default=None, alias="If-Match")) -> dict[str, Any]:
    try:
        current = _checked_project(if_match)
        candidate, changes = apply_dot(current, request.dot)
        layout = compute_layout(candidate)
    except DOTEditError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except GeometryError as exc:
        raise HTTPException(status_code=422, detail=f"Не удалось рассчитать компоновку: {exc}") from exc
    return {
        "diagram": candidate.model_dump(mode="json"),
        "layout": layout,
        "changes": changes,
    }


@app.get("/api/ollama/models")
async def ollama_models(
    endpoint: str = Query(default=DEFAULT_ENDPOINT, min_length=1, max_length=300),
    timeout: float = Query(default=5, ge=1, le=30),
) -> dict[str, Any]:
    try:
        models = await check_connection(endpoint, timeout)
    except OllamaError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"available": True, "models": models}


@app.post("/api/ollama/check")
async def ollama_check(request: OllamaConnection) -> dict[str, Any]:
    try:
        models = await check_connection(request.endpoint, request.timeout)
    except OllamaError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"available": True, "models": models}


@app.post("/api/ollama/generate")
async def ollama_generate(request: OllamaTaskRequest, if_match: str | None = Header(default=None, alias="If-Match")) -> dict[str, Any]:
    current = _checked_project(if_match)
    try:
        candidate = await generate_project(request, current)
        layout = compute_layout(candidate)
    except OllamaError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except GeometryError as exc:
        raise HTTPException(status_code=422, detail=f"Не удалось рассчитать компоновку: {exc}") from exc
    from .dot_editor import _changes

    return {
        "diagram": candidate.model_dump(mode="json"),
        "layout": layout,
        "changes": _changes(current, candidate),
    }


@app.post("/api/ollama/edit")
async def ollama_edit(request: OllamaTaskRequest, if_match: str | None = Header(default=None, alias="If-Match")) -> dict[str, Any]:
    current = _checked_project(if_match)
    try:
        operations = await edit_operations(request, current)
        candidate, changes = apply_operations(current, operations)
        layout = compute_layout(candidate)
    except OllamaError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except GeometryError as exc:
        raise HTTPException(status_code=422, detail=f"Не удалось рассчитать компоновку: {exc}") from exc
    return {
        "diagram": candidate.model_dump(mode="json"),
        "layout": layout,
        "changes": changes,
        "operations": operations,
    }


@app.post("/api/ollama/review")
async def ollama_review(request: OllamaReviewRequest, if_match: str | None = Header(default=None, alias="If-Match")) -> dict[str, Any]:
    current = _checked_project(if_match)
    try:
        report = await review_project(request, current)
    except OllamaError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"report": report, "revision": STORE.revision(current)}


@app.get("/api/layout")
def get_layout() -> dict[str, Any]:
    try:
        return compute_layout(STORE.load())
    except GeometryError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@app.get("/api/render.svg", response_class=Response)
def get_svg() -> Response:
    try:
        svg, engine = render_svg(STORE.load())
    except RenderError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return Response(svg, media_type="image/svg+xml", headers={"X-GraphiSchema-Layout": engine})


@app.get("/api/export.png", response_class=Response)
def export_png(
    scale: float = Query(default=1.0, ge=0.5, le=4.0),
    background: str = Query(default="#FFFFFF", max_length=11),
) -> Response:
    try:
        payload, engine = render_png(STORE.load(), scale=scale, background=background)
    except RenderError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return Response(
        payload,
        media_type="image/png",
        headers={"X-GraphiSchema-Layout": engine, "Content-Disposition": 'attachment; filename="graphischema-diagram.png"'},
    )


@app.get("/api/export.json")
def export_json() -> Response:
    project = STORE.load()
    payload = project.model_dump_json(indent=2)
    return Response(
        payload,
        media_type="application/json",
        headers={"Content-Disposition": 'attachment; filename="graphischema-project.json"'},
    )


@app.get("/api/versions")
def get_versions() -> dict[str, Any]:
    return {"versions": STORE.list_versions()}


@app.get("/api/versions/{version_id}/diff")
def get_version_diff(version_id: int) -> dict[str, Any]:
    try:
        return STORE.diff_version(version_id)
    except VersionNotFound as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@app.post("/api/versions/{version_id}/restore")
def restore_version(
    version_id: int,
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> dict[str, Any]:
    try:
        project = STORE.get_version(version_id)
    except VersionNotFound as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    try:
        result = CONTROLLER.replace_project(project, expected_revision=if_match)
    except RevisionConflict as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return {"diagram": result.project.model_dump(mode="json"), "revision": result.revision}


@app.get("/api/history")
def get_history_state() -> dict[str, bool]:
    return CONTROLLER.history_state


@app.post("/api/undo")
def undo(if_match: str | None = Header(default=None, alias="If-Match")) -> dict[str, Any]:
    try:
        result = CONTROLLER.undo(expected_revision=if_match)
    except HistoryUnavailable as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except RevisionConflict as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return {"diagram": result.project.model_dump(mode="json"), "revision": result.revision}


@app.post("/api/redo")
def redo(if_match: str | None = Header(default=None, alias="If-Match")) -> dict[str, Any]:
    try:
        result = CONTROLLER.redo(expected_revision=if_match)
    except HistoryUnavailable as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except RevisionConflict as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return {"diagram": result.project.model_dump(mode="json"), "revision": result.revision}


@app.exception_handler(ValueError)
async def value_error_handler(_request: Any, exc: ValueError) -> JSONResponse:
    return JSONResponse(status_code=422, content={"detail": str(exc)})


def _checked_project(expected_revision: str | None) -> DiagramProject:
    project = STORE.load()
    if expected_revision is not None and expected_revision != STORE.revision(project):
        raise HTTPException(status_code=409, detail="Проект изменился до выполнения запроса. Обновите предпросмотр и повторите.")
    return project
