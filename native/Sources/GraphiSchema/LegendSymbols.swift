import AppKit

@MainActor
enum LegendSymbols {
    static func draw(_ node: DiagramNode, in rect: NSRect, theme: String) {
        let aspect = node.width.flatMap { width in node.height.map { width/$0 } }
            ?? node.icon.flatMap { CanvasGeometry.icons[$0]?.aspectRatio } ?? 1
        let width = min(rect.width-2,(rect.height-2)*aspect), height = min(rect.height-2,(rect.width-2)/aspect)
        let frame = NSRect(x: rect.midX-width/2,y: rect.midY-height/2,width: width,height: height)
        func points(_ contour: [NSPoint]) -> [NSPoint] { contour.map { .init(x: frame.minX+$0.x*width,y: frame.minY+$0.y*height) } }
        let fill = NSBezierPath(); fill.windingRule = .nonZero
        for contour in CanvasGeometry.fillPaths(node) {
            let values = points(contour)
            if let first = values.first { fill.move(to: first); for p in values.dropFirst() { fill.line(to: p) }; fill.close() }
        }
        NSColor(hex: node.style.resolved(.fill,theme: theme)).setFill(); fill.fill()
        NSColor(hex: node.style.resolved(.stroke,theme: theme)).setStroke()
        let pen = min(2.5,max(0.6,node.style.penwidth*0.7))
        for contour in CanvasGeometry.paths(node) {
            let line = NSBezierPath(); line.lineWidth = pen; line.lineJoinStyle = .round; line.lineCapStyle = .round
            if node.style.effectiveLineStyle == "dashed" { line.setLineDash([4*pen,3*pen],count: 2,phase: 0) }
            if node.style.effectiveLineStyle == "dotted" { line.setLineDash([pen,2*pen],count: 2,phase: 0) }
            let values = points(contour)
            if let first = values.first { line.move(to: first); for p in values.dropFirst() { line.line(to: p) }; line.stroke() }
        }
    }

    static func draw(_ edge: DiagramEdge, in rect: NSRect, theme: String) {
        let pen = min(3,max(0.6,edge.style.penwidth*0.8))
        let geometry = ArrowGeometry.make([.init(x: rect.minX+1,y: rect.midY),.init(x: rect.maxX-1,y: rect.midY)],
            head: edge.direction == "none" ? "none" : edge.style.arrowhead,
            tail: edge.direction == "both" ? edge.style.arrowtail : "none",lineWidth: pen,markerScale: 0.8)
        let color = NSColor(hex: edge.style.resolved(.stroke,theme: theme)); color.setStroke(); color.setFill()
        let line = NSBezierPath(); line.lineWidth = pen; line.lineCapStyle = .round
        if edge.style.lineStyle == "dashed" { line.setLineDash([4*pen,3*pen],count: 2,phase: 0) }
        if edge.style.lineStyle == "dotted" { line.setLineDash([pen,2*pen],count: 2,phase: 0) }
        if let first = geometry.shaft.first { line.move(to: first); for p in geometry.shaft.dropFirst() { line.line(to: p) }; line.stroke() }
        for marker in [geometry.head,geometry.tail].compactMap({ $0 }) {
            let lead = NSBezierPath(); lead.lineWidth = pen; lead.move(to: marker.guide); lead.line(to: marker.base); lead.stroke()
            if marker.kind == "dot" {
                let center = marker.point(3), radius = 3*marker.scale
                NSBezierPath(ovalIn: NSRect(x: center.x-radius,y: center.y-radius,width: radius*2,height: radius*2)).fill()
                continue
            }
            let path = NSBezierPath(); path.lineWidth = max(0.6,marker.scale*1.5); path.lineCapStyle = .round; path.lineJoinStyle = .round
            if let first = marker.polygon.first { path.move(to: first); for p in marker.polygon.dropFirst() { path.line(to: p) } }
            if ["tee","vee","crow"].contains(marker.kind) {
                path.stroke()
                if marker.kind != "tee" { let stem = NSBezierPath(); stem.lineWidth = pen; stem.move(to: marker.base); stem.line(to: marker.tip); stem.stroke() }
            } else { path.close(); path.fill() }
        }
    }

    static func image(_ type: EdgeTypeDefinition,theme: String) -> NSImage {
        let edge = DiagramEdge(id: type.id,source: "source",target: "target",label: "",direction: type.direction,style: type.style)
        return NSImage(size: NSSize(width: 38,height: 24),flipped: false) { rect in
            draw(edge,in: rect,theme: theme); return true
        }
    }
}
