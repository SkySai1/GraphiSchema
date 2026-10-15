import AppKit

struct IconGeometry: Decodable {
    let aspectRatio: Double
    let paths: [[[Double]]]
    let closed: [Bool]
    let vertices: [[Double]]
    let fillPaths: [[[Double]]]?
}

enum ProjectResources {
    static func data(_ relative: String) -> Data? {
        var roots = PaletteObject.objectLibraryRoots().map { $0.deletingLastPathComponent().deletingLastPathComponent() }
        if let bundle = Bundle.main.resourceURL { roots.insert(bundle.appendingPathComponent("GraphiSchema"), at: 0) }
        return roots.lazy.compactMap { try? Data(contentsOf: $0.appendingPathComponent(relative)) }.first
    }
    static let graphvizDeclaration = data("backend/graphischema/resources/graphviz_attributes.txt")
        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
}

enum CanvasGeometry {
    private static let thumbnailCache = NSCache<NSString, NSImage>()
    static let icons: [String: IconGeometry] = ProjectResources.data("backend/graphischema/resources/icon_geometry.json")
        .flatMap { data in
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try? decoder.decode([String: IconGeometry].self, from: data)
        } ?? [:]

    static func iconSize(_ icon: String, extent: Double = 1.1) -> (width: Double, height: Double) {
        let aspect = icons[icon]?.aspectRatio ?? 1
        let width = aspect >= 1 ? extent : extent*aspect
        let height = aspect >= 1 ? extent/aspect : extent
        let factor = max(1, 0.5/min(width, height))
        return (width*factor, height*factor)
    }

