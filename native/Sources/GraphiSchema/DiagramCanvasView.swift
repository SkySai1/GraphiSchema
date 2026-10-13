import AppKit

@MainActor
final class DiagramCanvasView: NSView {
    var onSelect: ((DiagramSelection) -> Void)?
    var onMoveNode: ((String, Double, Double) -> Void)?
    var onResizeNode: ((String, Double, Double) -> Void)?
    var onCreateEdge: ((String, String) -> Void)?
    var onMoveContainer: ((String, Double, Double) -> Void)?
    var onResizeContainer: ((String, Double) -> Void)?
    var onDropPaletteItem: ((PaletteObject, Double, Double, String?) -> Void)?
    var onRequestStyle: (() -> Void)?
    var onDeleteSelection: (() -> Void)?

    private var diagram: DiagramProject?
    private var diagramLayout: DiagramLayout?
    private var nodeByID: [String: DiagramNode] = [:]
    private var containerByID: [String: DiagramContainer] = [:]
    private var edgeByID: [String: DiagramEdge] = [:]
    private var layoutNodeByID: [String: LayoutNode] = [:]
    private var memberPositionsByContainer: [String: [LayoutNode]] = [:]
    private var orderedContainers: [DiagramContainer] = []
    private var selection: DiagramSelection = .project
    private var scale: CGFloat = 80
    private var offset = NSPoint(x: 24, y: 24)
    private var shouldFitOnLayout = true
    private var panStart: NSPoint?
    private var initialOffset = NSPoint.zero
    private var draggingNodeID: String?
    private var dragPointerOffset = NSPoint.zero
    private var didDragNode = false
    private var resizingNodeID: String?
    private var nodeResizeStart: NSPoint?
    private var initialNodeSize: (width: Double, height: Double)?
    private var didResizeNode = false
    private var nodeSizePreview: [String: (width: Double, height: Double)] = [:]
    private var connectingFromNodeID: String?
    private var connectionPointer: NSPoint?
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([PaletteItem.pasteboardType])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    func update(diagram: DiagramProject?, layout: DiagramLayout?, selection: DiagramSelection) {
        let wasEmpty = diagramLayout == nil
        self.diagram = diagram
        if let diagram {
            let base = layout ?? DiagramLayout(engine: diagram.diagram.layoutEngine, width: 4, height: 2.5,
                                               minX: 0, minY: 0, nodes: [], edges: [])
            diagramLayout = layoutWithPendingGeometry(diagram, base: base)
        } else {
            diagramLayout = nil
        }
        self.selection = selection
        nodeByID = Dictionary(uniqueKeysWithValues: (diagram?.nodes ?? []).map { ($0.id, $0) })
        containerByID = Dictionary(uniqueKeysWithValues: (diagram?.containers ?? []).map { ($0.id, $0) })
        edgeByID = Dictionary(uniqueKeysWithValues: (diagram?.edges ?? []).map { ($0.id, $0) })
        layoutNodeByID = Dictionary(uniqueKeysWithValues: (diagramLayout?.nodes ?? []).map { ($0.id, $0) })
        rebuildContainerGeometryIndex()
        dragPreview.removeAll()
        nodeSizePreview.removeAll()
        containerPaddingPreview.removeAll()
        if wasEmpty, diagramLayout != nil { shouldFitOnLayout = true }
        needsDisplay = true
        if shouldFitOnLayout { fitToContent() }
    }

