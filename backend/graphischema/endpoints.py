"""Adapters for node and cluster connection endpoints; IDs stay canonical."""
import hashlib
from types import SimpleNamespace


def container_anchor_ids(project):
    referenced = {key for edge in project.edges for key in (edge.source, edge.target)}
    used = {item.id for item in [*project.nodes, *project.containers, *project.edges]}
    result = {}
    for container in project.containers:
        if container.id not in referenced:
            continue
        value = "gsAnchor_"+hashlib.sha256(container.id.encode()).hexdigest()[:20]
        while value in used:
            value += "x"
        used.add(value)
        result[container.id] = value
    return result


def container_figure(container):
    return SimpleNamespace(id=container.id, icon=None, shape="box", rotation=0, kind="__container_endpoint")


def endpoint_geometries(project, layout):
    from .container_layout import container_rects
    figures = {node.id: node for node in project.nodes}
    positions = {node["id"]: node for node in layout["nodes"]}
    bounds = container_rects(project, layout)
    for container in project.containers:
        left,bottom,right,top = bounds[container.id]
        figures[container.id] = container_figure(container)
        positions[container.id] = {"id":container.id,"x":(left+right)/2,"y":(bottom+top)/2,"width":right-left,"height":top-bottom}
    return figures, positions
