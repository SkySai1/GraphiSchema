"""Renderer-only crossing bridges; routes and arrow tangents stay unchanged."""
import bisect
import math


def bridged_path(points, lower_paths, radius=5):
    if len(points) < 2 or not lower_paths:
        return points
    distances = [0.0]
    for a, b in zip(points, points[1:]):
        distances.append(distances[-1]+math.dist(a, b))
    crossings = []
    for index, (a, b) in enumerate(zip(points, points[1:])):
        dx, dy = b[0]-a[0], b[1]-a[1]
        length = math.hypot(dx, dy)
        if length < 1e-8:
            continue
        for lower in lower_paths:
            for lower_index, (c, d) in enumerate(zip(lower, lower[1:])):
                if max(a[0],b[0])+1e-8 < min(c[0],d[0]) or min(a[0],b[0])-1e-8 > max(c[0],d[0]) or max(a[1],b[1])+1e-8 < min(c[1],d[1]) or min(a[1],b[1])-1e-8 > max(c[1],d[1]):
                    continue
                sx, sy = d[0]-c[0], d[1]-c[1]
                det = dx*sy-dy*sx
                if abs(det) < 1e-9:
                    continue
                t = ((c[0]-a[0])*sy-(c[1]-a[1])*sx)/det
                u = ((c[0]-a[0])*dy-(c[1]-a[1])*dx)/det
                if -1e-8 <= t <= 1+1e-8 and -1e-8 <= u <= 1+1e-8:
                    if not _straddles(points, index, t, c, d) or not _straddles(lower, lower_index, u, a, b):
                        continue
                    distance = distances[index]+max(0, min(1, t))*length
                    if radius*2 < distance < distances[-1]-radius*2:
                        crossings.append(distance)
    unique = []
    for distance in sorted(crossings):
        if not unique or distance-unique[-1] > radius*2.5:
            unique.append(distance)
    def sample(distance):
        index = min(len(points)-2, max(0, bisect.bisect_right(distances, distance)-1))
        a, b = points[index:index+2]
        length = distances[index+1]-distances[index]
        t = (distance-distances[index])/length if length else 0
        return a[0]+(b[0]-a[0])*t, a[1]+(b[1]-a[1])*t
    result, cursor = [], 0
    for distance in unique:
        start, end = distance-radius, distance+radius
        a, b = sample(start), sample(end)
        dx, dy = b[0]-a[0], b[1]-a[1]
        length = math.hypot(dx, dy)
        if length < radius:
            continue
        while cursor < len(points) and distances[cursor] < start:
            result.append(points[cursor]); cursor += 1
        nx, ny = -dy/length, dx/length
        # Deterministic arch side independent of source/target direction.
        if ny > 1e-8 or (abs(ny)<1e-8 and nx<0): nx, ny = -nx, -ny
        for step in range(17):
            t = step/16
            base = sample(start+(end-start)*t)
            offset = radius*math.sin(math.pi*t)**2
            result.append((base[0]+nx*offset, base[1]+ny*offset))
        while cursor < len(points) and distances[cursor] <= end:
            cursor += 1
    return result+points[cursor:]


def _straddles(path, index, t, a, b):
    """At polyline vertices, distinguish a crossing from a tangential touch."""
    before = path[index-1] if t <= 1e-8 and index > 0 else path[index]
    after = path[index+2] if t >= 1-1e-8 and index+2 < len(path) else path[index+1]
    def side(p): return (b[0]-a[0])*(p[1]-a[1])-(b[1]-a[1])*(p[0]-a[0])
    return side(before)*side(after) < -1e-12