    private func layoutWithPendingGeometry(_ diagram: DiagramProject, base: DiagramLayout) -> DiagramLayout {
        let currentIDs = Set(diagram.nodes.map(\.id))
        var nodes = base.nodes.filter { currentIDs.contains($0.id) }
        let originalPositions = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var nodeIndexes = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
        let horizontal = ["LR", "RL"].contains(diagram.diagram.direction)
        for node in diagram.nodes {
            guard let index = nodeIndexes[node.id] else { continue }
            if diagram.diagram.layoutMode == "manual", let x = node.x, let y = node.y {
                nodes[index].x = x
                nodes[index].y = y
            }
            if let width = node.width { nodes[index].width = width }
            if let height = node.height { nodes[index].height = height }
        }

        var rightExtent = nodes.map { $0.x + $0.width / 2 }.max() ?? 0
        var bottomExtent = nodes.map { $0.y + $0.height / 2 }.max() ?? 0
        var lastX = nodes.last?.x
        var lastY = nodes.last?.y
        for node in diagram.nodes where nodeIndexes[node.id] == nil {
            let width = node.width ?? 1.6
            let height = node.height ?? 0.62
            let x: Double
            let y: Double
            if diagram.diagram.layoutMode == "manual", let manualX = node.x, let manualY = node.y {
                x = manualX; y = manualY
            } else if nodes.isEmpty {
                x = width / 2 + 0.7; y = height / 2 + 0.7
            } else if horizontal {
                x = rightExtent + width / 2 + 0.85
                y = lastY ?? height / 2 + 0.7
            } else {
                x = lastX ?? width / 2 + 0.7
                y = bottomExtent + height / 2 + 0.85
            }
            nodeIndexes[node.id] = nodes.count
            nodes.append(LayoutNode(id: node.id, x: x, y: y, width: width, height: height))
            rightExtent = max(rightExtent, x + width / 2)
            bottomExtent = max(bottomExtent, y + height / 2)
            lastX = x
            lastY = y
        }

        let positions = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let existingEdges = Dictionary(uniqueKeysWithValues: base.edges.map { ($0.id, $0) })
        var edges: [LayoutEdge] = []
        for edge in diagram.edges {
            guard let source = positions[edge.source], let target = positions[edge.target] else { continue }
            if (base.edgeRouting ?? diagram.diagram.edgeRouting) == diagram.diagram.edgeRouting,
               let oldSource = originalPositions[edge.source], let oldTarget = originalPositions[edge.target],
               sameGeometry(source, oldSource), sameGeometry(target, oldTarget),
               let existing = existingEdges[edge.id], existing.source == edge.source, existing.target == edge.target {
                edges.append(existing)
                continue
            }
            let points = routedPoints(source: source, target: target, routing: diagram.diagram.edgeRouting, horizontal: horizontal)
            let start = points[0], end = points[points.count - 1]
            edges.append(LayoutEdge(
                id: edge.id, source: edge.source, target: edge.target, points: points, label: edge.label,
                labelX: (start.x + end.x) / 2, labelY: (start.y + end.y) / 2
            ))
        }
        let minX = min(base.minX, nodes.map { $0.x - $0.width / 2 }.min() ?? base.minX)
        let minY = min(base.minY, nodes.map { $0.y - $0.height / 2 }.min() ?? base.minY)
        let maxX = max(base.minX + base.width, nodes.map { $0.x + $0.width / 2 }.max() ?? 0)
        let maxY = max(base.minY + base.height, nodes.map { $0.y + $0.height / 2 }.max() ?? 0)
        return DiagramLayout(engine: base.engine, edgeRouting: diagram.diagram.edgeRouting, width: maxX - minX,
                             height: maxY - minY, minX: minX, minY: minY, nodes: nodes, edges: edges)
    }

    private func sameGeometry(_ first: LayoutNode, _ second: LayoutNode) -> Bool {
        abs(first.x - second.x) < 0.001 && abs(first.y - second.y) < 0.001
            && abs(first.width - second.width) < 0.001 && abs(first.height - second.height) < 0.001
    }

    private func routedPoints(source: LayoutNode, target: LayoutNode, routing: String, horizontal: Bool) -> [LayoutPoint] {
        let start = clippedPoint(center: source, toward: target)
        let end = clippedPoint(center: target, toward: source)
        if routing == "orthogonal" {
            if horizontal {
                let middleX = (start.x + end.x) / 2
                return [start, LayoutPoint(x: middleX, y: start.y), LayoutPoint(x: middleX, y: end.y), end]
            }
            let middleY = (start.y + end.y) / 2
            return [start, LayoutPoint(x: start.x, y: middleY), LayoutPoint(x: end.x, y: middleY), end]
        }
        if routing == "angled" {
            let bend = horizontal
                ? LayoutPoint(x: (start.x + end.x) / 2, y: start.y)
                : LayoutPoint(x: start.x, y: (start.y + end.y) / 2)
            return [start, bend, end]
        }
        return [start, end]
    }

