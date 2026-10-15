import AppKit

/// An export-only copy. Neither layout repair nor presentation overrides mutate the editor.
@MainActor
struct DiagramPDFScene {
    var project: DiagramProject
    var layout: DiagramLayout
    var style: DiagramPDFCanvasStyle
    var movedNodes = 0
    var movedLabels = 0
    var remainingOverlaps = 0

    static func prepare(project original: DiagramProject, layout originalLayout: DiagramLayout,
                        settings: DiagramPDFSettings) -> DiagramPDFScene {
        var project = original
        project.presentation.theme = "light"; project.presentation.background = "#FFFFFF"
        project.diagram.layoutMode = "manual"
        let originalPositions = Dictionary(uniqueKeysWithValues: originalLayout.nodes.map { ($0.id, $0) })
        var positions: [String: LayoutNode] = [:]
        for index in project.nodes.indices {
            var node = project.nodes[index]
            var position = originalPositions[node.id] ?? LayoutNode(id: node.id, x: node.x ?? 0, y: node.y ?? 0,
                                                                    width: node.width ?? 1.6, height: node.height ?? 0.62)
            position.x *= settings.spacing; position.y *= settings.spacing
            position.width = node.width ?? position.width; position.height = node.height ?? position.height
            node.style.penwidth *= settings.nodeStroke
            node.style.fontSize = min(144, max(1, node.style.effectiveFontSize*settings.nodeText))
            if settings.wrapNodeLabels { node.labelWrap = true }
            if settings.fitNodeLabels {
                let font = NSFont.systemFont(ofSize: node.style.effectiveFontSize, weight: .semibold)
                let lines = DiagramTextLayout.lines(node.label, width: position.width*72*0.84,
                                                    fontSize: node.style.effectiveFontSize, wrap: node.effectiveLabelWrap)
                let requiredHeight = Double(lines.count)*node.style.effectiveFontSize*1.25+12
                let requiredWidth = node.effectiveLabelWrap ? 0
                    : (node.label.components(separatedBy: .newlines).map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0)+16
                let grow = max(1, max(requiredHeight/(position.height*72), requiredWidth/(position.width*72)))
                position.width *= grow; position.height *= grow
            }
            node.width = position.width; node.height = position.height
            if settings.contrastText {
                let fill = NSColor(hex: node.style.resolved(.fill, theme: "light"))
                node.style.text = contrasting(node.style.resolved(.text, theme: "light"), on: fill)
                node.style.textMode = "custom"
            }
            positions[node.id] = position; project.nodes[index] = node
        }
        for index in project.containers.indices {
            project.containers[index].style.penwidth = project.containers[index].style.effectivePenwidth*settings.containerStroke
            if settings.contrastText {
                project.containers[index].style.text = contrasting(project.containers[index].style.resolved(.text, theme: "light"), on: .white)
                project.containers[index].style.textMode = "custom"
            }
        }
        let containers = Dictionary(uniqueKeysWithValues: project.containers.map { ($0.id, $0) })
        var containerFrames: [String: NSRect] = [:]
        var emptyCenters: [String: NSPoint] = [:]
        let previousContainers = Dictionary(uniqueKeysWithValues: (originalLayout.containers ?? []).map { ($0.id, $0) })
        for container in project.containers {
            emptyCenters[container.id] = NSPoint(x: (container.x ?? previousContainers[container.id]?.x ?? 0)*settings.spacing,
                                                y: (container.y ?? previousContainers[container.id]?.y ?? 0)*settings.spacing)
        }
        let children = Dictionary(grouping: project.containers, by: { $0.parentId ?? "" })
        let members = Dictionary(grouping: project.nodes, by: { $0.containerId ?? "" })
        var overlapCount = 0
        func translate(_ key: String, by delta: NSPoint) {
            if key.hasPrefix("n:"), var node = positions[String(key.dropFirst(2))] {
                node.x += delta.x; node.y += delta.y; positions[node.id] = node
            } else {
                let id = String(key.dropFirst(2))
                if let rect = containerFrames[id] { containerFrames[id] = rect.offsetBy(dx: delta.x, dy: delta.y) }
                if let point = emptyCenters[id] { emptyCenters[id] = NSPoint(x: point.x+delta.x, y: point.y+delta.y) }
                for node in members[id] ?? [] { translate("n:\(node.id)", by: delta) }
                for child in children[id] ?? [] { translate("c:\(child.id)", by: delta) }
            }
        }
        func frame(_ key: String) -> NSRect {
            if key.hasPrefix("n:"), let node = positions[String(key.dropFirst(2))] {
                return NSRect(x: node.x-node.width/2, y: node.y-node.height/2, width: node.width, height: node.height)
            }
            return containerFrames[String(key.dropFirst(2))] ?? .zero
        }
        func arrange(_ parent: String) {
            for container in children[parent] ?? [] { arrange(container.id) }
            let keys = (members[parent] ?? []).map { "n:\($0.id)" } + (children[parent] ?? []).map { "c:\($0.id)" }
            let gap = settings.gap/72
            if settings.avoidOverlaps, keys.count > 1 {
                for _ in 0..<32 {
                    var changed = false
                    let ordered = keys.sorted { frame($0).minX == frame($1).minX ? $0 < $1 : frame($0).minX < frame($1).minX }
                    for first in ordered.indices {
                        for second in ordered.indices where second > first {
                            let a = frame(ordered[first]), b = frame(ordered[second])
                            if b.minX > a.maxX+gap { break }
                            let dx = (a.midX <= b.midX ? a.maxX-b.minX : b.maxX-a.minX)+gap
                            let dy = (a.midY <= b.midY ? a.maxY-b.minY : b.maxY-a.minY)+gap
                            guard dx > 0.0001, dy > 0.0001 else { continue }
                            let delta: NSPoint
                            if dx <= dy {
                                delta = NSPoint(x: (a.midX <= b.midX ? 1 : -1)*(dx/2+0.001), y: 0)
                            } else { delta = NSPoint(x: 0, y: (a.midY <= b.midY ? 1 : -1)*(dy/2+0.001)) }
                            translate(ordered[first], by: NSPoint(x: -delta.x, y: -delta.y))
                            translate(ordered[second], by: delta)
                            changed = true
                        }
                    }
                    if !changed { break }
                }
            }
            let orderedFrames = keys.map(frame).sorted { $0.minX < $1.minX }
            for i in orderedFrames.indices {
                for j in orderedFrames.indices where j > i {
                    if orderedFrames[j].minX >= orderedFrames[i].maxX { break }
                    let intersection = orderedFrames[i].intersection(orderedFrames[j])
                    if !intersection.isNull && intersection.width > 0.001 && intersection.height > 0.001 { overlapCount += 1 }
                }
            }
            guard let container = containers[parent] else { return }
            var contents = keys.map(frame).reduce(NSRect.null) { $0.union($1) }
            if contents.isNull {
                let center = emptyCenters[parent] ?? .zero
                contents = NSRect(x: center.x-container.width/2, y: center.y-container.height/2,
                                  width: container.width, height: container.height)
            } else {
                contents = contents.insetBy(dx: -container.padding/72, dy: -container.padding/72)
                contents.size.height += settings.containerHeaderHeight/72
            }
            let titleWidth = (container.label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: settings.containerFontSize, weight: .bold)]).width+20
            let width = max(contents.width, min(500,titleWidth)/72)
            containerFrames[parent] = NSRect(x: contents.midX-width/2, y: contents.minY, width: width, height: max(contents.height,settings.containerHeaderHeight/72+0.1))
        }
        arrange("")
        // Store the final positions only in the export copy.
        var moved = 0
        for index in project.nodes.indices {
            guard let p = positions[project.nodes[index].id] else { continue }
            project.nodes[index].x = p.x; project.nodes[index].y = p.y
            if let old = originalPositions[p.id], hypot(p.x-old.x*settings.spacing,p.y-old.y*settings.spacing) > 0.001 { moved += 1 }
        }
        for index in project.containers.indices {
            let id = project.containers[index].id
            let point = emptyCenters[id] ?? .zero
            project.containers[index].x = point.x; project.containers[index].y = point.y
            // The native renderer computes occupied containers from their members.
            // Empty frames must keep the width reserved for a long heading too.
            if (members[id] ?? []).isEmpty && (children[id] ?? []).isEmpty, let rect = containerFrames[id] {
                project.containers[index].width = rect.width; project.containers[index].height = rect.height
                project.containers[index].x = rect.midX; project.containers[index].y = rect.midY
            }
        }
        let nodeByID = Dictionary(uniqueKeysWithValues: project.nodes.map { ($0.id,$0) })
        let oldEdges = Dictionary(uniqueKeysWithValues: originalLayout.edges.map { ($0.id,$0) })
        var edges: [LayoutEdge] = []
        var routes: [String: [NSPoint]] = [:]
        for index in project.edges.indices {
            var edge = project.edges[index]
            edge.style.penwidth *= settings.edgeStroke
            edge.style.fontSize = min(144,max(1,edge.style.effectiveFontSize*settings.edgeText))
            if settings.labelBackground != "project" { edge.style.labelBackgroundTransparent = settings.labelBackground == "transparent" }
            if settings.contrastText { edge.style.text = contrasting(edge.style.resolved(.text, theme: "light"), on: .white); edge.style.textMode = "custom" }
            guard let source = positions[edge.source], let target = positions[edge.target],
                  let sourceNode = nodeByID[edge.source], let targetNode = nodeByID[edge.target] else { continue }
            let oldSource = originalPositions[edge.source], oldTarget = originalPositions[edge.target]
            let delta = NSPoint(x: ((source.x-(oldSource?.x ?? source.x)*settings.spacing)+(target.x-(oldTarget?.x ?? target.x)*settings.spacing))/2,
                                y: ((source.y-(oldSource?.y ?? source.y)*settings.spacing)+(target.y-(oldTarget?.y ?? target.y)*settings.spacing))/2)
            edge.waypoints = edge.waypoints.map { RoutePoint(x: $0.x*settings.spacing+delta.x, y: $0.y*settings.spacing+delta.y) }
            let same = settings.spacing == 1 && source == oldSource && target == oldTarget
            let previous = oldEdges[edge.id]
            let route = CanvasGeometry.edgePoints(edge, source: source, target: target, sourceNode: sourceNode, targetNode: targetNode,
                settings: project.diagram, proposed: same ? previous?.points.map { NSPoint(x: $0.x,y: $0.y) } : nil,
                proposedNormalized: same && previous?.normalized == true)
            let center = midpoint(route)
            routes[edge.id] = route
            edges.append(LayoutEdge(id: edge.id, source: edge.source, target: edge.target,
                points: route.map { LayoutPoint(x: $0.x,y: $0.y) }, label: edge.label, labelX: center.x, labelY: center.y+0.15, normalized: true))
            project.edges[index] = edge
        }
        var reserved = positions.values.map { NSRect(x: $0.x-$0.width/2-0.025, y: $0.y-$0.height/2-0.025, width: $0.width+0.05,height: $0.height+0.05) }
        reserved += containerFrames.values.map { NSRect(x: $0.minX, y: $0.maxY-settings.containerHeaderHeight/72,
                                                       width: $0.width,height: settings.containerHeaderHeight/72) }
        var style = DiagramPDFCanvasStyle(containerFontSize: settings.containerFontSize, arrowSize: settings.arrowSize,
                                          containerFrames: containerFrames)
        var labelConflicts = 0, movedLabels = 0
        var obstacles = PDFObstacleIndex()
        for rect in reserved { obstacles.insert(rect) }
        let fractions: [Double] = settings.placeEdgeLabels ? [0.5,0.35,0.65,0.2,0.8] : [0.5]
        var offsets = [NSPoint(x: 0,y: 0.15)]
        if settings.placeEdgeLabels {
            offsets = [.zero]
            for distance in [CGFloat(12),24,40,64,96] {
                let d = distance/72
                offsets.append(contentsOf: [NSPoint(x: 0,y: d),NSPoint(x: 0,y: -d),NSPoint(x: d,y: 0),NSPoint(x: -d,y: 0)])
            }
        }
        for edge in project.edges where !edge.label.isEmpty {
            guard let route = routes[edge.id], !route.isEmpty else { continue }
            let size = (edge.label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: edge.style.effectiveFontSize, weight: .medium)])
            let width = (size.width+14)/72, height = max(16,size.height+8)/72
            let origin = midpoint(route)
            var best = NSPoint(x: origin.x,y: origin.y+0.15), bestScore = CGFloat.infinity
            for fraction in fractions {
                let anchor = midpoint(route, fraction: fraction)
                for offset in offsets {
                    let center = NSPoint(x: anchor.x+offset.x,y: anchor.y+offset.y)
                    let rect = NSRect(x: center.x-width/2,y: center.y-height/2,width: width,height: height)
                    let overlap = obstacles.overlapArea(rect)
                    let score = overlap*100_000 + hypot(center.x-origin.x,center.y-origin.y)
                    if score < bestScore { best = center; bestScore = score }
                }
            }
            let rect = NSRect(x: best.x-width/2,y: best.y-height/2,width: width,height: height)
            if obstacles.overlapArea(rect) > 0.000_001 { labelConflicts += 1 }
            if hypot(best.x-origin.x,best.y-origin.y) > 0.3 { style.labelLeaders[edge.id] = nearest(best,to: route) }
            if hypot(best.x-origin.x,best.y-origin.y-0.15) > 0.05 { movedLabels += 1 }
            style.edgeLabels[edge.id] = best; reserved.append(rect); obstacles.insert(rect)
        }
        let allNodes = project.nodes.compactMap { positions[$0.id] }
        let rect = reserved.reduce(NSRect.null) { $0.union($1) }
        let safe = rect.isNull ? NSRect(x: 0,y: 0,width: 3,height: 2) : rect
        let layout = DiagramLayout(engine: originalLayout.engine, edgeRouting: project.diagram.edgeRouting,
            width: max(0.1,safe.width), height: max(0.1,safe.height), minX: safe.minX,minY: safe.minY,
            nodes: allNodes,edges: edges,containers: originalLayout.containers)
        return DiagramPDFScene(project: project, layout: layout, style: style, movedNodes: moved,
                               movedLabels: movedLabels, remainingOverlaps: overlapCount+labelConflicts)
    }

    static func midpoint(_ points: [NSPoint], fraction: Double = 0.5) -> NSPoint {
        guard let first = points.first else { return .zero }
        let lengths = zip(points,points.dropFirst()).map { hypot($1.x-$0.x,$1.y-$0.y) }
        var remaining = lengths.reduce(0,+)*fraction
        for (i,length) in lengths.enumerated() where length > 0 {
            if remaining <= length {
                let t = remaining/length, a = points[i], b = points[i+1]
                return NSPoint(x: a.x+(b.x-a.x)*t,y: a.y+(b.y-a.y)*t)
            }
            remaining -= length
        }
        return points.last ?? first
    }

    private static func nearest(_ point: NSPoint,to route: [NSPoint]) -> NSPoint {
        zip(route,route.dropFirst()).map { CanvasGeometry.nearest(point,$0,$1) }
            .min { hypot($0.x-point.x,$0.y-point.y) < hypot($1.x-point.x,$1.y-point.y) } ?? point
    }

    private static func contrasting(_ text: String,on fill: NSColor) -> String {
        func lightness(_ color: NSColor) -> CGFloat {
            guard let rgb = color.usingColorSpace(.deviceRGB) else { return 1 }
            return (rgb.redComponent*0.2126+rgb.greenComponent*0.7152+rgb.blueComponent*0.0722)*rgb.alphaComponent+1-rgb.alphaComponent
        }
        let original = NSColor(hex: text)
        if original.alphaComponent < 0.05 { return text }
        let background = lightness(fill), foreground = lightness(original)
        if abs(background-foreground) >= 0.45 { return text }
        return NSColor(hex: background > 0.5 ? "#172238" : "#FFFFFF").withAlphaComponent(original.alphaComponent).hexRGBA
    }
}

