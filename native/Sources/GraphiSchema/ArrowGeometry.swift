import AppKit

struct ArrowMarkerGeometry {
    let kind: String
    let tip: NSPoint
    let base: NSPoint
    let guide: NSPoint
    let unit: NSPoint
    let scale: CGFloat

    func point(_ along: CGFloat, _ across: CGFloat = 0) -> NSPoint {
        NSPoint(x: tip.x-along*scale*unit.x+across*scale*unit.y,
                y: tip.y-along*scale*unit.y-across*scale*unit.x)
    }

    var polygon: [NSPoint] {
        switch kind {
        case "diamond": return [tip, point(4, 3), point(8), point(4, -3)]
        case "box": return [point(0, 3), point(6, 3), point(6, -3), point(0, -3)]
        case "tee": return [point(0, 4), point(0, -4)]
        case "vee", "crow": return [point(8, 4), tip, point(8, -4)]
        default: return [tip, point(8, 4), point(8, -4)]
        }
    }
}

struct EdgeDrawingGeometry {
    let shaft: [NSPoint]
    let head: ArrowMarkerGeometry?
    let tail: ArrowMarkerGeometry?
}

enum ArrowGeometry {
    private static let epsilon: CGFloat = 1e-9
    private static let depths: [String: CGFloat] = ["normal": 8, "diamond": 8, "box": 6, "dot": 6, "tee": 0, "vee": 8, "crow": 8]

    static func make(_ input: [NSPoint], head: String = "normal", tail: String = "none", lineWidth: CGFloat = 2,
                     markerScale: CGFloat = 1) -> EdgeDrawingGeometry {
        let points = clean(input)
        guard points.count >= 2 else { return EdgeDrawingGeometry(shaft: points, head: nil, tail: nil) }
        let total = zip(points, points.dropFirst()).reduce(CGFloat.zero) { $0 + distance($1.0, $1.1) }
        let count = (head == "none" ? 0 : 1)+(tail == "none" ? 0 : 1)
        guard count > 0 else { return EdgeDrawingGeometry(shaft: points, head: nil, tail: nil) }
        let budget = total * (count == 2 ? 0.45 : 0.9)
        let end = head == "none" ? nil : marker(points, kind: head, budget: budget, lineWidth: lineWidth, sizeScale: markerScale)
        let start = tail == "none" ? nil : marker(Array(points.reversed()), kind: tail, budget: budget, lineWidth: lineWidth, sizeScale: markerScale)
        let endCut = end?.cut ?? 0, startCut = start?.cut ?? 0
        let withoutEnd = prefix(points, length: total-endCut)
        let middle = Array(prefix(Array(withoutEnd.reversed()), length: total-endCut-startCut).reversed())
        let shaft = clean((start.map { [$0.marker.base, $0.marker.guide] } ?? []) + middle
                          + (end.map { [$0.marker.guide, $0.marker.base] } ?? []))
        return EdgeDrawingGeometry(shaft: shaft, head: end?.marker, tail: start?.marker)
    }

    private static func marker(_ points: [NSPoint], kind: String, budget: CGFloat, lineWidth: CGFloat, sizeScale: CGFloat) -> (marker: ArrowMarkerGeometry, cut: CGFloat)? {
        let tip = points[points.count-1], previous = points[points.count-2]
        let length = distance(tip, previous)
        let unit = NSPoint(x: (tip.x-previous.x)/length, y: (tip.y-previous.y)/length)
        let local = prefix(Array(points.reversed()), length: budget)
        func back(_ p: NSPoint) -> CGFloat { (tip.x-p.x)*unit.x+(tip.y-p.y)*unit.y }
        let grow = max(1, lineWidth/2)*max(0.1, sizeScale)
        let depth = (depths[kind] ?? 8)*grow, lead = max(4, lineWidth*2)
        let offset = min(depth+lead, (local.map(back).max() ?? 0)*0.9)
        let factor = offset/(depth+lead)
        let guide = NSPoint(x: tip.x-offset*unit.x, y: tip.y-offset*unit.y)
        let base = NSPoint(x: tip.x-depth*factor*unit.x, y: tip.y-depth*factor*unit.y)
        var consumed: CGFloat = 0
        for (a, b) in zip(local, local.dropFirst()) {
            let da = back(a), db = back(b)
            if db >= offset && db-da > epsilon {
                let t = (offset-da)/(db-da)
                let marker = ArrowMarkerGeometry(kind: kind, tip: tip, base: base, guide: guide, unit: unit, scale: grow*factor)
                return (marker, consumed+t*distance(a, b))
            }
            consumed += distance(a, b)
        }
        return nil
    }

    private static func prefix(_ points: [NSPoint], length: CGFloat) -> [NSPoint] {
        var result = [points[0]], remaining = max(0, length)
        for (a, b) in zip(points, points.dropFirst()) {
            let segment = distance(a, b)
            if remaining <= segment {
                let t = remaining/segment
                return clean(result+[NSPoint(x: a.x+t*(b.x-a.x), y: a.y+t*(b.y-a.y))])
            }
            result.append(b)
            remaining -= segment
        }
        return result
    }

    private static func clean(_ points: [NSPoint]) -> [NSPoint] {
        points.reduce(into: []) { result, point in
            if let last = result.last, distance(last, point) <= epsilon { return }
            result.append(point)
        }
    }

    private static func distance(_ a: NSPoint, _ b: NSPoint) -> CGFloat { hypot(a.x-b.x, a.y-b.y) }
}
