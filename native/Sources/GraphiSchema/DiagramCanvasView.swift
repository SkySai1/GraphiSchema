import AppKit

@MainActor
final class DiagramCanvasView: NSView {
    var onSelect: ((DiagramSelection) -> Void)?
    var onMoveNode: ((String, Double, Double) -> Void)?
    var onMoveContainer: ((String, Double, Double) -> Void)?
    var onResizeContainer: ((String, Double) -> Void)?

    private var diagram: DiagramProject?
    private var diagramLayout: DiagramLayout?
    private var selection: DiagramSelection = .project
    private var scale: CGFloat = 80
    private var offset = NSPoint(x: 24, y: 24)
    private var shouldFitOnLayout = true
    private var panStart: NSPoint?
    private var initialOffset = NSPoint.zero
    private var draggingNodeID: String?
    private var dragPointerOffset = NSPoint.zero
    private var didDragNode = false
    private var draggingContainerID: String?
    private var containerDragStart: NSPoint?
    private var containerMemberCenters: [String: NSPoint] = [:]
    private var didMoveContainer = false
    private var resizingContainerID: String?
    private var resizeStart: NSPoint?
    private var initialContainerPadding: Double?
    private var didResizeContainer = false
    private var dragPreview: [String: NSPoint] = [:]
    private var containerPaddingPreview: [String: Double] = [:]

    var isGridVisible = true { didSet { needsDisplay = true } }
    var isReadOnly = false

    override var acceptsFirstResponder: Bool { true }

    func update(diagram: DiagramProject?, layout: DiagramLayout?, selection: DiagramSelection) {
        let wasEmpty = diagramLayout == nil
        self.diagram = diagram
        diagramLayout = layout
        self.selection = selection
        dragPreview.removeAll()
        containerPaddingPreview.removeAll()
        if wasEmpty, layout != nil { shouldFitOnLayout = true }
        needsDisplay = true
        if shouldFitOnLayout { fitToContent() }
    }

    func zoom(by factor: CGFloat) {
        zoom(by: factor, around: NSPoint(x: bounds.midX, y: bounds.midY))
    }

