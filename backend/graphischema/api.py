"""FastAPI entry point for the local editor."""

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager, suppress
import logging
from pathlib import Path
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Query, Response, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

from .application.controller import ApplicationController, HistoryUnavailable
from .dot import to_dot
from .dot_editor import DOTEditError, MAX_DOT_BYTES, apply_dot, describe_dot_changes
from .layout import LayoutError as GeometryError, compute_layout
from .merge import merge_projects
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
from .storage import ProjectStore, RevisionConflict, VersionNotFound, ProjectNotFound, ProjectInTrash, REQUEST_SCOPE
from .paths import data_directory
from .validation import validate_diagram
from .prompt_templates import DEFAULT_VARIABLES, PromptPreviewRequest, PromptTemplateError, render_system_prompt
from .lifecycle import (
    BackendLifecycle,
    IDLE_CHECK_INTERVAL_SECONDS,
    request_server_shutdown,
)


ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = data_directory()
STORE = ProjectStore(DATA_DIR, ROOT / "examples" / "starter.json")
CONTROLLER = ApplicationController(STORE)
TRASH_SWEEP_INTERVAL_SECONDS = 60


async def cleanup_project_trash():
    try:
        await asyncio.to_thread(CONTROLLER.cleanup_expired_projects)
    except Exception:
        logging.getLogger(__name__).exception("Не удалось очистить просроченную корзину проектов")


@asynccontextmanager
async def lifespan(_app):
    await cleanup_project_trash()
    lifecycle = BackendLifecycle()
    _app.state.backend_lifecycle = lifecycle

    async def sweep():
        while True:
            await asyncio.sleep(TRASH_SWEEP_INTERVAL_SECONDS)
            await cleanup_project_trash()

    async def watch_frontend_leases():
        while True:
            await asyncio.sleep(IDLE_CHECK_INTERVAL_SECONDS)
            if lifecycle.should_shutdown():
                logging.getLogger(__name__).info("Нет активных frontend-клиентов; завершаю backend.")
                request_server_shutdown()
                return

    tasks = [asyncio.create_task(sweep()), asyncio.create_task(watch_frontend_leases())]
    try:
        yield
    finally:
        for task in tasks:
            task.cancel()
        for task in tasks:
            with suppress(asyncio.CancelledError):
                await task


app = FastAPI(title="GraphiSchema", version="0.1.0", description="Локальный редактор архитектурных диаграмм", lifespan=lifespan)

@app.middleware("http")
async def workspace_scope(request: Request, call_next):
    token = REQUEST_SCOPE.set((request.headers.get("X-GraphiSchema-Project"), request.headers.get("X-GraphiSchema-Branch")))
    try:
        response = await call_next(request)
        if request.url.path.startswith("/api/"):
            response.headers["Cache-Control"] = "no-store"
            response.headers["Vary"] = "X-GraphiSchema-Project, X-GraphiSchema-Branch"
        return response
    finally:
        REQUEST_SCOPE.reset(token)


def _diagram_envelope(project, revision=None):
    workspace = STORE.workspace()
    return {"diagram": project.model_dump(mode="json"), "revision": revision or STORE.revision(project),
            "branchId": workspace["id"], "branchName": workspace["name"], "headVersionId": workspace["head_version_id"]}


class DOTPreviewRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    dot: str = Field(min_length=1, max_length=MAX_DOT_BYTES)
    base_diagram: DiagramProject | None = None
    current_diagram: DiagramProject | None = None


@app.get("/", include_in_schema=False)
def root() -> dict[str, str]:
    return {"app": "GraphiSchema", "client": "native macOS AppKit", "docs": "/docs"}


@app.get("/api/health")
def health() -> dict[str, str]:
    storage_scope = "config"
    return {
        "status": "ok",
        "diagram_features": "container_edges_groups_exports_v3",
        "app": "GraphiSchema",
        "revision_merge": "three_way_v1",
        "edge_routing": "graphviz_v1",
        "dot_sync": "three_way_v1",
        "canvas_geometry": "icon_ports_v1",
        "node_text": "fontsize_v1",
        "edge_text": "fontsize_v1",
        "label_wrap": "renderer_v1",
        "selection_colors": "rgba_v1",
        "edge_label_background": "project_defaults_v2",
        "outline_styles": "nodes_clusters_v1",
        "version_preview": "snapshot_layout_v1",
        "container_headers": "fixed_11pt_v1",
        "workspaces": "projects_branches_v4",
        "prompt_templates": "jinja_v1",
        "lifecycle": "leases_v1",
        "storage_scope": storage_scope,
        "data_directory": str(STORE.data_dir.resolve()),
    }


class BackendLeaseRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    client_id: str = Field(min_length=1, max_length=80, pattern=r"^[A-Za-z0-9._-]+$")


@app.post("/api/lifecycle/keepalive")
def keepalive(request: Request, lease: BackendLeaseRequest) -> dict[str, Any]:
    lifecycle = getattr(request.app.state, "backend_lifecycle", None)
    if lifecycle is None:
        raise HTTPException(status_code=503, detail="Lifecycle backend недоступен.")
    active_clients = lifecycle.keepalive(lease.client_id)
    if active_clients is None:
        raise HTTPException(status_code=503, detail="Backend уже завершает работу.")
    return {"activeClients": active_clients, "leaseSeconds": 60}


@app.post("/api/lifecycle/release")
def release_frontend(request: Request, lease: BackendLeaseRequest) -> dict[str, Any]:
    lifecycle = getattr(request.app.state, "backend_lifecycle", None)
    if lifecycle is None:
        raise HTTPException(status_code=503, detail="Lifecycle backend недоступен.")
    active_clients, shutdown_scheduled = lifecycle.release(lease.client_id)
    return {"activeClients": active_clients, "shutdownScheduled": shutdown_scheduled}


@app.get("/api/diagram")
def get_diagram() -> dict[str, Any]:
    project = STORE.load()
    return _diagram_envelope(project)


class CreateProjectRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    title: str = Field(min_length=1, max_length=160)
    template: bool = False
    version_id: int | None = Field(default=None, ge=1)


class CreateBranchRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str = Field(min_length=1, max_length=80)
    from_version_id: int | None = Field(default=None, ge=1)


class CommitRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    message: str = Field(min_length=1, max_length=500)


class RegisterProjectRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    diagram: DiagramProject
    base_diagram: DiagramProject


def _project_preview(project: DiagramProject):
    try:
        layout = compute_layout(project)
    except GeometryError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return {"diagram": project.model_dump(mode="json"), "revision": STORE.revision(project), "layout": layout, "dot": to_dot(project)}


@app.get("/api/projects/draft")
def new_project_draft():
    return _project_preview(STORE.new_draft())


@app.post("/api/projects/preview")
def preview_project(project: DiagramProject):
    return _project_preview(project)


@app.post("/api/projects/register")
def register_project(request: RegisterProjectRequest):
    if REQUEST_SCOPE.get() != (None, None):
        raise HTTPException(status_code=422, detail="Сохранение первого изменения не должно менять открытый проект.")
    if request.diagram == request.base_diagram:
        raise HTTPException(status_code=422, detail="Пустой холст без изменений не требует регистрации.")
    try:
        workspace = CONTROLLER.register_project(request.diagram, request.base_diagram)
    except RevisionConflict as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    token = REQUEST_SCOPE.set((workspace["projectId"], workspace["branchId"]))
    try:
        return _diagram_envelope(STORE.load())
    finally:
        REQUEST_SCOPE.reset(token)


@app.get("/api/projects")
def projects():
    return {"projects": STORE.list_projects()}


@app.get("/api/projects/trash")
def project_trash():
    CONTROLLER.cleanup_expired_projects()
    return {"projects": STORE.list_projects(trashed=True)}


@app.post("/api/projects/{project_id}/trash")
def trash_project(project_id: str):
    return CONTROLLER.trash_project(project_id)


@app.post("/api/projects/{project_id}/restore")
def restore_project(project_id: str):
    return CONTROLLER.restore_project(project_id)


@app.delete("/api/projects/{project_id}/permanent")
def purge_project(project_id: str):
    try:
        return CONTROLLER.purge_project(project_id)
    except RevisionConflict as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@app.post("/api/projects")
def create_project(request: CreateProjectRequest):
    template = DiagramProject.model_validate_json((ROOT/"examples"/"starter.json").read_text()) if request.template else None
    return STORE.create_project(request.title, template)


@app.post("/api/projects/fork")
def fork_project(request: CreateProjectRequest):
    template = STORE.get_version(request.version_id) if request.version_id else STORE.load()
    return STORE.create_project(request.title, template, origin_project_id=template.project.id,
                                origin_version_id=request.version_id or STORE.workspace()["head_version_id"])


@app.post("/api/projects/import")
def import_project(project: DiagramProject):
    workspace = STORE.import_project(project)
    token = REQUEST_SCOPE.set((workspace["projectId"], workspace["branchId"]))
    try:
        return _diagram_envelope(STORE.load())
    finally:
        REQUEST_SCOPE.reset(token)


@app.post("/api/projects/open")
def open_project(project: DiagramProject):
    workspace = STORE.open_project(project)
    token = REQUEST_SCOPE.set((workspace["projectId"], workspace["branchId"]))
    try:
        return _diagram_envelope(STORE.load())
    finally:
        REQUEST_SCOPE.reset(token)


