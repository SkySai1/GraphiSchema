from pathlib import Path
import shutil
from xml.etree import ElementTree

import pytest

from graphischema.models import DiagramProject
from graphischema.rendering import LayoutError, render_fallback_svg, render_png, render_svg


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def project() -> DiagramProject:
    return DiagramProject.model_validate_json((ROOT / "examples" / "starter.json").read_text())


def test_fallback_svg_is_valid_and_contains_graph_labels(project: DiagramProject) -> None:
    svg = render_fallback_svg(project)
    assert svg.startswith('<svg xmlns="http://www.w3.org/2000/svg"')
    assert "WAF" in svg
    assert "PostgreSQL" in svg
    assert "DMZ" in svg
    assert "HTTPS" in svg
    assert svg.endswith("</svg>")


def test_fallback_svg_is_deterministic(project: DiagramProject) -> None:
    assert render_fallback_svg(project) == render_fallback_svg(project)


def test_fallback_svg_reflects_custom_node_dimensions(project: DiagramProject) -> None:
    project.nodes[0].shape = "box"
    project.nodes[0].width = 4.0
    project.nodes[0].height = 1.2
    svg = render_fallback_svg(project)
    assert 'width="304.0" height="162.6"' in svg


def test_fallback_svg_escapes_untrusted_text(project: DiagramProject) -> None:
    project.nodes[0].label = '<script>alert("x")</script>'
    svg = render_fallback_svg(project)
    assert "<script>" not in svg
    assert "&lt;script&gt;" in svg


@pytest.mark.skipif(not shutil.which("dot"), reason="Graphviz dot is not installed")
def test_graphviz_layout_returns_parseable_svg(project: DiagramProject) -> None:
    svg, engine = render_svg(project)
    assert engine == "dot"
    assert ElementTree.fromstring(svg).tag.endswith("svg")
    assert "WAF" in svg


@pytest.mark.skipif(not shutil.which("dot"), reason="Graphviz dot is not installed")
def test_graphviz_png_export_respects_scale_and_background(project: DiagramProject) -> None:
    png_1x, engine = render_png(project, scale=1, background="#FFFFFF")
    png_2x, _ = render_png(project, scale=2, background="transparent")
    assert engine == "dot"
    assert png_1x.startswith(b"\x89PNG\r\n\x1a\n")
    assert png_2x.startswith(b"\x89PNG\r\n\x1a\n")
    assert png_2x[25] == 6
    width_1x, height_1x = int.from_bytes(png_1x[16:20], "big"), int.from_bytes(png_1x[20:24], "big")
    width_2x, height_2x = int.from_bytes(png_2x[16:20], "big"), int.from_bytes(png_2x[20:24], "big")
    assert abs(width_2x - 2 * width_1x) <= 1
    assert abs(height_2x - 2 * height_1x) <= 1


def test_png_export_rejects_invalid_scale_and_background(project: DiagramProject) -> None:
    with pytest.raises(LayoutError, match="Масштаб PNG"):
        render_png(project, scale=5)
    with pytest.raises(LayoutError, match="Фон PNG"):
        render_png(project, background="url(unsafe)")
