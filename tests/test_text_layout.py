import json
from pathlib import Path
from xml.etree import ElementTree as ET

import pytest
from pydantic import ValidationError

from graphischema.dot import to_dot
from graphischema.dot_editor import apply_dot, DOTEditError
from graphischema.models import DiagramProject
from graphischema.rendering import render_svg
from graphischema.storage import ProjectStore
from graphischema.text_layout import label_lines

ROOT = Path(__file__).resolve().parents[1]
CASES = json.loads((ROOT / "native/Tests/GraphiSchemaTests/Fixtures/text_layout.json").read_text())


@pytest.mark.parametrize("case", CASES)
def test_line_breaks_match_shared_native_fixtures(case):
    assert list(label_lines(case["text"], case["width"], case["font_size"], case["wrap"])) == case["expected"]


def project(wrap=True):
    return DiagramProject.model_validate({
        "diagram": {"layout_mode": "manual"},
        "nodes": [{"id": "node", "label": "абв абв\n\nабв", "label_wrap": wrap,
                   "width": .5, "height": 1.2, "x": 1, "y": 1,
                   "style": {"font_size": 10}}],
    })


@pytest.mark.parametrize("wrap", [True, False])
def test_json_dot_and_versions_preserve_wrap_and_original_label(tmp_path, wrap):
    original = project(wrap)
    decoded = DiagramProject.model_validate_json(original.model_dump_json())
    dot = to_dot(decoded)
    assert f'gs_label_wrap={str(wrap).lower()}' in dot
    assert apply_dot(decoded, dot)[0] == original
    store = ProjectStore(tmp_path, ROOT / "examples/starter.json")
    store.save(original)
    restored = store.get_version(store.list_versions()[0]["id"])
    assert restored.nodes[0].label == "абв абв\n\nабв"
    assert restored.nodes[0].label_wrap is wrap


def test_plain_nodes_with_wrap_get_fixed_geometry():
    model = DiagramProject.model_validate({"nodes": [{"id": "node", "label": "A long name", "label_wrap": True}]})
    node = model.nodes[0]
    assert (node.width, node.height) == (1.6, .62)
    assert 'fixedsize=true' in to_dot(model)


def test_old_projects_default_to_no_wrapping():
    model = DiagramProject.model_validate({"nodes": [{"id": "node", "label": "Old name"}]})
    assert model.nodes[0].label_wrap is False
    assert model.nodes[0].width is None


def test_dot_option_can_be_changed_without_changing_text():
    model = project(False)
    updated, _ = apply_dot(model, to_dot(model).replace("gs_label_wrap=false", "gs_label_wrap=true"))
    assert updated.nodes[0].label_wrap is True
    assert updated.nodes[0].label == model.nodes[0].label
    with pytest.raises(DOTEditError, match="gs_label_wrap"):
        apply_dot(model, to_dot(model).replace("gs_label_wrap=false", 'gs_label_wrap="invalid"'))


@pytest.mark.parametrize("vertical", ["top", "middle", "bottom"])
@pytest.mark.parametrize("horizontal", ["left", "center", "right"])
def test_svg_exports_each_line_with_alignment_and_clip(vertical, horizontal):
    model = project()
    model.nodes[0].label_alignment = horizontal
    model.nodes[0].label_vertical_alignment = vertical
    root = ET.fromstring(render_svg(model)[0])
    ns = {"s": "http://www.w3.org/2000/svg"}
    label = root.find('.//s:text[@clip-path="url(#label_clip_node)"]', ns)
    assert label is not None
    assert label.attrib["text-anchor"] == {"left": "start", "center": "middle", "right": "end"}[horizontal]
    assert [span.text or "" for span in label] == ["абв", "абв", "", "абв"]
    ys = [float(span.attrib["y"]) for span in label]
    assert all(b-a == pytest.approx(12.5) for a, b in zip(ys, ys[1:]))
    assert root.find('.//s:clipPath[@id="label_clip_node"]/s:rect', ns) is not None


def test_manual_lines_export_without_automatic_wrap():
    model = project(False)
    root = ET.fromstring(render_svg(model)[0])
    spans = root.findall('.//{*}text[@clip-path="url(#label_clip_node)"]/{*}tspan')
    assert [span.text or "" for span in spans] == ["абв абв", "", "абв"]


@pytest.mark.parametrize("font_size", [0, 145, float("inf")])
def test_invalid_font_values_are_rejected(font_size):
    data = project().model_dump()
    data["nodes"][0]["style"]["font_size"] = font_size
    with pytest.raises(ValidationError):
        DiagramProject.model_validate(data)
