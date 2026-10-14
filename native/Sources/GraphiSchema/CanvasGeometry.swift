import AppKit

struct IconGeometry: Decodable {
    let aspectRatio: Double
    let paths: [[[Double]]]
    let closed: [Bool]
    let vertices: [[Double]]
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

    static func nearest(_ point: NSPoint, _ a: NSPoint, _ b: NSPoint) -> NSPoint {
        let dx = b.x-a.x, dy = b.y-a.y, length = dx*dx+dy*dy
        let t = length > 0 ? max(0, min(1, ((point.x-a.x)*dx+(point.y-a.y)*dy)/length)) : 0
        return NSPoint(x: a.x+t*dx, y: a.y+t*dy)
    }

    static func attachment(_ node: DiagramNode, at position: LayoutNode, toward: NSPoint, port: String) -> NSPoint {
        if port.hasPrefix("vertex:"), let index = Int(port.dropFirst(7)), vertices(node).indices.contains(index) {
            return world(vertices(node)[index], in: position)
        }
        let contours = paths(node).map { $0.map { world($0, in: position) } }
        let directions: [String: NSPoint] = ["n": .init(x: 0, y: 1), "ne": .init(x: 1, y: 1), "e": .init(x: 1, y: 0), "se": .init(x: 1, y: -1), "s": .init(x: 0, y: -1), "sw": .init(x: -1, y: -1), "w": .init(x: -1, y: 0), "nw": .init(x: -1, y: 1)]
        var aim = toward
        if let d = directions[port] {
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
        if edge.sourcePort != "auto" || edge.targetPort != "auto" {
            let leadLength = min(0.25, hypot(end.x-start.x, end.y-start.y)/3)
            let anchors = [portLead(start, at: source, port: edge.sourcePort, routing: routing, length: leadLength)] + bends
                + [portLead(end, at: target, port: edge.targetPort, routing: routing, length: leadLength)]
            result = [start, anchors[0]] + zip(anchors, anchors.dropFirst()).flatMap { a, b in
                bends.isEmpty || routing == "orthogonal" ? Array(route(a, b, routing: routing, horizontal: horizontal).dropFirst()) : [b]
            } + [end]
        } else if !bends.isEmpty {
            let anchors = [start] + bends + [end]
            result = [start] + zip(anchors, anchors.dropFirst()).flatMap { a, b in
                routing == "orthogonal" ? Array(route(a, b, routing: routing, horizontal: horizontal).dropFirst()) : [b]
            }
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

    private static func deduplicate(_ input: [NSPoint]) -> [NSPoint] {
        input.reduce(into: []) { points, next in
            if let last = points.last, hypot(last.x-next.x, last.y-next.y) < 1e-7 { return }
            points.append(next)
        }
    }

    private static func portLead(_ point: NSPoint, at position: LayoutNode, port: String, routing: String, length: CGFloat) -> NSPoint {
        guard port != "auto" else { return point }
        var dx = point.x-position.x, dy = point.y-position.y
        if routing == "orthogonal" {
            if abs(dx) >= abs(dy) { dy = 0 } else { dx = 0 }
        }
        let norm = hypot(dx, dy)
        return norm > 1e-9 ? NSPoint(x: point.x+length*dx/norm, y: point.y+length*dy/norm) : point
    }

    private static func sourceToTarget(_ points: [NSPoint], source: LayoutNode, target: LayoutNode) -> [NSPoint] {
        guard let first = points.first, let last = points.last, points.count > 1 else { return points }
        let direct = hypot(first.x-source.x, first.y-source.y) + hypot(last.x-target.x, last.y-target.y)
        let reversed = hypot(last.x-source.x, last.y-source.y) + hypot(first.x-target.x, first.y-target.y)
        return reversed + 1e-7 < direct ? Array(points.reversed()) : points
    }
}
