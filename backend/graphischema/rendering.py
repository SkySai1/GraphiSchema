"""Graphviz adapter and deterministic SVG fallback for local previews."""

from __future__ import annotations

import re
import shutil
import subprocess
from functools import lru_cache
from threading import Lock

from .models import DiagramProject


class LayoutError(RuntimeError):
    pass


class _RenderGeometry:
    def __init__(self):
        self.lock = Lock()
        self.layout = None


_render_slots_lock = Lock()


@lru_cache(maxsize=4)
def _render_geometry_slot(snapshot: str, timeout: float) -> _RenderGeometry:
    # The complete canonical snapshot is the key; never mix projects/branches or
    # reuse geometry after any edit. Slots also coalesce simultaneous requests.
    return _RenderGeometry()


def _render_layout(project: DiagramProject, timeout: float):
    from .layout import compute_layout
    snapshot = project.model_dump_json()
    with _render_slots_lock:
        slot = _render_geometry_slot(snapshot, timeout)
    with slot.lock:
        if slot.layout is None:
            slot.layout = compute_layout(project, timeout)
        return slot.layout


def render_svg(project: DiagramProject, timeout: float = 8.0, *, include_legend=None, show_groups=False) -> tuple[str, str]:
    """Return (svg, engine). Graphviz is preferred; fallback is local and deterministic."""
    from .layout import LayoutError as GeometryError
    from .scene_renderer import render_scene
    try:
        layout = _render_layout(project, timeout)
    except GeometryError as exc:
        raise LayoutError(str(exc)) from exc
    return render_scene(project, layout, include_legend=include_legend, show_groups=show_groups), layout["engine"]


def render_png(project: DiagramProject, scale: float = 1.0, background: str = "#FFFFFF", timeout: float = 20.0, *, width: int | None = None, height: int | None = None, include_legend=None, show_groups=False) -> tuple[bytes, str]:
    """Rasterize the common SVG scene at the requested resolution and background."""
    if not 0.5 <= scale <= 4:
        raise LayoutError("Масштаб PNG должен быть от 0.5 до 4.")
    if background != "transparent" and not re.fullmatch(r"#[0-9a-fA-F]{6}", background):
        raise LayoutError("Фон PNG должен быть transparent или цветом #RRGGBB.")
    from .layout import LayoutError as GeometryError
    from .scene_renderer import render_scene
    binary = shutil.which("rsvg-convert")
    if not binary:
        raise LayoutError("Для экспорта PNG требуется rsvg-convert (brew install librsvg).")
    try:
        layout = _render_layout(project, timeout)
        svg = render_scene(project, layout, background=background, include_legend=include_legend, show_groups=show_groups)
        command = [binary,"--zoom",str(scale)]
        if width is not None or height is not None:
            if width is None or height is None or not (64<=width<=16384 and 64<=height<=16384) or width*height>67_108_864:
                raise LayoutError("Размер PNG: 64–16384 пикселей на сторону и не более 64 мегапикселей.")
            from xml.etree import ElementTree
            root = ElementTree.fromstring(svg)
            _,_,svg_width,svg_height = map(float,root.attrib["viewBox"].split())
            fit = min(width/svg_width,height/svg_height)
            actual_width,actual_height = svg_width*fit,svg_height*fit
            command = [binary,"--width",str(actual_width),"--height",str(actual_height),"--page-width",str(width),"--page-height",str(height),"--left",str((width-actual_width)/2),"--top",str((height-actual_height)/2)]
            if background != "transparent": command += ["--background-color",background]
        result = subprocess.run(command, input=svg.encode("utf-8"),
                                capture_output=True, check=False, timeout=timeout)
    except GeometryError as exc:
        raise LayoutError(str(exc)) from exc
    except subprocess.TimeoutExpired as exc:
        raise LayoutError("Превышено время ожидания экспорта PNG.") from exc
    if result.returncode != 0:
        raise LayoutError("Не удалось экспортировать PNG: " + result.stderr.decode("utf-8", errors="replace")[-1000:])
    return result.stdout, layout["engine"]



def render_fallback_svg(project: DiagramProject) -> str:
    """Use the common scene so offline rendering retains identical styles and labels."""
    from .layout import _fallback_layout
    from .geometry import normalize_edges
    from .scene_renderer import render_scene
    return render_scene(project, normalize_edges(project, _fallback_layout(project, "fallback")))
