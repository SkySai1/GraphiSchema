"""Real SVG/PNG export options, raster size and read-only snapshot regressions."""
import shutil
from xml.etree import ElementTree

import pytest
from fastapi.testclient import TestClient

from graphischema import api
from graphischema.models import DiagramProject


pytestmark = pytest.mark.skipif(
    not shutil.which("dot") or not shutil.which("rsvg-convert"),
    reason="Real PNG regressions require Graphviz and librsvg",
)


def export_snapshot():
    return DiagramProject.model_validate({
        "project": {"id": "png_draft", "title": "Unsaved PNG"},
        "diagram": {"layout_mode": "manual"},
        "nodes": [
            {"id": "a", "label": "Server", "x": 0, "y": 0, "width": 2, "height": 1},
            {"id": "b", "label": "Database", "x": 4, "y": 0, "width": 2, "height": 1},
        ],
        "edges": [{"id": "ab", "source": "a", "target": "b", "label": "HTTPS"}],
        "groups": [{"id": "pair", "label": "Group", "node_ids": ["a", "b"]}],
    }).model_dump(mode="json")


def test_png_options_update_pixels_and_svg_without_saving_project(monkeypatch):
    from graphischema import layout
    with TestClient(api.app) as client:
        before = client.get("/api/diagram").json()
        versions = client.get("/api/versions").json()
        original_layout = layout.compute_layout
        calls = []
        def observed_layout(project, timeout):
            calls.append(project.project.id)
            return original_layout(project, timeout)
        monkeypatch.setattr(layout, "compute_layout", observed_layout)
        rasters = {}
        for legend in (False, True):
            for groups in (False, True):
                options = {"include_legend": legend, "show_groups": groups}
                svg = client.post("/api/export.svg", params=options, json=export_snapshot())
                assert svg.status_code == 200, svg.text
                root = ElementTree.fromstring(svg.content)
                assert any(e.get("data-legend") for e in root.iter()) == legend
                assert any(e.get("data-group") == "pair" for e in root.iter()) == groups
                png = client.post("/api/export.png", params={**options, "width": 800, "height": 450}, json=export_snapshot())
                assert png.status_code == 200, png.text[:1000]
                assert png.headers["content-type"] == "image/png"
                assert png.content[:8] == b"\x89PNG\r\n\x1a\n"
                assert int.from_bytes(png.content[16:20], "big") == 800
                assert int.from_bytes(png.content[20:24], "big") == 450
                rasters[legend, groups] = png.content
        assert len(set(rasters.values())) == 4, "Each legend/group combination must produce its own image"
        assert calls == ["png_draft"], "SVG and PNG option changes must reuse the same canonical geometry"
        assert client.get("/api/diagram").json() == before
        assert client.get("/api/versions").json() == versions


def test_export_geometry_cache_coalesces_requests_and_invalidates_after_edits(monkeypatch):
    from concurrent.futures import ThreadPoolExecutor
    from time import sleep
    from graphischema import layout
    from graphischema.rendering import render_svg
    project = DiagramProject.model_validate(export_snapshot())
    original = layout.compute_layout
    calls = []
    def slow_layout(project, timeout):
        calls.append(project.project.id)
        sleep(.05)
        return original(project, timeout)
    monkeypatch.setattr(layout, "compute_layout", slow_layout)
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(lambda legend: render_svg(project, timeout=20, include_legend=legend)[0], [True, False, True, False]))
    assert calls == ["png_draft"]
    assert results[0] == results[2] and results[1] == results[3] and results[0] != results[1]
    project.nodes[0].label = "Changed"
    render_svg(project, timeout=20)
    assert calls == ["png_draft", "png_draft"]
    project.project.id = "another_project"
    render_svg(project, timeout=20)
    assert calls[-1] == "another_project" and len(calls) == 3


@pytest.mark.parametrize("size", [{"width": 800}, {"width": 63, "height": 450}, {"width": 16384, "height": 16384}])
def test_invalid_png_dimensions_explain_failure_and_do_not_poison_later_export(size):
    with TestClient(api.app) as client:
        failed = client.post("/api/export.png", params=size, json=export_snapshot())
        assert failed.status_code == 422
        assert failed.json()["detail"]
        recovered = client.post("/api/export.png", params={"width": 640, "height": 480, "include_legend": False, "show_groups": True}, json=export_snapshot())
        assert recovered.status_code == 200, recovered.text[:1000]
        assert int.from_bytes(recovered.content[16:20], "big") == 640
        assert int.from_bytes(recovered.content[20:24], "big") == 480
