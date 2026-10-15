"""Container envelopes and fixed title metrics shared by all SVG exports.

The native equivalent is DiagramContainerLayout.swift. Layout coordinates are
in inches; title metrics are in points and do not depend on content padding.
"""
from collections import defaultdict
from .geometry import node_bounds

FONT_SIZE = 11
HEADER_HEIGHT = 28
LABEL_HEIGHT = 16
LABEL_INSET_X = 10
LABEL_INSET_TOP = 6
MIN_WIDTH = 32
MIN_EMPTY_HEIGHT = 36


def container_rects(project, layout):
    """Return (left, bottom, right, top), including nested and empty children."""
    containers = {item.id: item for item in project.containers}
    positions = {item["id"]: item for item in layout["nodes"]}
    previous = {item["id"]: item for item in layout.get("containers", [])}
    children = defaultdict(list)
    members = defaultdict(list)
    for item in project.containers:
        if item.parent_id in containers:
            children[item.parent_id].append(item.id)
    for node in project.nodes:
        if node.container_id in containers and node.id in positions:
            point = positions[node.id]
            members[node.container_id].append(node_bounds(node, point))
    result = {}

    def envelope(container_id):
        if container_id in result:
            return result[container_id]
        container = containers[container_id]
        contents = members[container_id] + [envelope(child) for child in children[container_id]]
        if contents:
            padding = container.padding/72
            left = min(rect[0] for rect in contents)-padding
            bottom = min(rect[1] for rect in contents)-padding
            right = max(rect[2] for rect in contents)+padding
            top = max(rect[3] for rect in contents)+padding+HEADER_HEIGHT/72
        else:
            saved = previous.get(container_id, {})
            x = container.x if container.x is not None else saved.get("x", layout["minX"]+1.6)
            y = container.y if container.y is not None else saved.get("y", layout["minY"]+1.2)
            width, height = max(container.width, MIN_WIDTH/72), max(container.height, MIN_EMPTY_HEIGHT/72)
            left, bottom, right, top = x-width/2, y-height/2, x+width/2, y+height/2
        if right-left < MIN_WIDTH/72:
            center = (left+right)/2
            left, right = center-MIN_WIDTH/144, center+MIN_WIDTH/144
        result[container_id] = left, bottom, right, top
        return result[container_id]

    for item in project.containers:
        envelope(item.id)
    return result