    static func thumbnail(icon: String) -> NSImage? {
        if let cached = thumbnailCache.object(forKey: icon as NSString) { return cached }
        guard let geometry = icons[icon] else { return nil }
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
            NSColor.labelColor.setStroke()
            for contour in geometry.paths {
                let path = NSBezierPath()
                let aspect = geometry.aspectRatio
                let width = aspect >= 1 ? rect.width-4 : (rect.width-4)*aspect
                let height = aspect >= 1 ? (rect.height-4)/aspect : rect.height-4
                let points = contour.map { NSPoint(x: rect.midX-width/2+$0[0]*width, y: rect.midY-height/2+$0[1]*height) }
                if let first = points.first {
                    path.move(to: first); for point in points.dropFirst() { path.line(to: point) }
                    path.lineWidth = 1.3; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        thumbnailCache.setObject(image, forKey: icon as NSString)
        return image
    }

    static func paths(_ node: DiagramNode) -> [[NSPoint]] {
        if let icon = node.icon, let geometry = icons[icon] {
            return geometry.paths.map { $0.map { NSPoint(x: $0[0], y: $0[1]) } }
        }
        if ["ellipse", "cloud"].contains(node.shape) {
            return [(0...64).map { i in NSPoint(x: 0.5 + 0.5*cos(Double(i)*2 * .pi/64), y: 0.5 + 0.5*sin(Double(i)*2 * .pi/64)) }]
        }
        if node.shape == "cylinder" {
            let top = (0...32).map { i in NSPoint(x: 0.5+0.5*cos(Double(i) * .pi/32), y: 0.88+0.12*sin(Double(i) * .pi/32)) }
            let bottom = (0...32).map { i in NSPoint(x: 0.5+0.5*cos(.pi+Double(i) * .pi/32), y: 0.12+0.12*sin(.pi+Double(i) * .pi/32)) }
            let ellipse = (0...64).map { i in NSPoint(x: 0.5+0.5*cos(Double(i)*2 * .pi/64), y: 0.88+0.12*sin(Double(i)*2 * .pi/64)) }
            return [top+bottom+[top[0]], ellipse]
        }
        let vertices: [NSPoint]
        switch node.shape {
        case "diamond": vertices = [.init(x: 0, y: 0.5), .init(x: 0.5, y: 0), .init(x: 1, y: 0.5), .init(x: 0.5, y: 1)]
        case "hexagon": vertices = [.init(x: 0, y: 0.5), .init(x: 0.16, y: 0), .init(x: 0.84, y: 0), .init(x: 1, y: 0.5), .init(x: 0.84, y: 1), .init(x: 0.16, y: 1)]
        default: vertices = [.zero, .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)]
        }
        return [vertices + [vertices[0]]]
    }

    static func fillPaths(_ node: DiagramNode) -> [[NSPoint]] {
        if let icon = node.icon, let geometry = icons[icon], let fill = geometry.fillPaths {
            return fill.map { $0.map { NSPoint(x: $0[0], y: $0[1]) } }
        }
        return [paths(node)[0]]
    }

    static func vertices(_ node: DiagramNode) -> [NSPoint] {
        if let icon = node.icon, let g = icons[icon] { return g.vertices.map { .init(x: $0[0], y: $0[1]) } }
        let path = paths(node)[0]
        return ["ellipse", "cloud", "cylinder"].contains(node.shape) ? (0..<8).map { path[$0*(path.count-1)/8] } : Array(path.dropLast())
    }

    static func portChoices(_ node: DiagramNode?) -> [(String, String)] {
        let sides = [("auto", "Ближайшая граница"), ("n", "Верх"), ("e", "Право"), ("s", "Низ"), ("w", "Лево"),
                     ("ne", "Северо-восток"), ("se", "Юго-восток"), ("sw", "Юго-запад"), ("nw", "Северо-запад")]
        return sides + (node.map { vertices($0).indices.map { ("vertex:\($0)", "Вершина \($0 + 1)") } } ?? [])
    }

    static func world(_ point: NSPoint, in position: LayoutNode) -> NSPoint {
        NSPoint(x: position.x+(point.x-0.5)*position.width, y: position.y+(point.y-0.5)*position.height)
    }

    static func rotated(_ point: NSPoint, around center: NSPoint, degrees: Double) -> NSPoint {
        let angle = degrees * .pi / 180, x = point.x-center.x, y = point.y-center.y
        return NSPoint(x: center.x+x*cos(angle)-y*sin(angle), y: center.y+x*sin(angle)+y*cos(angle))
    }

    static func world(_ point: NSPoint, node: DiagramNode, in position: LayoutNode) -> NSPoint {
        rotated(world(point, in: position), around: .init(x: position.x, y: position.y), degrees: node.effectiveRotation)
    }

    static func visualBounds(_ rect: NSRect, rotation: Double) -> NSRect {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let points = [NSPoint(x: rect.minX,y: rect.minY), NSPoint(x: rect.maxX,y: rect.minY),
                      NSPoint(x: rect.maxX,y: rect.maxY), NSPoint(x: rect.minX,y: rect.maxY)]
            .map { rotated($0, around: center, degrees: rotation) }
        let xs = points.map(\.x), ys = points.map(\.y)
        return NSRect(x: xs.min()!, y: ys.min()!, width: xs.max()!-xs.min()!, height: ys.max()!-ys.min()!)
    }

    /// Hit the same filled contours and strokes that the canvas paints. All
    /// coordinates and tolerance are screen points, independent of canvas zoom.
    static func contains(_ point: NSPoint, node: DiagramNode, in rect: NSRect, tolerance: CGFloat) -> Bool {
        let point = rotated(point, around: .init(x: rect.midX, y: rect.midY), degrees: -node.effectiveRotation)
        guard rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
        for contour in fillPaths(node) {
            let path = NSBezierPath()
            for (index, p) in contour.enumerated() {
                let value = NSPoint(x: rect.minX+p.x*rect.width, y: rect.minY+p.y*rect.height)
                if index == 0 { path.move(to: value) } else { path.line(to: value) }
            }
            path.close(); if path.contains(point) { return true }
        }
        let closed = node.icon.flatMap { icons[$0]?.closed } ?? [true]
        for (index, contour) in paths(node).enumerated() {
            var points = contour.map { NSPoint(x: rect.minX+$0.x*rect.width, y: rect.minY+$0.y*rect.height) }
            guard let first = points.first else { continue }
            if closed.indices.contains(index), closed[index] {
                let path = NSBezierPath()
                path.move(to: first)
                for next in points.dropFirst() { path.line(to: next) }
                path.close()
                if path.contains(point) { return true }
                if points.last != first { points.append(first) }
            }
            if zip(points, points.dropFirst()).contains(where: {
                let closest = nearest(point, $0.0, $0.1)
                return hypot(point.x-closest.x, point.y-closest.y) <= tolerance
            }) { return true }
        }
        return false
    }

    static func nearest(_ point: NSPoint, _ a: NSPoint, _ b: NSPoint) -> NSPoint {
        let dx = b.x-a.x, dy = b.y-a.y, length = dx*dx+dy*dy
        let t = length > 0 ? max(0, min(1, ((point.x-a.x)*dx+(point.y-a.y)*dy)/length)) : 0
        return NSPoint(x: a.x+t*dx, y: a.y+t*dy)
    }

    static func segmentIntersectsRect(_ a: NSPoint, _ b: NSPoint, _ rect: NSRect) -> Bool {
        var low: CGFloat = 0, high: CGFloat = 1
        for (origin, delta, minimum, maximum) in [(a.x,b.x-a.x,rect.minX,rect.maxX),(a.y,b.y-a.y,rect.minY,rect.maxY)] {
            if abs(delta) < 1e-10 { if origin < minimum || origin > maximum { return false }; continue }
            let enter = (minimum-origin)/delta, leave = (maximum-origin)/delta
            low = max(low,min(enter,leave)); high = min(high,max(enter,leave))
            if low > high { return false }
        }
        return true
    }

    static func attachment(_ node: DiagramNode, at position: LayoutNode, toward: NSPoint, port: String) -> NSPoint {
        if port.hasPrefix("vertex:"), let index = Int(port.dropFirst(7)), vertices(node).indices.contains(index) {
            return world(vertices(node)[index], node: node, in: position)
        }
        let contours = paths(node).map { $0.map { world($0, node: node, in: position) } }
        let directions: [String: NSPoint] = ["n": .init(x: 0, y: 1), "ne": .init(x: 1, y: 1), "e": .init(x: 1, y: 0), "se": .init(x: 1, y: -1), "s": .init(x: 0, y: -1), "sw": .init(x: -1, y: -1), "w": .init(x: -1, y: 0), "nw": .init(x: -1, y: 1)]
        var aim = toward
        if let direction = directions[port] {
            let d = rotated(direction, around: .zero, degrees: node.effectiveRotation)
            var intersections: [(CGFloat, NSPoint)] = []
            for contour in contours {
                for (a, b) in zip(contour, contour.dropFirst()) {
                    let sx = b.x-a.x, sy = b.y-a.y, denominator = d.x*sy-d.y*sx
                    if abs(denominator) < 1e-10 { continue }
                    let ax = a.x-position.x, ay = a.y-position.y
                    let t = (ax*sy-ay*sx)/denominator, u = (ax*d.y-ay*d.x)/denominator
                    if t >= 0 && u >= 0 && u <= 1 { intersections.append((t, .init(x: position.x+t*d.x, y: position.y+t*d.y))) }
                }
            }
            if let last = intersections.max(by: { $0.0 < $1.0 }) { return last.1 }
            aim = .init(x: position.x+d.x*position.width*2, y: position.y+d.y*position.height*2)
        }
        let points = contours.flatMap { path in zip(path, path.dropFirst()).map { nearest(aim, $0.0, $0.1) } }
        return points.min { hypot($0.x-aim.x, $0.y-aim.y) < hypot($1.x-aim.x, $1.y-aim.y) } ?? .init(x: position.x, y: position.y)
    }

    static func route(_ a: NSPoint, _ b: NSPoint, routing: String, horizontal: Bool) -> [NSPoint] {
        if routing == "orthogonal" {
            if horizontal { let middle = (a.x+b.x)/2; return [a, .init(x: middle, y: a.y), .init(x: middle, y: b.y), b] }
            let middle = (a.y+b.y)/2; return [a, .init(x: a.x, y: middle), .init(x: b.x, y: middle), b]
        }
        if routing == "angled" { return [a, horizontal ? .init(x: (a.x+b.x)/2, y: a.y) : .init(x: a.x, y: (a.y+b.y)/2), b] }
        if routing == "curved" {
            let dx = b.x-a.x, dy = b.y-a.y
            let offset = min(0.55, max(0.12, hypot(dx, dy)*0.12))
            let c1 = horizontal ? NSPoint(x: a.x+dx/3, y: a.y+offset) : NSPoint(x: a.x+offset, y: a.y+dy/3)
            let c2 = horizontal ? NSPoint(x: a.x+2*dx/3, y: b.y+offset) : NSPoint(x: b.x+offset, y: a.y+2*dy/3)
            return sampleCubic(a, c1, c2, b)
        }
        return [a, b]
    }

    static func sampleCubic(_ p0: NSPoint, _ p1: NSPoint, _ p2: NSPoint, _ p3: NSPoint, segments: Int = 24) -> [NSPoint] {
        (0...segments).map { step in
            let t = CGFloat(step) / CGFloat(segments), u = 1-t
            return NSPoint(x: u*u*u*p0.x+3*u*u*t*p1.x+3*u*t*t*p2.x+t*t*t*p3.x,
                           y: u*u*u*p0.y+3*u*u*t*p1.y+3*u*t*t*p2.y+t*t*t*p3.y)
        }
    }

    static func edgePoints(_ edge: DiagramEdge, source: LayoutNode, target: LayoutNode, sourceNode: DiagramNode, targetNode: DiagramNode,
                           settings: DiagramSettings, proposed: [NSPoint]? = nil, waypoints: [RoutePoint]? = nil,
                           proposedNormalized: Bool = false) -> [NSPoint] {
        if proposedNormalized, let proposed { return deduplicate(proposed) }
        let proposed = proposed.map { sourceToTarget($0, source: source, target: target) }
        var bends = (waypoints ?? edge.waypoints).map { NSPoint(x: $0.x, y: $0.y) }
        var start = attachment(sourceNode, at: source, toward: bends.first ?? .init(x: target.x, y: target.y), port: edge.sourcePort)
        var end = attachment(targetNode, at: target, toward: bends.last ?? .init(x: source.x, y: source.y), port: edge.targetPort)
        let routing = edge.routing ?? settings.edgeRouting
        let horizontal = ["LR", "RL"].contains(settings.direction)
        if edge.source == edge.target && bends.isEmpty {
            start = attachment(sourceNode, at: source, toward: .zero, port: edge.sourcePort == "auto" ? "e" : edge.sourcePort)
            end = attachment(targetNode, at: target, toward: .zero, port: edge.targetPort == "auto" ? "n" : edge.targetPort)
            bends = [.init(x: source.x+source.width, y: source.y), .init(x: source.x+source.width, y: source.y+source.height), .init(x: source.x, y: source.y+source.height)]
        }
        let result: [NSPoint]
        if routing == "curved", !bends.isEmpty || edge.sourcePort != "auto" || edge.targetPort != "auto" {
            result = smoothRoute([start] + bends + [end], source: edge.sourcePort == "auto" ? nil : source,
                                 target: edge.targetPort == "auto" ? nil : target)
        } else if routing == "orthogonal" {
            let anchors = [start] + bends + [end]
            result = [start] + (0..<anchors.count-1).flatMap { index in
                Array(orthogonalRoute(anchors[index], anchors[index+1],
                    source: index == 0 && edge.sourcePort != "auto" ? source : nil,
                    target: index == anchors.count-2 && edge.targetPort != "auto" ? target : nil).dropFirst())
            }
        } else if !bends.isEmpty {
            result = [start] + bends + [end]
        } else if edge.sourcePort != "auto" || edge.targetPort != "auto" {
            result = route(start, end, routing: routing, horizontal: horizontal)
        } else if let proposed, proposed.count > 2, routing == "angled", edge.routing == nil,
                  edge.sourcePort == "auto", edge.targetPort == "auto" {
            start = attachment(sourceNode, at: source, toward: proposed[1], port: "auto")
            end = attachment(targetNode, at: target, toward: proposed[proposed.count-2], port: "auto")
            result = [start] + proposed.dropFirst().dropLast() + [end]
        } else if routing == "curved", edge.sourcePort == "auto", edge.targetPort == "auto",
                  let proposed, proposed.count >= 4, (proposed.count-1) % 3 == 0 {
            let p1 = proposed[1], p2 = proposed[proposed.count-2]
            start = attachment(sourceNode, at: source, toward: p1, port: "auto")
            end = attachment(targetNode, at: target, toward: p2, port: "auto")
            let controls = [start] + proposed.dropFirst().dropLast() + [end]
            result = [start] + stride(from: 0, to: controls.count-1, by: 3).flatMap { index in
                Array(sampleCubic(controls[index], controls[index+1], controls[index+2], controls[index+3]).dropFirst())
            }
        } else { result = route(start, end, routing: routing, horizontal: horizontal) }
        return deduplicate(result)
    }

    static func smoothRoute(_ anchors: [NSPoint], source: LayoutNode? = nil, target: LayoutNode? = nil) -> [NSPoint] {
        let points = deduplicate(anchors)
        guard points.count > 1 else { return points }
        var tangents: [NSPoint] = [], lengths: [CGFloat] = []
        for (index, point) in points.enumerated() {
            let before = points[max(0, index-1)], after = points[min(points.count-1,index+1)]
            let vector: NSPoint
            if index == 0, let source { vector = .init(x: point.x-source.x, y: point.y-source.y) }
            else if index == points.count-1, let target { vector = .init(x: target.x-point.x, y: target.y-point.y) }
            else { vector = .init(x: after.x-before.x, y: after.y-before.y) }
            let norm = hypot(vector.x,vector.y)
            tangents.append(norm > 1e-9 ? .init(x: vector.x/norm,y: vector.y/norm) : .init(x: 1,y: 0))
            let distances = [before,after].map { hypot(point.x-$0.x,point.y-$0.y) }.filter { $0 > 1e-7 }
            lengths.append(min(2,(distances.min() ?? 0)*0.35))
        }
        var result = [points[0]]
        for index in 0..<points.count-1 {
            let a = points[index], b = points[index+1], u = tangents[index], v = tangents[index+1]
            let c1 = NSPoint(x: a.x+u.x*lengths[index], y: a.y+u.y*lengths[index])
            let c2 = NSPoint(x: b.x-v.x*lengths[index+1], y: b.y-v.y*lengths[index+1])
            result += sampleCubic(a,c1,c2,b,segments: 96).dropFirst()
        }
        return result
    }

    private static func deduplicate(_ input: [NSPoint]) -> [NSPoint] {
        input.reduce(into: []) { points, next in
            if let last = points.last, hypot(last.x-next.x, last.y-next.y) < 1e-7 { return }
            points.append(next)
        }
    }

    static func orthogonalRoute(_ a: NSPoint, _ b: NSPoint, source: LayoutNode? = nil, target: LayoutNode? = nil) -> [NSPoint] {
        var xs = [(a.x+b.x)/2,a.x,b.x], ys = [(a.y+b.y)/2,a.y,b.y]
        for object in [source,target].compactMap({ $0 }) {
            xs += [object.x-object.width/2-0.08,object.x+object.width/2+0.08]
            ys += [object.y-object.height/2-0.08,object.y+object.height/2+0.08]
        }
        var candidates: [[NSPoint]] = [[a,.init(x: a.x,y: b.y),b],[a,.init(x: b.x,y: a.y),b]]
        for x in xs { candidates.append([a,.init(x: x,y: a.y),.init(x: x,y: b.y),b]) }
        for y in ys { candidates.append([a,.init(x: a.x,y: y),.init(x: b.x,y: y),b]) }
        for x in xs { for y in ys {
            candidates.append([a,.init(x: x,y: a.y),.init(x: x,y: y),.init(x: b.x,y: y),b])
            candidates.append([a,.init(x: a.x,y: y),.init(x: x,y: y),.init(x: x,y: b.y),b])
        } }
        func compact(_ points: [NSPoint]) -> [NSPoint] {
            var result: [NSPoint] = []
            for p in deduplicate(points) {
                while result.count > 1 {
                    let u = result[result.count-2], v = result.last!
                    let cross = (v.x-u.x)*(p.y-v.y)-(v.y-u.y)*(p.x-v.x)
                    let dot = (v.x-u.x)*(p.x-v.x)+(v.y-u.y)*(p.y-v.y)
                    if abs(cross)>1e-9 || dot<=0 { break }
                    result.removeLast()
                }
                result.append(p)
            }
            return result
        }
        func score(_ points: [NSPoint]) -> Double {
            guard points.count>1 else { return 0 }
            var cost = zip(points,points.dropFirst()).reduce(0.0) { $0+hypot($1.1.x-$1.0.x,$1.1.y-$1.0.y) } + 0.12*Double(points.count)
            for (end,peer,object) in [(points[0],points[1],source),(points.last!,points[points.count-2],target)] {
                if let object, (end.x-object.x)*(peer.x-end.x)+(end.y-object.y)*(peer.y-end.y)<=1e-8 { cost += 10000 }
            }
            for object in [source,target].compactMap({ $0 }) {
                let rect = NSRect(x: object.x-object.width/2+1e-5,y: object.y-object.height/2+1e-5,
                                  width: object.width-2e-5,height: object.height-2e-5)
                for (u,v) in zip(points,points.dropFirst()) where segmentIntersectsRect(u,v,rect) { cost += 10000 }
            }
            return cost
        }
        return candidates.map(compact).min { score($0)<score($1) } ?? [a,b]
    }

    private static func sourceToTarget(_ points: [NSPoint], source: LayoutNode, target: LayoutNode) -> [NSPoint] {
        guard let first = points.first, let last = points.last, points.count > 1 else { return points }
        let direct = hypot(first.x-source.x, first.y-source.y) + hypot(last.x-target.x, last.y-target.y)
        let reversed = hypot(last.x-source.x, last.y-source.y) + hypot(first.x-target.x, first.y-target.y)
        return reversed + 1e-7 < direct ? Array(points.reversed()) : points
    }
}
