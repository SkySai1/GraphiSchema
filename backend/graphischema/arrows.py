"""Build a shaft and its markers together, in final renderer coordinates.

Tips stay on the node contours. The shaft stops at the centre of each marker's
rear edge and has a straight lead into it, even when the original last segment
is shorter than the head or the route curves around an endpoint.
"""
from dataclasses import dataclass
import math

EPSILON = 1e-9
DEPTHS = {"normal": 8, "diamond": 8, "box": 6, "dot": 6, "tee": 0, "vee": 8, "crow": 8}


@dataclass
class ArrowMarker:
    kind: str
    tip: tuple
    base: tuple
    guide: tuple
    unit: tuple
    scale: float

    def point(self, along, across=0):
        ux, uy = self.unit
        return (self.tip[0]-along*self.scale*ux+across*self.scale*uy,
                self.tip[1]-along*self.scale*uy-across*self.scale*ux)

    @property
    def polygon(self):
        if self.kind == "diamond":
            return [self.tip, self.point(4, 3), self.point(8), self.point(4, -3)]
        if self.kind == "box":
            return [self.point(0, 3), self.point(6, 3), self.point(6, -3), self.point(0, -3)]
        if self.kind == "tee":
            return [self.point(0, 4), self.point(0, -4)]
        if self.kind in {"vee", "crow"}:
            return [self.point(8, 4), self.tip, self.point(8, -4)]
        return [self.tip, self.point(8, 4), self.point(8, -4)]


@dataclass
class ArrowDrawing:
    shaft: list
    head: ArrowMarker | None
    tail: ArrowMarker | None


def _clean(points):
    result = []
    for p in points:
        if not result or math.dist(result[-1], p) > EPSILON:
            result.append(tuple(p))
    return result


def _prefix(points, length):
    """An exact arc-length cut, including a point interpolated on its segment."""
    result = [points[0]]
    for a, b in zip(points, points[1:]):
        distance = math.dist(a, b)
        if length <= distance:
            t = length/distance
            return _clean([*result, (a[0]+t*(b[0]-a[0]), a[1]+t*(b[1]-a[1]))])
        result.append(b)
        length -= distance
    return result


def _marker(points, kind, budget, line_width):
    tip, previous = points[-1], points[-2]
    distance = math.dist(tip, previous)
    unit = (tip[0]-previous[0])/distance, (tip[1]-previous[1])/distance
    local = _prefix(points[::-1], budget)
    back = lambda p: (tip[0]-p[0])*unit[0]+(tip[1]-p[1])*unit[1]
    # Reserve a straight lead as well as the head. Reduce both together on a
    # short edge; independently sizing two heads would make them overlap.
    grow = max(1, line_width/2)
    depth, lead = DEPTHS[kind]*grow, max(4, line_width*2)
    offset = min(depth+lead, max(back(p) for p in local)*.9)
    factor = offset/(depth+lead)
    scale = grow*factor
    guide = (tip[0]-offset*unit[0], tip[1]-offset*unit[1])
    base = (tip[0]-depth*factor*unit[0], tip[1]-depth*factor*unit[1])
    consumed = 0.0
    for a, b in zip(local, local[1:]):
        da, db = back(a), back(b)
        if db >= offset and db-da > EPSILON:
            t = (offset-da)/(db-da)
            cut = a[0]+t*(b[0]-a[0]), a[1]+t*(b[1]-a[1])
            return ArrowMarker(kind, tip, base, guide, unit, scale), cut, consumed+t*math.dist(a, b)
        consumed += math.dist(a, b)
    raise ValueError("Arrow lead has no intersection with its route")


def arrow_drawing(points, head_kind="normal", tail_kind="none", line_width=2):
    points = _clean(points)
    if len(points) < 2:
        return ArrowDrawing(points, None, None)
    total = sum(math.dist(a, b) for a, b in zip(points, points[1:]))
    count = int(head_kind != "none")+int(tail_kind != "none")
    if not count:
        return ArrowDrawing(points, None, None)
    budget = total*(.45 if count == 2 else .9)
    head = tail = None
    head_cut = tail_cut = 0.0
    if head_kind != "none":
        head, _, head_cut = _marker(points, head_kind, budget, line_width)
    if tail_kind != "none":
        tail, _, tail_cut = _marker(points[::-1], tail_kind, budget, line_width)
    middle = _prefix(_prefix(points, total-head_cut)[::-1], total-head_cut-tail_cut)[::-1]
    shaft = _clean(([tail.base, tail.guide] if tail else []) + middle + ([head.guide, head.base] if head else []))
    return ArrowDrawing(shaft, head, tail)
