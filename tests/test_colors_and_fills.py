"""Theme contract, legacy colors, all vendored figure bodies and stroke ordering."""
import ast
import json
import math
from pathlib import Path
from xml.etree import ElementTree as ET
import pytest
from pydantic import ValidationError
from graphischema.colors import resolve_color
from graphischema.dot import to_dot
from graphischema.dot_editor import apply_dot
from graphischema.geometry import icon_library
from graphischema.models import DiagramProject
from graphischema.ollama import apply_operations
from graphischema.rendering import render_svg

ROOT=Path(__file__).resolve().parents[1]

@pytest.mark.parametrize('theme',['light','dark'])
@pytest.mark.parametrize('mode',['custom','theme','inverse'])
@pytest.mark.parametrize('fill',[True,False])
def test_monochrome_color_truth_table(theme,mode,fill):
    value=resolve_color('#11223380',mode,theme,fill=fill)
    if mode=='custom': assert value=='#11223380'
    else:
        white=(theme=='light') if fill else (theme=='dark')
        if mode=='inverse':white=not white
        assert value==('#FFFFFF' if white else '#000000')

def new_project():
    return DiagramProject.model_validate({'nodes':[{'id':'a','label':'A'},{'id':'b','label':'B'}],
        'containers':[{'id':'zone','label':'Zone'}], 'edges':[{'id':'ab','source':'a','target':'b','label':'Link'}]})

def test_new_elements_default_to_auto_and_legacy_explicit_colors_stay_custom():
    project=new_project()
    for item in [*project.nodes,*project.containers]:
        assert (item.style.fill_mode,item.style.stroke_mode,item.style.text_mode)==('theme',)*3
    assert project.edges[0].style.color_mode=='theme'
    legacy=json.loads((ROOT/'examples/starter.json').read_text())
    restored=DiagramProject.model_validate(legacy)
    for item in [*restored.nodes,*restored.containers]: assert item.style.fill_mode==item.style.stroke_mode==item.style.text_mode=='custom'
    assert json.loads(restored.model_dump_json())['nodes'][0]['style']['fill']==legacy['nodes'][0]['style']['fill']

@pytest.mark.parametrize('theme',['light','dark'])
def test_render_resolves_modes_without_mutating_snapshot_and_roundtrips_dot(theme):
    project=new_project();project.presentation.theme=theme
    project.nodes[0].style.fill_mode='inverse';project.nodes[0].style.text_mode='inverse'
    before=project.model_dump_json()
    root=ET.fromstring(render_svg(project)[0]);group=next(e for e in root.iter() if e.get('data-node')=='a')
    fill=next(e for e in group if e.get('data-node-fill'));text=next(e for e in group if e.tag.endswith('text'))
    assert fill.get('fill')==('#000000' if theme=='light' else '#FFFFFF')
    assert text.get('fill')==('#FFFFFF' if theme=='light' else '#000000')
    assert project.model_dump_json()==before
    candidate,_=apply_dot(project,to_dot(project));assert candidate==project
    modified,_=apply_dot(project,to_dot(project).replace('fillcolor="#FFFFFF"','fillcolor="#12345680"',1))
    assert modified.nodes[0].style.fill_mode=='custom'
    assert modified.nodes[0].style.fill=='#12345680'

def test_ollama_color_change_exits_auto_but_can_explicitly_choose_inverse():
    project=new_project()
    changed,_=apply_operations(project,[{'op':'update_node','id':'a','changes':{'style':{'fill':'#12345680'}}}])
    assert changed.nodes[0].style.fill_mode=='custom'
    assert project.nodes[0].style.fill_mode=='theme'
    changed,_=apply_operations(project,[{'op':'update_edge','id':'ab','changes':{'style':{'color_mode':'inverse'}}}])
    assert changed.edges[0].style.color_mode=='inverse'

@pytest.mark.parametrize('icon',sorted(icon_library()))
@pytest.mark.parametrize('alpha',['FF','80','00'])
def test_every_figure_fills_bodies_once_then_recolors_every_semantic_stroke(icon,alpha):
    project=DiagramProject.model_validate({'nodes':[{'id':'figure','label':'X','icon':icon,
        'style':{'fill':'#12AB34'+alpha,'stroke':'#EF5612'+alpha,'text':'#123456'}}]})
    svg=render_svg(project)[0];root=ET.fromstring(svg)
    group=next(e for e in root.iter() if e.get('data-node')=='figure')
    fills=[e for e in group if e.get('data-node-fill')];strokes=[e for e in group if e.get('data-node-stroke')]
    geometry=icon_library()[icon]
    assert len(strokes)==len(geometry['paths'])
    assert len(fills)==bool(geometry['fill_paths'])
    assert all(e.get('fill')=='none' and e.get('stroke')=='#EF5612' for e in strokes)
    assert all(float(e.get('stroke-opacity'))==pytest.approx(int(alpha,16)/255,abs=.0001) for e in strokes)
    if fills:
        assert fills[0].get('fill')=='#12AB34' and fills[0].get('fill-rule')=='nonzero'
        assert float(fills[0].get('fill-opacity'))==pytest.approx(int(alpha,16)/255,abs=.0001)
        assert list(group).index(fills[0]) < min(list(group).index(e) for e in strokes)
        assert fills[0].get('d').count('M ')==len(geometry['fill_paths'])
    assert svg==render_svg(project)[0]

def test_fill_metadata_reproducible_positive_winding_and_wires_not_filled():
    path=ROOT/'scripts/generate_icon_geometry.py'
    function=next(n for n in ast.parse(path.read_text()).body if isinstance(n,ast.FunctionDef) and n.name=='fill_contours')
    scope={'math':math};exec(compile(ast.Module(body=[function],type_ignores=[]),str(path),'exec'),scope)
    for name,geometry in icon_library().items():
        assert geometry['fill_paths']==scope['fill_contours'](geometry['paths'],geometry['closed'],name)
        for contour in geometry['fill_paths']:
            area=sum(a[0]*b[1]-b[0]*a[1] for a,b in zip(contour,contour[1:]+contour[:1]))/2
            assert area>0,(name,area)
            assert all(-.001<=p[0]<=1.001 and -.001<=p[1]<=1.001 for p in contour)
    for name in ['lucide/icons/git-branch.svg','lucide/icons/workflow.svg','tabler-icons/outline/load-balancer.svg']:
        g=icon_library()[name]
        assert len(g['fill_paths'])==sum(g['closed']),name
    assert not icon_library()['lucide/icons/activity.svg']['fill_paths']
    assert not icon_library()['tabler-icons/outline/brand-aws.svg']['fill_paths']

def test_project_palette_validation_and_legacy_default():
    project=new_project();assert project.presentation.saved_colors==[]
    data=project.model_dump();data['presentation']['saved_colors']=['#11223380','#11223380','#abcdef']
    assert DiagramProject.model_validate(data).presentation.saved_colors==['#11223380','#ABCDEF']
    for colors in [['bad'], ['#000000']*65]:
        data['presentation']['saved_colors']=colors
        with pytest.raises(ValidationError):DiagramProject.model_validate(data)