/// A spatial index keeps repeated label-placement previews local to nearby obstacles.
private struct PDFObstacleIndex {
    private struct Cell: Hashable { let x: Int; let y: Int }
    private var rectangles: [NSRect] = []
    private var cells: [Cell: [Int]] = [:]
    private var broad: [Int] = []

    private func keys(_ rect: NSRect) -> [Cell]? {
        let x0 = Int(floor(rect.minX)),x1 = Int(floor(rect.maxX))
        let y0 = Int(floor(rect.minY)),y1 = Int(floor(rect.maxY))
        guard x1-x0 <= 64,y1-y0 <= 64,(x1-x0+1)*(y1-y0+1) <= 4096 else { return nil }
        return (x0...x1).flatMap { x in (y0...y1).map { Cell(x: x,y: $0) } }
    }
    mutating func insert(_ rect: NSRect) {
        let index = rectangles.count; rectangles.append(rect)
        guard let keys = keys(rect) else { broad.append(index); return }
        for key in keys { cells[key,default: []].append(index) }
    }
    func overlapArea(_ rect: NSRect) -> CGFloat {
        let indices: [Int]
        if let keys = keys(rect) {
            var nearby = Set(broad)
            for key in keys { nearby.formUnion(cells[key] ?? []) }
            indices = nearby.sorted()
        } else { indices = Array(rectangles.indices) }
        return indices.reduce(CGFloat.zero) { value,index in
            let hit = rectangles[index].intersection(rect)
            return value+(hit.isNull ? 0 : hit.width*hit.height)
        }
    }
}
