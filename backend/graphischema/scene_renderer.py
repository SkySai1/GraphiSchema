"""SVG scene built from the same normalized geometry and icon vectors as AppKit."""
import html
import math

from .geometry import icon_library, normalized_paths


def render_scene(project, layout, background=None):
    pad = 28
    width, height = max(1, layout["width"]*72+pad*2), max(1, layout["height"]*72+pad*2+20)
    def point(x, y):
        return (x-layout["minX"])*72+pad, (layout["minY"]+layout["height"]-y)*72+pad
    def data(points, closed=False):
        return "M " + " L ".join(f"{x:.4f} {y:.4f}" for x, y in points) + (" Z" if closed else "")
    dark = project.presentation.theme == "dark"
    canvas = background or ("#21172F" if dark else project.presentation.background)
    if background and background != "transparent":
        red, green, blue = (int(background[i:i+2], 16)/255 for i in (1, 3, 5))
        dark = .2126*red+.7152*green+.0722*blue < .5
    text = "#FFFFFF" if dark else "#172238"
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:.4f}pt" height="{height:.4f}pt" viewBox="0 0 {width:.4f} {height:.4f}">']
    if canvas != "transparent":
        out.append(f'<rect width="100%" height="100%" fill="{canvas}"/>')
    positions = {n["id"]: n for n in layout["nodes"]}
    containers = {c.id: c for c in project.containers}
    members = {c.id: [] for c in project.containers}
    for node in project.nodes:
        current = node.container_id
        while current:
            members[current].append(positions[node.id])
            current = containers[current].parent_id
    def depth(container):
        current, result = container.parent_id, 0
        while current:
            result += 1
            current = containers[current].parent_id
        return result
    for c in sorted(project.containers, key=depth):
        group = members[c.id]
        if not group:
            continue
        left = min(n["x"]-n["width"]/2 for n in group)-c.padding/72
        right = max(n["x"]+n["width"]/2 for n in group)+c.padding/72
        bottom = min(n["y"]-n["height"]/2 for n in group)-c.padding/72
        top = max(n["y"]+n["height"]/2 for n in group)+c.padding/72
        x, y = point(left, top)
        out.append(f'<rect x="{x:.4f}" y="{y:.4f}" width="{(right-left)*72:.4f}" height="{(top-bottom)*72:.4f}" rx="11" fill="{c.style.fill}" fill-opacity="0.42" stroke="{c.style.stroke}" stroke-width="1.2"/>')
        out.append(f'<text x="{x+10:.4f}" y="{y+17:.4f}" fill="{c.style.text}" font-family="Arial,sans-serif" font-size="11">{html.escape(c.label)}</text>')
    edges = {e.id: e for e in project.edges}
    for g in layout["edges"]:
        edge = edges[g["id"]]
        points = [point(p["x"], p["y"]) for p in g["points"]]
        if len(points) < 2:
            continue
        style = edge.style
        dash = {"dashed": ' stroke-dasharray="6 4"', "dotted": ' stroke-dasharray="1.5 3"'}.get(style.line_style, "")
        out.append(f'<path data-edge="{edge.id}" d="{data(points)}" fill="none" stroke="{style.color}" stroke-width="{style.penwidth}" stroke-linecap="round" stroke-linejoin="round"{dash}/>')
        for tip, previous, kind in ([(points[-1], points[-2], style.arrowhead)] if edge.direction in {"forward", "both"} else []) + ([(points[0], points[1], style.arrowtail)] if edge.direction == "both" else []):
            if kind == "none":
                continue
            angle = math.atan2(tip[1]-previous[1], tip[0]-previous[0])
            def arrow_point(along, across):
                return tip[0]-along*math.cos(angle)+across*math.sin(angle), tip[1]-along*math.sin(angle)-across*math.cos(angle)
            if kind == "dot":
                x, y = arrow_point(3, 0)
                out.append(f'<circle cx="{x:.4f}" cy="{y:.4f}" r="3" fill="{style.color}"/>')
            else:
                polygon = [tip, arrow_point(8, 4), arrow_point(8, -4)]
                if kind == "diamond":
                    polygon = [tip, arrow_point(4, 3), arrow_point(8, 0), arrow_point(4, -3)]
                elif kind == "box":
                    polygon = [arrow_point(0, 3), arrow_point(6, 3), arrow_point(6, -3), arrow_point(0, -3)]
                elif kind == "tee":
                    polygon = [arrow_point(0, 4), arrow_point(0, -4)]
                elif kind in {"vee", "crow"}:
                    polygon = [arrow_point(8, 4), tip, arrow_point(8, -4)]
                closed = kind not in {"tee", "vee", "crow"}
                out.append(f'<path d="{data(polygon, closed)}" fill="{style.color if closed else "none"}" stroke="{style.color}" stroke-width="1.5"/>')
        if edge.label:
            x, y = point(g["labelX"] or 0, g["labelY"] or 0)
            out.append(f'<text x="{x:.4f}" y="{y:.4f}" text-anchor="middle" fill="{text}" font-family="Arial,sans-serif" font-size="10">{html.escape(edge.label)}</text>')
    for node in project.nodes:
        n = positions[node.id]
        paths = normalized_paths(node)
        closed = icon_library()[node.icon]["closed"] if node.icon else [True]+[False]*(len(paths)-1)
        out.append(f'<g data-node="{node.id}"' + (f' data-icon="{node.icon}"' if node.icon else "") + ">")
        for path, close in zip(paths, closed):
            points = [point(n["x"]+(x-.5)*n["width"], n["y"]+(y-.5)*n["height"]) for x, y in path]
            out.append(f'<path d="{data(points, close)}" fill="{node.style.fill if close else "none"}" stroke="{node.style.stroke}" stroke-width="{node.style.penwidth}" stroke-linecap="round" stroke-linejoin="round"/>')
        x, y = point(n["x"], n["y"]-n["height"]/2) if node.icon else point(n["x"], n["y"])
        label_color = "#FFFFFF" if node.icon and dark and node.style.text in {"#172238", "#0F172A"} else node.style.text
        out.append(f'<text x="{x:.4f}" y="{y+(16 if node.icon else 4):.4f}" text-anchor="middle" fill="{label_color}" font-family="Arial,sans-serif" font-size="11" font-weight="600">{html.escape(node.label)}</text></g>')
    out.append("</svg>")
    return "\n".join(out)
