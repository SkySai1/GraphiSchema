# /// script
# dependencies = ["svgpathtools>=1.7,<2"]
# ///
"""Build shared vector contours from the vendored, licensed SVG collections.

Run with uv run scripts/generate_icon_geometry.py. Runtime has no SVG parser dependency.
Coordinates are normalized to [0,1], with Y pointing up, as on the native canvas.
"""
import json
import math
from pathlib import Path

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


result = {}
for file in sorted(LIBRARY.glob("*/*/*.svg")):
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
        "vertices": hull([tuple(p) for stroke in strokes for p in stroke]),
    }
destination = ROOT / "backend/graphischema/resources/icon_geometry.json"
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n")
print(f"Prepared vector contours for {len(result)} icons: {destination}")