@app.get("/api/branches")
def branches(project_id: str | None = None):
    return {"branches": STORE.list_branches(project_id)}


@app.post("/api/branches")
def create_branch(request: CreateBranchRequest):
    return STORE.create_branch(request.name, request.from_version_id)


@app.get("/api/projects/{project_id}/branches")
def project_branches(project_id: str):
    return {"branches": STORE.list_branches(project_id)}


@app.get("/api/commits/tree")
def commit_tree():
    return STORE.commit_tree()


@app.post("/api/commits")
def create_commit(request: CommitRequest, if_match: str | None = Header(default=None, alias="If-Match")):
    project = STORE.load()
    try:
        revision = STORE.save(project, expected_revision=if_match, message=request.message, source="manual", force_commit=True)
    except RevisionConflict as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return _diagram_envelope(project, revision)


@app.get("/api/storage")
def storage_info():
    return STORE.storage_info()


@app.get("/api/ollama/variables/defaults")
def prompt_variables_defaults() -> dict[str, Any]:
    return {"variables": DEFAULT_VARIABLES}


@app.post("/api/ollama/prompt/preview")
def preview_system_prompt(request: PromptPreviewRequest) -> dict[str, str]:
    try:
        return {"prompt": render_system_prompt(request.system_prompt, request.variables)}
    except PromptTemplateError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@app.put("/api/diagram")
def put_diagram(project: DiagramProject, if_match: str | None = Header(default=None, alias="If-Match")) -> dict[str, Any]:
    try:
        result = CONTROLLER.replace_project(project, expected_revision=if_match)
    except RevisionConflict as exc:
        if if_match is None:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        try:
            result = _merge_stale_update(project, if_match)
        except RevisionConflict as merge_error:
            raise HTTPException(status_code=409, detail=str(merge_error)) from merge_error
    return _diagram_envelope(result.project, result.revision)


@app.post("/api/validate")
def validate(project: DiagramProject) -> dict[str, Any]:
    return {"valid": True, "issues": [issue.__dict__ for issue in validate_diagram(project)]}


@app.get("/api/dot", response_class=Response)
def get_dot(if_match: str | None = Header(default=None, alias="If-Match")) -> Response:
    return Response(to_dot(_checked_project(if_match)), media_type="text/vnd.graphviz; charset=utf-8")


@app.post("/api/dot/preview")
def preview_dot(request: DOTPreviewRequest, if_match: str | None = Header(default=None, alias="If-Match")) -> dict[str, Any]:
    try:
        current = _checked_project(if_match, request.current_diagram)
        base = request.base_diagram or current
        if base.project.id != current.project.id:
            raise DOTEditError("Черновик DOT относится к другому проекту. Откройте DOT текущей диаграммы.")
        edited, _ = apply_dot(base, request.dot)
        candidate = merge_projects(base, edited, current)
        if candidate is None:
            raise HTTPException(status_code=409, detail="DOT и холст изменили одни и те же поля. Согласуйте правки перед применением. Текущая диаграмма сохранена.")
        changes = describe_dot_changes(current, candidate)
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
    current = _checked_project(if_match, request.current_diagram)
    try:
        candidate = await generate_project(request, current)
        layout = compute_layout(candidate)
    except OllamaError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except GeometryError as exc:
        raise HTTPException(status_code=422, detail=f"Не удалось рассчитать компоновку: {exc}") from exc

    return {
        "diagram": candidate.model_dump(mode="json"),
        "layout": layout,
        "changes": describe_dot_changes(current, candidate),
    }


@app.post("/api/ollama/edit")
async def ollama_edit(request: OllamaTaskRequest, if_match: str | None = Header(default=None, alias="If-Match")) -> dict[str, Any]:
    current = _checked_project(if_match, request.current_diagram)
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
    current = _checked_project(if_match, request.current_diagram)
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


@app.get("/api/export.svg", response_class=Response)
def export_svg(include_legend: bool = True, show_groups: bool = False) -> Response:
    return _export_project_svg(STORE.load(),include_legend,show_groups)


@app.post("/api/export.svg", response_class=Response)
def export_snapshot_svg(project: DiagramProject, include_legend: bool = True, show_groups: bool = False) -> Response:
    return _export_project_svg(project,include_legend,show_groups)


def _export_project_svg(project,include_legend,show_groups):
    try:
        svg,engine = render_svg(project,timeout=20.0,include_legend=include_legend,show_groups=show_groups)
    except RenderError as exc:
        raise HTTPException(status_code=422,detail=str(exc)) from exc
    return Response(svg,media_type="image/svg+xml",headers={"X-GraphiSchema-Layout":engine,"Content-Disposition":'attachment; filename="graphischema-diagram.svg"'})