    func fitToContent() {
        guard let layout = diagramLayout, layout.width > 0, layout.height > 0, bounds.width > 1, bounds.height > 1 else {
            shouldFitOnLayout = true
            return
        }
        let fitScale = min((bounds.width - 48) / CGFloat(layout.width), (bounds.height - 48) / CGFloat(layout.height))
        scale = min(220, max(16, fitScale))
        offset = NSPoint(
            x: (bounds.width - CGFloat(layout.width) * scale) / 2 - CGFloat(layout.minX) * scale,
            y: (bounds.height - CGFloat(layout.height) * scale) / 2 - CGFloat(layout.minY) * scale
        )
        shouldFitOnLayout = false
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        if shouldFitOnLayout { fitToContent() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let background = diagram?.presentation.theme == "dark" ? NSColor(hex: "#111827") : NSColor(hex: "#F5F7FA")
        background.setFill()
        bounds.fill()
        guard let diagram, let layout = diagramLayout else {
            drawMessage("Подготовка геометрии диаграммы…")
            return
        }
        if isGridVisible { drawGrid() }
        drawContainers(diagram: diagram, layout: layout)
        drawEdges(diagram: diagram, layout: layout)
        drawNodes(diagram: diagram, layout: layout)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) {
            zoom(by: pow(1.06, event.scrollingDeltaY), around: point)
        } else {
            offset.x += event.scrollingDeltaX
            offset.y += event.scrollingDeltaY
            needsDisplay = true
        }
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        zoom(by: 1 + event.magnification, around: point)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.option) {
            panStart = point
            initialOffset = offset
            return
        }
        if isReadOnly { return }
        if case .container(let id) = selection,
           let diagram, let layout = diagramLayout,
           let container = diagram.containers.first(where: { $0.id == id }),
           let rect = containerScreenRect(id, diagram: diagram, layout: layout) {
            let handle = NSRect(x: rect.maxX - 9, y: rect.maxY - 9, width: 18, height: 18)
            if handle.contains(point) {
                resizingContainerID = id
                resizeStart = point
                initialContainerPadding = container.padding
                didResizeContainer = false
                return
            }
        }
        guard let diagram, let layout = diagramLayout else {
            draggingNodeID = nil
            draggingContainerID = nil
            resizingContainerID = nil
            didDragNode = false
            onSelect?(.project)
            selection = .project
            needsDisplay = true
            return
        }
        guard let node = hitNode(at: point, diagram: diagram, layout: layout) else {
            draggingNodeID = nil
            didDragNode = false
            if let id = hitContainer(at: point, diagram: diagram, layout: layout) {
                draggingContainerID = id
                containerDragStart = worldPoint(for: point)
                containerMemberCenters = Dictionary(uniqueKeysWithValues: memberPositions(id, diagram: diagram, layout: layout).map {
                    ($0.id, NSPoint(x: CGFloat($0.x), y: CGFloat($0.y)))
                })
                didMoveContainer = false
                selection = .container(id)
                onSelect?(.container(id))
            } else {
                draggingContainerID = nil
                selection = .project
                onSelect?(.project)
            }
            needsDisplay = true
            return
        }
        draggingNodeID = node.id
        guard let position = layout.nodes.first(where: { $0.id == node.id }) else { return }
        let center = NSPoint(x: CGFloat(position.x), y: CGFloat(position.y))
        let pointer = worldPoint(for: point)
        dragPointerOffset = NSPoint(x: center.x - pointer.x, y: center.y - pointer.y)
        dragPreview[node.id] = center
        didDragNode = false
        selection = .node(node.id)
        onSelect?(.node(node.id))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let id = resizingContainerID, let resizeStart, let initialContainerPadding {
            let delta = ((point.x - resizeStart.x) + (point.y - resizeStart.y)) / 2 / scale * 72
            containerPaddingPreview[id] = min(48, max(4, initialContainerPadding + Double(delta)))
            didResizeContainer = true
            needsDisplay = true
            return
        }
        if let panStart {
            offset = NSPoint(
                x: initialOffset.x + point.x - panStart.x,
                y: initialOffset.y + point.y - panStart.y
            )
            needsDisplay = true
            return
        }
        if draggingContainerID != nil, let containerDragStart {
            let world = worldPoint(for: point)
            let delta = NSPoint(x: world.x - containerDragStart.x, y: world.y - containerDragStart.y)
            for (nodeID, center) in containerMemberCenters {
                dragPreview[nodeID] = NSPoint(x: center.x + delta.x, y: center.y + delta.y)
            }
            didMoveContainer = hypot(delta.x, delta.y) > 0.025
            needsDisplay = true
            return
        }
        guard let id = draggingNodeID else { return }
        let pointer = worldPoint(for: point)
        dragPreview[id] = NSPoint(x: pointer.x + dragPointerOffset.x, y: pointer.y + dragPointerOffset.y)
        didDragNode = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if panStart != nil {
            panStart = nil
            return
        }
        if let id = resizingContainerID {
            if didResizeContainer, let padding = containerPaddingPreview[id] { onResizeContainer?(id, padding) }
            resizingContainerID = nil
            resizeStart = nil
            initialContainerPadding = nil
            didResizeContainer = false
            return
        }
        if let id = draggingContainerID {
            if didMoveContainer, let start = containerDragStart {
                let end = worldPoint(for: convert(event.locationInWindow, from: nil))
                onMoveContainer?(id, Double(end.x - start.x), Double(end.y - start.y))
            }
            draggingContainerID = nil
            containerDragStart = nil
            containerMemberCenters.removeAll()
            didMoveContainer = false
            return
        }
        defer {
            draggingNodeID = nil
            didDragNode = false
        }
        guard didDragNode, let id = draggingNodeID, let point = dragPreview[id]
        else { return }
        onMoveNode?(id, Double(point.x), Double(point.y))
    }

    private func zoom(by factor: CGFloat, around anchor: NSPoint) {
        let world = worldPoint(for: anchor)
        scale = min(300, max(12, scale * factor))
        offset = NSPoint(x: anchor.x - world.x * scale, y: anchor.y - world.y * scale)
        needsDisplay = true
    }

    private func worldPoint(for screenPoint: NSPoint) -> NSPoint {
        NSPoint(x: (screenPoint.x - offset.x) / scale, y: (screenPoint.y - offset.y) / scale)
    }

    private func screenPoint(for worldPoint: NSPoint) -> NSPoint {
        NSPoint(x: offset.x + worldPoint.x * scale, y: offset.y + worldPoint.y * scale)
    }

    private func screenRect(center: NSPoint, width: Double, height: Double) -> NSRect {
        let point = screenPoint(for: center)
        return NSRect(x: point.x - CGFloat(width) * scale / 2,
                      y: point.y - CGFloat(height) * scale / 2,
                      width: CGFloat(width) * scale,
                      height: CGFloat(height) * scale)
    }

    private func hitNode(at point: NSPoint, diagram: DiagramProject, layout: DiagramLayout) -> DiagramNode? {
        let world = worldPoint(for: point)
        let positions = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0) })
        for node in diagram.nodes.reversed() {
            guard let position = positions[node.id] else { continue }
            let center = dragPreview[node.id] ?? NSPoint(x: CGFloat(position.x), y: CGFloat(position.y))
            let width = CGFloat(position.width)
            let height = CGFloat(position.height)
            let rect = NSRect(x: center.x - width / 2,
                              y: center.y - height / 2,
                              width: width, height: height).insetBy(dx: -0.08, dy: -0.08)
            if rect.contains(world) { return node }
        }
        return nil
    }

    private func hitContainer(at point: NSPoint, diagram: DiagramProject, layout: DiagramLayout) -> String? {
        let world = worldPoint(for: point)
        let containers = Dictionary(uniqueKeysWithValues: diagram.containers.map { ($0.id, $0) })
        for container in diagram.containers.sorted(by: {
            depth(of: $0, containers: containers) > depth(of: $1, containers: containers)
        }) {
            if containerWorldRect(container.id, diagram: diagram, layout: layout)?.contains(world) == true { return container.id }
        }
        return nil
    }

    private func memberPositions(_ containerID: String, diagram: DiagramProject, layout: DiagramLayout) -> [LayoutNode] {
        let containers = Dictionary(uniqueKeysWithValues: diagram.containers.map { ($0.id, $0) })
        let positions = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0) })
        return diagram.nodes.compactMap { node in
            guard let position = positions[node.id] else { return nil }
            var parent = node.containerId
            while let id = parent, let container = containers[id] {
                if id == containerID { return position }
                parent = container.parentId
            }
            return nil
        }
    }

    private func containerWorldRect(_ id: String, diagram: DiagramProject, layout: DiagramLayout) -> NSRect? {
        guard let container = diagram.containers.first(where: { $0.id == id }),
              let first = memberPositions(id, diagram: diagram, layout: layout).first
        else { return nil }
        let nodes = memberPositions(id, diagram: diagram, layout: layout)
        let firstCenter = dragPreview[first.id] ?? NSPoint(x: CGFloat(first.x), y: CGFloat(first.y))
        var rect = NSRect(x: firstCenter.x - CGFloat(first.width) / 2, y: firstCenter.y - CGFloat(first.height) / 2,
                          width: CGFloat(first.width), height: CGFloat(first.height))
        for node in nodes.dropFirst() {
            let center = dragPreview[node.id] ?? NSPoint(x: CGFloat(node.x), y: CGFloat(node.y))
            let nodeRect = NSRect(x: center.x - CGFloat(node.width) / 2, y: center.y - CGFloat(node.height) / 2,
                                  width: CGFloat(node.width), height: CGFloat(node.height))
            rect = rect.union(nodeRect)
        }
        let padding = containerPaddingPreview[id] ?? container.padding
        let inset = CGFloat(padding / 72)
        return rect.insetBy(dx: -inset, dy: -inset)
    }

    private func containerScreenRect(_ id: String, diagram: DiagramProject, layout: DiagramLayout) -> NSRect? {
        guard let rect = containerWorldRect(id, diagram: diagram, layout: layout) else { return nil }
        return NSRect(x: offset.x + rect.minX * scale, y: offset.y + rect.minY * scale,
                      width: rect.width * scale, height: rect.height * scale)
    }

    private func drawGrid() {
        var step: CGFloat = 0.25
        while step * scale < 22 { step *= 2 }
        let minX = (-offset.x) / scale
        let maxX = (bounds.width - offset.x) / scale
        let minY = (-offset.y) / scale
        let maxY = (bounds.height - offset.y) / scale
        while (maxX - minX) / step > 100 || (maxY - minY) / step > 100 { step *= 2 }
        let path = NSBezierPath()
        path.lineWidth = 0.6
        let color = diagram?.presentation.theme == "dark" ? NSColor.white.withAlphaComponent(0.08) : NSColor(hex: "#64748B").withAlphaComponent(0.12)
        color.setStroke()
        var x = floor(minX / step) * step
        while x <= maxX {
            let sx = offset.x + x * scale
            path.move(to: NSPoint(x: sx, y: 0))
            path.line(to: NSPoint(x: sx, y: bounds.height))
            x += step
        }
        var y = floor(minY / step) * step
        while y <= maxY {
            let sy = offset.y + y * scale
            path.move(to: NSPoint(x: 0, y: sy))
            path.line(to: NSPoint(x: bounds.width, y: sy))
            y += step
        }
        path.stroke()
    }

    private func drawContainers(diagram: DiagramProject, layout: DiagramLayout) {
        let containers = Dictionary(uniqueKeysWithValues: diagram.containers.map { ($0.id, $0) })
        let ordered = diagram.containers.sorted { depth(of: $0, containers: containers) < depth(of: $1, containers: containers) }
        for container in ordered {
            guard let rect = containerScreenRect(container.id, diagram: diagram, layout: layout) else { continue }
            let path = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
            NSColor(hex: container.style.fill).withAlphaComponent(0.42).setFill()
            NSColor(hex: container.style.stroke).setStroke()
            path.lineWidth = 1.2
            path.fill()
            path.stroke()
            drawText(container.label, in: NSRect(x: rect.minX + 10, y: rect.maxY - 25, width: max(80, rect.width - 20), height: 17),
                     color: NSColor(hex: container.style.text), size: 11, weight: .bold, alignment: .left)
            if selection == .container(container.id) {
                let handleRect = NSRect(x: rect.maxX - 5, y: rect.maxY - 5, width: 10, height: 10)
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: handleRect).fill()
            }
        }
    }

    private func depth(of container: DiagramContainer, containers: [String: DiagramContainer]) -> Int {
        var level = 0
        var parent = container.parentId
        while let id = parent, let item = containers[id], level < containers.count {
            level += 1
            parent = item.parentId
        }
        return level
    }

    private func drawEdges(diagram: DiagramProject, layout: DiagramLayout) {
        let styles = Dictionary(uniqueKeysWithValues: diagram.edges.map { ($0.id, $0) })
        for edgeLayout in layout.edges {
            guard let edge = styles[edgeLayout.id], edgeLayout.points.count >= 2 else { continue }
            var worldPoints = edgeLayout.points.map { NSPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
            if let sourcePosition = layout.nodes.first(where: { $0.id == edge.source }),
               let draggedSource = dragPreview[edge.source] {
                let delta = NSPoint(x: draggedSource.x - CGFloat(sourcePosition.x), y: draggedSource.y - CGFloat(sourcePosition.y))
                worldPoints[0].x += delta.x
                worldPoints[0].y += delta.y
                if worldPoints.count > 2 {
                    worldPoints[1].x += delta.x
                    worldPoints[1].y += delta.y
                }
            }
            if let targetPosition = layout.nodes.first(where: { $0.id == edge.target }),
               let draggedTarget = dragPreview[edge.target] {
                let delta = NSPoint(x: draggedTarget.x - CGFloat(targetPosition.x), y: draggedTarget.y - CGFloat(targetPosition.y))
                let last = worldPoints.count - 1
                worldPoints[last].x += delta.x
                worldPoints[last].y += delta.y
                if last > 1 {
                    worldPoints[last - 1].x += delta.x
                    worldPoints[last - 1].y += delta.y
                }
            }
            let points = worldPoints.map { screenPoint(for: $0) }
            let path = NSBezierPath()
            path.lineWidth = max(1, CGFloat(edge.style.penwidth) * min(scale / 72, 1.4))
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            switch edge.style.lineStyle {
            case "dashed": setDash([6, 4], on: path)
            case "dotted": setDash([1.5, 3], on: path)
            default: break
            }
            NSColor(hex: edge.style.color).setStroke()
            path.move(to: points[0])
            if points.count >= 4 {
                var index = 1
                while index + 2 < points.count {
                    path.curve(to: points[index + 2], controlPoint1: points[index], controlPoint2: points[index + 1])
                    index += 3
                }
                if index < points.count { path.line(to: points[points.count - 1]) }
            } else {
                for point in points.dropFirst() { path.line(to: point) }
            }
            path.stroke()
            if edge.direction == "forward" || edge.direction == "both" {
                drawArrow(to: points[points.count - 1], from: points[points.count - 2], color: NSColor(hex: edge.style.color))
            }
            if edge.direction == "both" {
                drawArrow(to: points[0], from: points[1], color: NSColor(hex: edge.style.color))
            }
            if !edge.label.isEmpty, let x = edgeLayout.labelX, let y = edgeLayout.labelY {
                let center = screenPoint(for: NSPoint(x: CGFloat(x), y: CGFloat(y)))
                let textSize = (edge.label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium)])
                let rect = NSRect(x: center.x - textSize.width / 2 - 5, y: center.y - 8,
                                  width: textSize.width + 10, height: 16)
                let pill = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
                NSColor.controlBackgroundColor.withAlphaComponent(0.96).setFill()
                pill.fill()
                drawText(edge.label, in: rect, color: NSColor(hex: edge.style.color), size: 9, weight: .medium, alignment: .center)
            }
        }
    }

    private func drawNodes(diagram: DiagramProject, layout: DiagramLayout) {
        let positions = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0) })
        for node in diagram.nodes {
            guard let position = positions[node.id] else { continue }
            let center = dragPreview[node.id] ?? NSPoint(x: CGFloat(position.x), y: CGFloat(position.y))
            let rect = screenRect(center: center, width: position.width, height: position.height)
            let selected = selection == .node(node.id)
            let path = nodePath(shape: node.shape, rect: rect)
            path.lineWidth = selected ? 2.6 : max(1, CGFloat(node.style.penwidth))
            if selected {
                NSColor.controlAccentColor.setStroke()
            } else {
                NSColor(hex: node.style.stroke).setStroke()
            }
            NSColor(hex: node.style.fill).setFill()
            path.fill()
            path.stroke()
            let fontSize = min(14, max(9, scale * 0.14))
            let textRect = rect.insetBy(dx: 7, dy: 4)
            drawText(node.label, in: textRect, color: NSColor(hex: node.style.text), size: fontSize,
                     weight: .semibold, alignment: .center)
        }
    }

    private func nodePath(shape: String, rect: NSRect) -> NSBezierPath {
        switch shape {
        case "ellipse", "cloud": return NSBezierPath(ovalIn: rect)
        case "diamond":
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.midX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
            path.line(to: NSPoint(x: rect.midX, y: rect.minY))
            path.line(to: NSPoint(x: rect.minX, y: rect.midY))
            path.close()
            return path
        case "hexagon":
            let cut = rect.width * 0.16
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX + cut, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX - cut, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
            path.line(to: NSPoint(x: rect.maxX - cut, y: rect.maxY))
            path.line(to: NSPoint(x: rect.minX + cut, y: rect.maxY))
            path.line(to: NSPoint(x: rect.minX, y: rect.midY))
            path.close()
            return path
        default:
            return NSBezierPath(roundedRect: rect, xRadius: shape == "cylinder" ? 9 : 7, yRadius: 7)
        }
    }

    private func drawArrow(to tip: NSPoint, from previous: NSPoint, color: NSColor) {
        let angle = atan2(tip.y - previous.y, tip.x - previous.x)
        let size: CGFloat = 8
        let left = NSPoint(x: tip.x - size * cos(angle - .pi / 6), y: tip.y - size * sin(angle - .pi / 6))
        let right = NSPoint(x: tip.x - size * cos(angle + .pi / 6), y: tip.y - size * sin(angle + .pi / 6))
        let arrow = NSBezierPath()
        arrow.move(to: tip)
        arrow.line(to: left)
        arrow.line(to: right)
        arrow.close()
        color.setFill()
        arrow.fill()
    }

    private func setDash(_ pattern: [CGFloat], on path: NSBezierPath) {
        pattern.withUnsafeBufferPointer { buffer in
            path.setLineDash(buffer.baseAddress, count: buffer.count, phase: 0)
        }
    }

    private func drawText(_ text: String, in rect: NSRect, color: NSColor, size: CGFloat,
                          weight: NSFont.Weight, alignment: NSTextAlignment) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func drawMessage(_ message: String) {
        let rect = bounds.insetBy(dx: 24, dy: 24)
        drawText(message, in: rect, color: .secondaryLabelColor, size: 13, weight: .regular, alignment: .center)
    }
}
