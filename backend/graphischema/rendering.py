"""Graphviz adapter and deterministic SVG fallback for local previews."""

from __future__ import annotations

import re
import shutil
import subprocess

from .models import DiagramProject


class LayoutError(RuntimeError):
    pass


def render_svg(project: DiagramProject, timeout: float = 8.0) -> tuple[str, str]:
    """Return (svg, engine). Graphviz is preferred; fallback is local and deterministic."""
    from .layout import compute_layout, LayoutError as GeometryError
    from .scene_renderer import render_scene
    try:
        layout = compute_layout(project, timeout)
    except GeometryError as exc:
        raise LayoutError(str(exc)) from exc
    return render_scene(project, layout), layout["engine"]


def render_png(project: DiagramProject, scale: float = 1.0, background: str = "#FFFFFF", timeout: float = 20.0) -> tuple[bytes, str]:
    """Rasterize the common SVG scene at the requested resolution and background."""
    if not 0.5 <= scale <= 4:
        raise LayoutError("Масштаб PNG должен быть от 0.5 до 4.")
    if background != "transparent" and not re.fullmatch(r"#[0-9a-fA-F]{6}", background):
        raise LayoutError("Фон PNG должен быть transparent или цветом #RRGGBB.")
    from .layout import compute_layout, LayoutError as GeometryError
    from .scene_renderer import render_scene
    binary = shutil.which("rsvg-convert")
    if not binary:
        raise LayoutError("Для экспорта PNG требуется rsvg-convert (brew install librsvg).")
    try:
        layout = compute_layout(project, timeout)
        svg = render_scene(project, layout, background=background)
        result = subprocess.run([binary, "--zoom", str(scale)], input=svg.encode("utf-8"),
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