@app.get("/api/export.png", response_class=Response)
def export_png(scale: float = Query(default=1.0,ge=0.5,le=4.0),background: str = Query(default="#FFFFFF",max_length=11),
               width: int | None = Query(default=None,ge=64,le=16384),height: int | None = Query(default=None,ge=64,le=16384),
               include_legend: bool | None = None,show_groups: bool = False) -> Response:
    return _export_project_png(STORE.load(),scale,background,width,height,include_legend,show_groups)


@app.post("/api/export.png", response_class=Response)
def export_transient_png(project: DiagramProject,scale: float = Query(default=1.0,ge=0.5,le=4.0),background: str = Query(default="#FFFFFF",max_length=11),
                         width: int | None = Query(default=None,ge=64,le=16384),height: int | None = Query(default=None,ge=64,le=16384),
                         include_legend: bool | None = None,show_groups: bool = False) -> Response:
    return _export_project_png(project,scale,background,width,height,include_legend,show_groups)


def _export_project_png(project,scale,background,width=None,height=None,include_legend=None,show_groups=False):
    try:
        payload,engine = render_png(project,scale=scale,background=background,width=width,height=height,include_legend=include_legend,show_groups=show_groups)
    except RenderError as exc:
        raise HTTPException(status_code=422,detail=str(exc)) from exc
    return Response(payload,media_type="image/png",headers={"X-GraphiSchema-Layout":engine,"Content-Disposition":'attachment; filename="graphischema-diagram.png"'})


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


@app.get("/api/versions/{version_id}/preview")
def preview_version(version_id: int) -> dict[str, Any]:
    """Render an immutable snapshot without changing the current project/history."""
    try:
        project = STORE.get_version(version_id)
    except VersionNotFound as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    try:
        layout = compute_layout(project)
    except GeometryError as exc:
        raise HTTPException(status_code=422, detail=f"Не удалось отобразить версию: {exc}") from exc
    return {
        "versionId": version_id,
        "revision": STORE.revision(project),
        "diagram": project.model_dump(mode="json"),
        "layout": layout,
    }


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
        result = CONTROLLER.replace_project(project, expected_revision=if_match, source="restore",
                                            message=f"Восстановление коммита №{STORE.get_version_number(version_id)}", force_commit=True)
    except RevisionConflict as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return _diagram_envelope(result.project, result.revision)


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
    return _diagram_envelope(result.project, result.revision)


@app.post("/api/redo")
def redo(if_match: str | None = Header(default=None, alias="If-Match")) -> dict[str, Any]:
    try:
        result = CONTROLLER.redo(expected_revision=if_match)
    except HistoryUnavailable as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except RevisionConflict as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return _diagram_envelope(result.project, result.revision)


@app.exception_handler(ValueError)
async def value_error_handler(_request: Any, exc: ValueError) -> JSONResponse:
    return JSONResponse(status_code=422, content={"detail": str(exc)})


@app.exception_handler(ProjectNotFound)
@app.exception_handler(VersionNotFound)
async def missing_workspace_handler(_request: Any, exc: Exception) -> JSONResponse:
    return JSONResponse(status_code=404, content={"detail": str(exc)})


@app.exception_handler(ProjectInTrash)
async def trashed_workspace_handler(_request: Any, exc: Exception) -> JSONResponse:
    return JSONResponse(status_code=410, content={"detail": str(exc)})


def _checked_project(expected_revision: str | None, transient: DiagramProject | None = None) -> DiagramProject:
    if transient is not None and REQUEST_SCOPE.get() != (None, None):
        raise HTTPException(status_code=422, detail="Несохранённый холст не может подменять открытый проект.")
    project = transient if transient is not None else STORE.load()
    if expected_revision is not None and expected_revision != STORE.revision(project):
        raise HTTPException(status_code=409, detail="Проект изменился до выполнения запроса. Обновите предпросмотр и повторите.")
    return project


def _merge_stale_update(project: DiagramProject, base_revision: str) -> Any:
    base = STORE.get_project_at_revision(base_revision)
    if base is None:
        raise RevisionConflict("Не удалось найти исходную ревизию проекта для согласования изменений.")
    for _ in range(3):
        current = STORE.load()
        current_revision = STORE.revision(current)
        merged = merge_projects(base, project, current)
        if merged is None:
            raise RevisionConflict("Одно и то же поле изменено параллельно. Обновите проект и повторите правку.")
        try:
            return CONTROLLER.replace_project(merged, expected_revision=current_revision)
        except RevisionConflict:
            continue
    raise RevisionConflict("Проект продолжает изменяться. Повторите сохранение.")
