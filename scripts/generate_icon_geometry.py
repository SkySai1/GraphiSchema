# /// script
# dependencies = ["svgpathtools>=1.7,<2"]
# ///
"""Build shared vector contours from the vendored, licensed SVG collections.

Run with uv run scripts/generate_icon_geometry.py. Runtime has no SVG parser dependency.
Coordinates are normalized to [0,1], with Y pointing up, as on the native canvas.
"""
import json
import math
import sys
from pathlib import Path

if "--fills-only" not in sys.argv:
    from svgpathtools import svg2paths2

ROOT = Path(__file__).resolve().parents[1]
LIBRARY = ROOT / "resources/object-library"


def hull(points):
    points = sorted(set(points))
    def cross(a, b, c):
        return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])
    sides = []
    for sequence in (points, points[::-1]):
        side = []
        for point in sequence:
            while len(side) > 1 and cross(side[-2], side[-1], point) <= 0:
                side.pop()
            side.append(point)
        sides.extend(side[:-1])
    # Keep corners and a small number of curved boundary vertices for attachment controls.
    changed = True
    while changed and len(sides) > 4:
        changed = False
        for i, b in enumerate(sides):
            a, c = sides[i-1], sides[(i+1) % len(sides)]
            if abs(cross(a, b, c)) / max(math.dist(a, c), 1e-9) < .008:
                sides.pop(i)
                changed = True
                break
    return sides


def fill_contours(strokes, closed, name):
    """Paint all component bodies once, then paint every original semantic stroke.

    Outline icon sets deliberately leave some bodies open (building baseline,
    server/cog, cloud/cog, API lobes). Close their curved/area-bearing contours
    for the fill pass only. Pure wires, ticks and activity traces have no body.
    All contours wind the same way so translucent overlaps are filled once.
    """
    open_bodies = {
        "lucide/icons/blocks.svg": {0}, "lucide/icons/cloud-cog.svg": {2,3,6},
        "lucide/icons/database.svg": {0}, "lucide/icons/lock.svg": {0},
        "lucide/icons/server-cog.svg": {1,3,6,7}, "lucide/icons/user-round.svg": {0},
        "tabler-icons/outline/api-app.svg": {0,1,2,3}, "tabler-icons/outline/building.svg": {7},
        "tabler-icons/outline/database.svg": {1,2}, "tabler-icons/outline/lock.svg": {2},
        "tabler-icons/outline/users.svg": {1,2,3},
    }
    fills = []
    for index, (points, is_closed) in enumerate(zip(strokes, closed)):
        signed = sum(a[0]*b[1]-b[0]*a[1] for a,b in zip(points, points[1:]+points[:1]))/2
        if is_closed or index in open_bodies.get(name, set()):
            if abs(signed) > 1e-6: fills.append(points if signed > 0 else list(reversed(points)))
    if name == "tabler-icons/outline/api-app.svg":
        # The four interlocking open lobes enclose a central application body.
        fills.append([[.3125,.3125],[.6875,.3125],[.6875,.6875],[.3125,.6875]])
    if name == "lucide/icons/webhook.svg":
        for cx,cy in [(6,17),(12,6),(18,17)]:
            circle = [[(cx+4*math.cos(i*math.tau/64)-2)/20, (21-cy-4*math.sin(i*math.tau/64))/19] for i in range(65)]
            fills.append(list(reversed(circle)))
    if name == "tabler-icons/outline/database-export.svg":
        body = [[0,16/19],[0,4/19]]
        body += [[(12+8*math.cos(math.pi-i*math.pi/32)-4)/18, (22-18-3*math.sin(math.pi-i*math.pi/32))/19] for i in range(33)]
        body += [[16/18,16/19]]
        fills.append(body)
    return [p if sum(a[0]*b[1]-b[0]*a[1] for a,b in zip(p,p[1:]+p[:1])) > 0 else list(reversed(p)) for p in fills]


destination = ROOT / "backend/graphischema/resources/icon_geometry.json"
result = json.loads(destination.read_text()) if "--fills-only" in sys.argv else {}
for file in ([] if "--fills-only" in sys.argv else sorted(LIBRARY.glob("*/*/*.svg"))):
    paths, _, _ = svg2paths2(file)
    paths = [part for path in paths for part in path.continuous_subpaths() if part.length() > .02]
    bounds = [path.bbox() for path in paths]
    left, right = min(b[0] for b in bounds), max(b[1] for b in bounds)
    bottom, top = min(b[2] for b in bounds), max(b[3] for b in bounds)
    strokes = []
    closed = []
    for path in paths:
        samples = []
        for segment in path:
            count = max(1, min(100, math.ceil(segment.length() / .3)))
            samples.extend(segment.point(i/count) for i in range(count))
        samples.append(path[-1].end)
        strokes.append([[round((p.real-left)/(right-left), 6), round((top-p.imag)/(top-bottom), 6)] for p in samples])
        closed.append(abs(path.start-path.end) < .05)
    result[file.relative_to(LIBRARY).as_posix()] = {
        "aspect_ratio": round((right-left)/(top-bottom), 6),
        "paths": strokes, "closed": closed,
        "fill_paths": fill_contours(strokes, closed, file.relative_to(LIBRARY).as_posix()),
        "vertices": hull([tuple(p) for stroke in strokes for p in stroke]),
    }
for name, geometry in result.items():
    geometry["fill_paths"] = fill_contours(geometry["paths"], geometry["closed"], name)
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n")
print(f"Prepared vector contours for {len(result)} icons: {destination}")