    private func clippedPoint(center: LayoutNode, toward target: LayoutNode) -> LayoutPoint {
        let dx = target.x - center.x, dy = target.y - center.y
        guard dx != 0 || dy != 0 else { return LayoutPoint(x: center.x, y: center.y) }
        let xScale = dx == 0 ? Double.infinity : center.width / 2 / abs(dx)
        let yScale = dy == 0 ? Double.infinity : center.height / 2 / abs(dy)
        let factor = min(xScale, yScale)
        return LayoutPoint(x: center.x + dx * factor, y: center.y + dy * factor)
    }

    private func rebuildContainerGeometryIndex() {
        memberPositionsByContainer.removeAll(keepingCapacity: true)
        guard let diagram else { orderedContainers = []; return }
        for node in diagram.nodes {
            guard let position = layoutNodeByID[node.id] else { continue }
            var parent = node.containerId
            var visited: Set<String> = []
            while let id = parent, let container = containerByID[id], visited.insert(id).inserted {
                memberPositionsByContainer[id, default: []].append(position)
                parent = container.parentId
            }
        }
        func depth(_ container: DiagramContainer) -> Int {
            var level = 0
            var parent = container.parentId
            var visited: Set<String> = [container.id]
            while let id = parent, let ancestor = containerByID[id], visited.insert(id).inserted {
                level += 1
                parent = ancestor.parentId
            }
            return level
        }
        orderedContainers = diagram.containers.sorted { depth($0) > depth($1) }
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
        drawConnectionPreview()
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
           let container = containerByID[id],
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
        if case .node(let id) = selection,
           let node = nodeByID[id],
           let position = layoutNodeByID[id] {
            let size = nodeSizePreview[id] ?? (node.width ?? position.width, node.height ?? position.height)
            let rect = screenRect(center: NSPoint(x: CGFloat(position.x), y: CGFloat(position.y)),
                                  width: size.width, height: size.height)
            let resizeHandle = NSRect(x: rect.maxX - 8, y: rect.minY - 8, width: 16, height: 16)
            if resizeHandle.contains(point) {
                resizingNodeID = id
                nodeResizeStart = point
                initialNodeSize = size
                didResizeNode = false
                return
            }
            let connector = NSRect(x: rect.maxX - 5, y: rect.midY - 8, width: 16, height: 16)
            if connector.contains(point) {
                connectingFromNodeID = id
                connectionPointer = point
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
            if let edgeID = hitEdge(at: point, diagram: diagram, layout: layout) {
                draggingContainerID = nil
                selection = .edge(edgeID)
                onSelect?(.edge(edgeID))
            } else if let id = hitContainer(at: point, diagram: diagram, layout: layout) {
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
        guard let position = layoutNodeByID[node.id] else { return }
        let center = NSPoint(x: CGFloat(position.x), y: CGFloat(position.y))
        let pointer = worldPoint(for: point)
        dragPointerOffset = NSPoint(x: center.x - pointer.x, y: center.y - pointer.y)
        dragPreview[node.id] = center
        didDragNode = false
        selection = .node(node.id)
        onSelect?(.node(node.id))
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !isReadOnly, let diagram, let layout = diagramLayout else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let node = hitNode(at: point, diagram: diagram, layout: layout) {
            selection = .node(node.id)
            onSelect?(selection)
        } else if let edgeID = hitEdge(at: point, diagram: diagram, layout: layout) {
            selection = .edge(edgeID)
            onSelect?(selection)
        } else if let id = hitContainer(at: point, diagram: diagram, layout: layout) {
            selection = .container(id)
            onSelect?(selection)
        } else {
            return
        }
        needsDisplay = true
        let menu = NSMenu()
        let style = NSMenuItem(title: "Оформление и свойства…", action: #selector(openContextStyle), keyEquivalent: "")
        style.target = self
        menu.addItem(style)
        let delete = NSMenuItem(title: "Удалить", action: #selector(deleteContextSelection), keyEquivalent: "")
        delete.target = self
        menu.addItem(delete)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isReadOnly,
              sender.draggingPasteboard.availableType(from: [PaletteItem.pasteboardType]) != nil
        else { return [] }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !isReadOnly && sender.draggingPasteboard.availableType(from: [PaletteItem.pasteboardType]) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !isReadOnly,
              let value = sender.draggingPasteboard.string(forType: PaletteItem.pasteboardType),
              let item = PaletteLibrary.object(id: value)
        else { return false }
        let screenPoint = convert(sender.draggingLocation, from: nil)
        let world = worldPoint(for: screenPoint)
        let containerID: String?
        if let diagram, let layout = diagramLayout {
            containerID = hitContainer(at: screenPoint, diagram: diagram, layout: layout)
        } else {
            containerID = nil
        }
        onDropPaletteItem?(item, Double(world.x), Double(world.y), containerID)
        return true
    }

    @objc private func openContextStyle() { onRequestStyle?() }
    @objc private func deleteContextSelection() { onDeleteSelection?() }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if connectingFromNodeID != nil {
            connectionPointer = point
            needsDisplay = true
            return
        }
        if let id = resizingNodeID, let nodeResizeStart, let initialNodeSize {
            let width = min(10, max(0.5, initialNodeSize.width + 2 * Double(point.x - nodeResizeStart.x) / Double(scale)))
            let height = min(10, max(0.5, initialNodeSize.height - 2 * Double(point.y - nodeResizeStart.y) / Double(scale)))
            nodeSizePreview[id] = (width, height)
            didResizeNode = true
            needsDisplay = true
            return
        }
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
        if let sourceID = connectingFromNodeID {
            let point = convert(event.locationInWindow, from: nil)
            if let diagram, let layout = diagramLayout,
               let target = hitNode(at: point, diagram: diagram, layout: layout), target.id != sourceID {
                onCreateEdge?(sourceID, target.id)
            }
            connectingFromNodeID = nil
            connectionPointer = nil
            needsDisplay = true
            return
        }
        if panStart != nil {
            panStart = nil
            return
        }
        if let id = resizingNodeID {
            if didResizeNode, let size = nodeSizePreview[id] { onResizeNode?(id, size.width, size.height) }
            resizingNodeID = nil
            nodeResizeStart = nil
            initialNodeSize = nil
            didResizeNode = false
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
        for node in diagram.nodes.reversed() {
            guard let position = layoutNodeByID[node.id] else { continue }
            let center = dragPreview[node.id] ?? NSPoint(x: CGFloat(position.x), y: CGFloat(position.y))
            let size = nodeSizePreview[node.id] ?? (node.width ?? position.width, node.height ?? position.height)
            let width = CGFloat(size.width)
            let height = CGFloat(size.height)
            let rect = NSRect(x: center.x - width / 2,
                              y: center.y - height / 2,
                              width: width, height: height).insetBy(dx: -0.08, dy: -0.08)
            if rect.contains(world) { return node }
        }
        return nil
    }

    private func hitContainer(at point: NSPoint, diagram: DiagramProject, layout: DiagramLayout) -> String? {
        let world = worldPoint(for: point)
        for container in orderedContainers {
            if containerWorldRect(container.id, diagram: diagram, layout: layout)?.contains(world) == true { return container.id }
        }
        return nil
    }

    private func memberPositions(_ containerID: String, diagram: DiagramProject, layout: DiagramLayout) -> [LayoutNode] {
        memberPositionsByContainer[containerID] ?? []
    }

    private func containerWorldRect(_ id: String, diagram: DiagramProject, layout: DiagramLayout) -> NSRect? {
        let nodes = memberPositions(id, diagram: diagram, layout: layout)
        guard let container = containerByID[id], let first = nodes.first else { return nil }
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
        for container in orderedContainers.reversed() {
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

    private func drawEdges(diagram: DiagramProject, layout: DiagramLayout) {
        for edgeLayout in layout.edges {
            guard let edge = edgeByID[edgeLayout.id], edgeLayout.points.count >= 2 else { continue }
            let points = displayedEdgePoints(edge, geometry: edgeLayout, settings: diagram.diagram).map { screenPoint(for: $0) }
            guard points.count >= 2 else { continue }
            let path = NSBezierPath()
            let isSelected = selection == .edge(edge.id)
            if isSelected {
                let highlight = NSBezierPath()
                highlight.lineWidth = max(7, CGFloat(edge.style.penwidth) + 5)
                highlight.lineCapStyle = .round
                highlight.lineJoinStyle = .round
                highlight.move(to: points[0])
                appendEdgeSegments(points, to: highlight)
                NSColor.controlAccentColor.withAlphaComponent(0.28).setStroke()
                highlight.stroke()
            }
            path.lineWidth = isSelected ? max(3, CGFloat(edge.style.penwidth) + 1) : max(1, CGFloat(edge.style.penwidth) * min(scale / 72, 1.4))
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            switch edge.style.lineStyle {
            case "dashed": setDash([6, 4], on: path)
            case "dotted": setDash([1.5, 3], on: path)
            default: break
            }
            NSColor(hex: edge.style.color).setStroke()
            path.move(to: points[0])
            appendEdgeSegments(points, to: path)
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
        for node in diagram.nodes {
            guard let position = layoutNodeByID[node.id] else { continue }
            let center = dragPreview[node.id] ?? NSPoint(x: CGFloat(position.x), y: CGFloat(position.y))
            let size = nodeSizePreview[node.id] ?? (node.width ?? position.width, node.height ?? position.height)
            let rect = screenRect(center: center, width: size.width, height: size.height)
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
            if selected {
                let resizeHandle = NSRect(x: rect.maxX - 5, y: rect.minY - 5, width: 10, height: 10)
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: resizeHandle, xRadius: 2, yRadius: 2).fill()
                let connector = NSRect(x: rect.maxX + 3, y: rect.midY - 4, width: 8, height: 8)
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: connector).fill()
                toolTip = "Перетащите нижний правый маркер, чтобы изменить размер. Потяните правый маркер к другому объекту, чтобы создать связь."
            } else {
                toolTip = nil
            }
        }
    }

    private func drawConnectionPreview() {
        guard let sourceID = connectingFromNodeID, let pointer = connectionPointer,
              let node = nodeByID[sourceID],
              let position = layoutNodeByID[sourceID] else { return }
        let size = nodeSizePreview[sourceID] ?? (node.width ?? position.width, node.height ?? position.height)
        let start = screenPoint(for: NSPoint(x: CGFloat(position.x + size.width / 2), y: CGFloat(position.y)))
        let path = NSBezierPath()
        path.lineWidth = 2
        let dash: [CGFloat] = [5, 4]
        dash.withUnsafeBufferPointer { buffer in
            path.setLineDash(buffer.baseAddress, count: buffer.count, phase: 0)
        }
        path.move(to: start)
        path.line(to: pointer)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    private func displayedEdgePoints(_ edge: DiagramEdge, geometry: LayoutEdge, settings: DiagramSettings) -> [NSPoint] {
        var points = geometry.points
        let hasPreview = dragPreview[edge.source] != nil || dragPreview[edge.target] != nil
            || nodeSizePreview[edge.source] != nil || nodeSizePreview[edge.target] != nil
        if hasPreview, let source = layoutNodeByID[edge.source], let target = layoutNodeByID[edge.target] {
            points = routedPoints(source: previewPosition(source), target: previewPosition(target),
                                  routing: settings.edgeRouting, horizontal: ["LR", "RL"].contains(settings.direction))
        }
        if settings.edgeRouting == "straight", let first = points.first, let last = points.last {
            points = [first, last]
        }
        var result: [NSPoint] = []
        for point in points {
            let next = NSPoint(x: CGFloat(point.x), y: CGFloat(point.y))
            if let last = result.last, hypot(last.x - next.x, last.y - next.y) < 0.00001 { continue }
            result.append(next)
        }
        return result
    }

    private func previewPosition(_ position: LayoutNode) -> LayoutNode {
        var result = position
        if let center = dragPreview[position.id] {
            result.x = Double(center.x)
            result.y = Double(center.y)
        }
        if let size = nodeSizePreview[position.id] {
            result.width = size.width
            result.height = size.height
        }
        return result
    }

    private func appendEdgeSegments(_ points: [NSPoint], to path: NSBezierPath) {
        for point in points.dropFirst() { path.line(to: point) }
    }

    private func hitEdge(at point: NSPoint, diagram: DiagramProject, layout: DiagramLayout) -> String? {
        for edge in layout.edges.reversed() where edge.points.count >= 2 {
            guard let modelEdge = edgeByID[edge.id] else { continue }
            let points = displayedEdgePoints(modelEdge, geometry: edge, settings: diagram.diagram).map { screenPoint(for: $0) }
            for pair in zip(points, points.dropFirst()) where distance(point, toSegmentFrom: pair.0, to: pair.1) <= 8 {
                return edge.id
            }
        }
        return nil
    }

    private func distance(_ point: NSPoint, toSegmentFrom start: NSPoint, to end: NSPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / length))
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
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
