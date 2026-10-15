"""Independent curve tangent and arrow joins across ports, quadrants and engines."""
import math
import pytest
from graphischema.geometry import attachment, smooth_route
from graphischema.layout import compute_layout
from graphischema.arrows import arrow_drawing
from graphischema.models import DiagramProject

PORTS=['n','ne','e','se','s','sw','w','nw','vertex:0','vertex:2']

def cosine(a,b):return sum(x*y for x,y in zip(a,b))/(math.hypot(*a)*math.hypot(*b))

@pytest.mark.parametrize('source_port',PORTS)
@pytest.mark.parametrize('target_port',PORTS)
@pytest.mark.parametrize('target_center',[(4,2),(-4,2),(4,-2),(-4,-2)])
def test_curves_start_at_boundary_and_turn_continuously_without_a_stub(source_port,target_port,target_center):
    project=DiagramProject.model_validate({'diagram':{'layout_mode':'manual','edge_routing':'curved'},
        'nodes':[{'id':'a','label':'A','x':0,'y':0,'width':1.4,'height':1},{'id':'b','label':'B','x':target_center[0],'y':target_center[1],'width':1.4,'height':1}],
        'edges':[{'id':'ab','source':'a','target':'b','source_port':source_port,'target_port':target_port}]})
    layout=compute_layout(project);nodes={n['id']:n for n in layout['nodes']}
    points=[(p['x'],p['y']) for p in layout['edges'][0]['points']]
    assert len(points)==97
    for index,(port,center,node) in enumerate([(source_port,(0,0),project.nodes[0]),(target_port,target_center,project.nodes[1])]):
        tip,next=points[:2] if index==0 else (points[-1],points[-2])
        assert tip==pytest.approx(attachment(node,nodes[node.id],target_center if index==0 else (0,0),port))
        normal=(tip[0]-center[0],tip[1]-center[1]);delta=(next[0]-tip[0],next[1]-tip[1])
        assert cosine(normal,delta)>.985
    # Verify the rendered shaft reaches the REAR of each marker on its own axis.
    drawing=arrow_drawing([(x*72,y*72) for x,y in points],'normal','normal')
    for marker,shaft_end in [(drawing.head,drawing.shaft[-1]),(drawing.tail,drawing.shaft[0])]:
        assert shaft_end==pytest.approx(marker.base)
        assert cosine((marker.tip[0]-marker.base[0],marker.tip[1]-marker.base[1]),marker.unit)>.999999

@pytest.mark.parametrize('engine',['dot','neato','fdp','sfdp','twopi','circo'])
@pytest.mark.parametrize('routing',['curved','orthogonal'])
def test_fixed_vertex_routes_work_for_every_engine(engine,routing):
    project=DiagramProject.model_validate({'diagram':{'layout_engine':engine},'nodes':[{'id':'a','label':'A','shape':'diamond'},{'id':'b','label':'B','shape':'hexagon'}],
        'edges':[{'id':'ab','source':'a','target':'b','routing':routing,'source_port':'vertex:0','target_port':'vertex:2'}]})
    layout=compute_layout(project);points=[(p['x'],p['y']) for p in layout['edges'][0]['points']]
    assert all(math.isfinite(c) for p in points for c in p)
    if routing=='orthogonal':assert all(abs(a[0]-b[0])<1e-8 or abs(a[1]-b[1])<1e-8 for a,b in zip(points,points[1:]))
    else:assert len(points)==97

def test_curve_waypoints_have_shared_derivatives_and_no_zero_segments():
    anchors=[(0,0),(1,2),(3,1),(5,3)]
    points=smooth_route(anchors)
    assert len(points)==289 and [points[i] for i in (0,96,192,288)]==anchors
    for index in (96,192):
        before,at,after=points[index-1:index+2]
        assert cosine((at[0]-before[0],at[1]-before[1]),(after[0]-at[0],after[1]-at[1]))>.995
    assert smooth_route([(1,1),(1,1)])==[(1,1)]
