"""Object border lengths scale with pen width, including rounded cap coverage."""
import json
from pathlib import Path
from xml.etree import ElementTree as ET

import pytest

from graphischema.dot import to_dot
from graphischema.dot_editor import apply_dot
from graphischema.geometry import icon_library, normalized_paths
from graphischema.models import DiagramProject
from graphischema.rendering import render_fallback_svg, render_svg
from graphischema.scene_renderer import render_scene

ROOT = Path(__file__).resolve().parents[1]
CASES = json.loads((ROOT/'native/Tests/GraphiSchemaTests/Fixtures/border_patterns.json').read_text())
FIGURES = [(None, shape) for shape in ('box', 'ellipse', 'diamond', 'hexagon', 'cloud', 'cylinder')]
FIGURES += [(icon, 'box') for icon in sorted(icon_library())]


def project(style, width, *, icon=None, shape='box'):
    return DiagramProject.model_validate({
        'diagram': {'layout_mode': 'manual'},
        'nodes': [{'id': 'figure', 'label': 'X', 'x': 0, 'y': 0, 'width': 10, 'height': 3,
                   'icon': icon, 'shape': shape, 'style': {'line_style': style, 'penwidth': width}}],
    })


def strokes(svg):
    return [e for e in ET.fromstring(svg).iter() if e.get('data-node-stroke') == 'figure']


def assert_pattern(paths, style, width, expected):
    assert paths
    for path in paths:
        assert float(path.get('stroke-width')) == width
        pattern = [float(v) for v in path.get('stroke-dasharray', '').split()]
        assert pattern == pytest.approx(expected)
        if style == 'solid':
            assert path.get('stroke-dasharray') is None
        else:
            assert path.get('stroke-linecap') == 'round'
            # Each adjacent round cap consumes width/2 of the specified gap.
            visible_gap = pattern[1]-width
            assert visible_gap > 0
            assert visible_gap/width == pytest.approx(5/3 if style == 'dashed' else 1)


@pytest.mark.parametrize('case', CASES, ids=lambda c: f"{c['style']}-{c['width']}pt")
@pytest.mark.parametrize('render', [render_fallback_svg, lambda p: render_svg(p)[0]], ids=['fallback', 'graphviz'])
def test_export_border_matches_shared_native_fixtures(case, render):
    p = project(case['style'], case['width'])
    before = p.model_dump_json()
    assert_pattern(strokes(render(p)), case['style'], case['width'], case['pattern'])
    assert p.model_dump_json() == before  # Rendering never rewrites the style/snapshot.
    roundtrip, _ = apply_dot(p, to_dot(p))
    assert roundtrip == p


@pytest.mark.parametrize('icon,shape', FIGURES)
@pytest.mark.parametrize('style', ['solid', 'dashed', 'dotted'])
def test_thick_border_scales_every_contour_of_every_figure(icon, shape, style):
    p = project(style, 10, icon=icon, shape=shape)
    layout = {'width': 12, 'height': 5, 'minX': -6, 'minY': -2.5,
              'nodes': [{'id': 'figure', 'x': 0, 'y': 0, 'width': 10, 'height': 3}], 'edges': []}
    paths = strokes(render_scene(p, layout))
    assert len(paths) == len(normalized_paths(p.nodes[0]))
    assert_pattern(paths, style, 10, {'solid': [], 'dashed': [40, 80/3], 'dotted': [10, 20]}[style])
