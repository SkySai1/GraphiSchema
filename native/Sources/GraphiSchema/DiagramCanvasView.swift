import AppKit

@MainActor
final class DiagramCanvasView: NSView {
    var onSelect: ((DiagramSelection) -> Void)?
    var onMoveNode: ((String, Double, Double, String?) -> Void)?
    var onSetNodeZIndex: ((String, Int) -> Void)?
    var onMoveNodeInStack: ((String, Bool) -> Void)?
    var onMoveNodes: ((Set<String>, Double, Double) -> Void)?
    var onResizeNode: ((String, Double, Double) -> Void)?
    var onScaleNodes: ((Set<String>, Double) -> Void)?
    var onEditNodeText: ((String) -> Void)?
    var onCreateEdge: ((String, String) -> Void)?
    var onSetEdgeWaypoints: ((String, [RoutePoint], [LayoutNode]) -> Void)?
    var onReattachEdge: ((String, Bool, String) -> Void)?
    var onMoveContainer: ((String, Double, Double) -> Void)?
    var onResizeContainer: ((String, Double) -> Void)?
    var onResizeEmptyContainer: ((String, Double, Double) -> Void)?
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
    private var draggingNodeIDs: Set<String> = []
    private var groupDragStart: NSPoint?
    private var groupInitialCenters: [String: NSPoint] = [:]
    private var didDragGroup = false
    private var dragPointerOffset = NSPoint.zero
    private var didDragNode = false
    private var resizingNodeID: String?
    private var nodeResizeStart: NSPoint?
    private var initialNodeSize: (width: Double, height: Double)?
    private var didResizeNode = false
    private var nodeSizePreview: [String: (width: Double, height: Double)] = [:]
    private var groupResizeStart: NSPoint?
    private var groupResizeCenter: NSPoint?
    private var groupResizeGeometry: [String: (width: Double, height: Double)] = [:]
    private var didResizeGroup = false
    private var marqueeStart: NSPoint?
    private var selectionMarquee: NSRect?
    private var marqueeBaseSelection: Set<String> = []
    private var longPressTask: Task<Void, Never>?
    private var longPressNodeID: String?
    private var longPressOrigin: NSPoint?
    private var didTriggerLongPress = false
    private var connectingFromNodeID: String?
    private var connectionPointer: NSPoint?
    private var draggingContainerID: String?
    private var containerDragStart: NSPoint?
    private var containerMemberCenters: [String: NSPoint] = [:]
    private var emptyContainerDragOriginCenter: NSPoint?
    private var emptyContainerDragPreview: [String: NSPoint] = [:]
    private var didMoveContainer = false
    private var resizingContainerID: String?
    private var resizeStart: NSPoint?
    private var initialContainerPadding: Double?
    private var didResizeContainer = false
    private var dragPreview: [String: NSPoint] = [:]
    private var containerPaddingPreview: [String: Double] = [:]
    private var emptyContainerSizePreview: [String: (width: Double, height: Double)] = [:]
    private var nodeDropBounds: [String: NSRect] = [:]
    private var dropTargetContainerID: String?
    private var resizingEmptyContainerID: String?
    private var emptyContainerResizeStart: NSPoint?
    private var initialEmptyContainerSize: (width: Double, height: Double)?
    private var endpointDrag: (id: String, source: Bool)?
    private var endpointPointer: NSPoint?

    private var draggingWaypoint: (id: String, index: Int)?
    private var waypointPreview: [String: [RoutePoint]] = [:]
    var inverseTrackpad = false
    var exportBackground: String?

    var isGridVisible = true { didSet { needsDisplay = true } }
    var isReadOnly = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("diagram-canvas")
        registerForDraggedTypes([PaletteItem.pasteboardType])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    func update(diagram: DiagramProject?, layout: DiagramLayout?, selection: DiagramSelection) {
        let wasEmpty = diagramLayout == nil
        let previousSelection = self.selection
        let previousEdges = Dictionary(uniqueKeysWithValues: (self.diagram?.edges ?? []).map { ($0.id, $0) })
        let previousNodes = nodeByID
        self.diagram = diagram
        nodeByID = Dictionary(uniqueKeysWithValues: (diagram?.nodes ?? []).map { ($0.id, $0) })
        if let diagram {
            let base = layout ?? DiagramLayout(engine: diagram.diagram.layoutEngine, width: 4, height: 2.5,
                                               minX: 0, minY: 0, nodes: [], edges: [])
            diagramLayout = layoutWithPendingGeometry(diagram, base: base, previousEdges: previousEdges, previousNodes: previousNodes)
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
        waypointPreview.removeAll()
        containerPaddingPreview.removeAll()
        emptyContainerSizePreview.removeAll()
        emptyContainerDragPreview.removeAll()
        nodeDropBounds.removeAll()
        dropTargetContainerID = nil
        emptyContainerDragOriginCenter = nil
        endpointDrag = nil
        endpointPointer = nil
        if wasEmpty, diagramLayout != nil { shouldFitOnLayout = true }
        needsDisplay = true
        let selectedEmptyContainer: Bool
        if case .container(let id) = selection, let diagram {
            selectedEmptyContainer = memberPositionsByContainer[id]?.isEmpty != false && diagram.containers.contains(where: { $0.id == id })
        } else { selectedEmptyContainer = false }
        if shouldFitOnLayout || (selectedEmptyContainer && previousSelection != selection) { fitToContent() }
    }

    private func layoutWithPendingGeometry(_ diagram: DiagramProject, base: DiagramLayout, previousEdges: [String: DiagramEdge],
                                           previousNodes: [String: DiagramNode]) -> DiagramLayout {
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
            let width = node.width ?? (node.icon == nil ? 1.6 : 1.1)
            let height = node.height ?? (node.icon == nil ? 0.62 : 1.1)
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
               sameRouting(edge, previous: previousEdges[edge.id]),
               sameContour(nodeByID[edge.source]!, previous: previousNodes[edge.source]),
               sameContour(nodeByID[edge.target]!, previous: previousNodes[edge.target]),
               let existing = existingEdges[edge.id], existing.source == edge.source, existing.target == edge.target {
                edges.append(existing)
                continue
            }
            let points = CanvasGeometry.edgePoints(edge, source: source, target: target,
                sourceNode: nodeByID[edge.source]!, targetNode: nodeByID[edge.target]!, settings: diagram.diagram)
                .map { LayoutPoint(x: $0.x, y: $0.y) }
            let start = points[0], end = points[points.count - 1]
            edges.append(LayoutEdge(
                id: edge.id, source: edge.source, target: edge.target, points: points, label: edge.label,
                labelX: (start.x + end.x) / 2, labelY: (start.y + end.y) / 2, normalized: true
            ))
        }
        let containers = Dictionary(uniqueKeysWithValues: diagram.containers.map { ($0.id, $0) })
        var occupiedContainers: Set<String> = []
        for node in diagram.nodes {
            var parent = node.containerId
            while let id = parent, let container = containers[id] {
                occupiedContainers.insert(id)
                parent = container.parentId
            }
        }
        var minX = base.minX, minY = base.minY
        var maxX = base.minX+base.width, maxY = base.minY+base.height
        for node in nodes {
            minX = min(minX, node.x-node.width/2); minY = min(minY, node.y-node.height/2)
            maxX = max(maxX, node.x+node.width/2); maxY = max(maxY, node.y+node.height/2)
        }
        for edge in edges {
            for point in edge.points {
                minX = min(minX, point.x); minY = min(minY, point.y)
                maxX = max(maxX, point.x); maxY = max(maxY, point.y)
            }
        }
        for edge in diagram.edges {
            for point in edge.waypoints {
                minX = min(minX, point.x); minY = min(minY, point.y)
                maxX = max(maxX, point.x); maxY = max(maxY, point.y)
            }
        }
        for container in diagram.containers where !occupiedContainers.contains(container.id) {
            let centerX = container.x ?? base.minX+1.6
            let centerY = container.y ?? base.minY+1.2
            minX = min(minX, centerX-container.width/2); minY = min(minY, centerY-container.height/2)
            maxX = max(maxX, centerX+container.width/2); maxY = max(maxY, centerY+container.height/2)
        }
        return DiagramLayout(engine: base.engine, edgeRouting: diagram.diagram.edgeRouting, width: maxX - minX,
                             height: maxY - minY, minX: minX, minY: minY, nodes: nodes, edges: edges)
    }

    private func sameGeometry(_ first: LayoutNode, _ second: LayoutNode) -> Bool {
        abs(first.x - second.x) < 0.001 && abs(first.y - second.y) < 0.001
            && abs(first.width - second.width) < 0.001 && abs(first.height - second.height) < 0.001
    }

    private func sameRouting(_ edge: DiagramEdge, previous: DiagramEdge?) -> Bool {
        guard let previous else { return true }
        return edge.source == previous.source && edge.target == previous.target && edge.routing == previous.routing
            && edge.sourcePort == previous.sourcePort && edge.targetPort == previous.targetPort
            && edge.waypoints == previous.waypoints
    }

    private func sameContour(_ node: DiagramNode, previous: DiagramNode?) -> Bool {
        guard let previous else { return true }
        return node.shape == previous.shape && node.icon == previous.icon
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

    func fitToContent(minimumScale: CGFloat = 16, maximumScale: CGFloat = 220) {
        guard let layout = diagramLayout, layout.width > 0, layout.height > 0, bounds.width > 1, bounds.height > 1 else {
            shouldFitOnLayout = true
            return
        }
        let fitScale = min((bounds.width - 48) / CGFloat(layout.width), (bounds.height - 48) / CGFloat(layout.height))
        scale = min(maximumScale, max(minimumScale, fitScale))
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
        let background = exportBackground.map { NSColor(hex: $0) }
            ?? (diagram?.presentation.theme == "dark" ? NSColor(hex: "#21172F") : NSColor(hex: diagram?.presentation.background ?? "#FFFFFF"))
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
        drawArrowheads(diagram: diagram, layout: layout)
        drawSelectionOverlay()
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) {
            zoom(by: pow(1.06, event.scrollingDeltaY), around: point)
        } else {
            let delta = Self.scrollOffsetDelta(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
                                               precise: event.hasPreciseScrollingDeltas,
                                               natural: event.isDirectionInvertedFromDevice,
                                               inverse: inverseTrackpad)
            offset.x += delta.x
            offset.y += delta.y
            needsDisplay = true
        }
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        zoom(by: 1 + event.magnification, around: point)
    }

    static func scrollDirection(precise: Bool, natural: Bool, inverse: Bool) -> CGFloat {
        guard precise else { return 1 }
        return natural == inverse ? -1 : 1
    }

    static func scrollOffsetDelta(x: CGFloat, y: CGFloat, precise: Bool, natural: Bool, inverse: Bool) -> NSPoint {
        let direction = scrollDirection(precise: precise, natural: natural, inverse: inverse)
        return NSPoint(x: x * direction, y: y * direction)
    }

    func edgePoints(for id: String) -> [NSPoint] {
        guard let edge = edgeByID[id], let geometry = diagramLayout?.edges.first(where: { $0.id == id }), let settings = diagram?.diagram else { return [] }
        return displayedEdgePoints(edge, geometry: geometry, settings: settings)
    }

    func containerScreenFrame(for id: String) -> NSRect? {
        guard let diagram, let layout = diagramLayout else { return nil }
        return containerScreenRect(id, diagram: diagram, layout: layout)
    }

    func edgeDrawing(for id: String) -> EdgeDrawingGeometry? {
        guard let edge = edgeByID[id], let geometry = diagramLayout?.edges.first(where: { $0.id == id }),
              let settings = diagram?.diagram else { return nil }
        let points = displayedEdgePoints(edge, geometry: geometry, settings: settings).map { screenPoint(for: $0) }
        return drawing(edge, points: points)
    }

    private func edgeLineWidth(_ edge: DiagramEdge) -> CGFloat {
        selection == .edge(edge.id) ? max(3, CGFloat(edge.style.penwidth)+1)
            : max(1, CGFloat(edge.style.penwidth)*min(scale/72, 1.4))
    }

    private func drawing(_ edge: DiagramEdge, points: [NSPoint]) -> EdgeDrawingGeometry {
        ArrowGeometry.make(points, head: ["forward", "both"].contains(edge.direction) ? edge.style.arrowhead : "none",
                           tail: edge.direction == "both" ? edge.style.arrowtail : "none", lineWidth: edgeLineWidth(edge))
    }

    var nodePositions: [LayoutNode] { diagramLayout?.nodes ?? [] }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        cancelLongPress(resetTrigger: true)
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.option) {
            panStart = point
            initialOffset = offset
            return
        }
        if isReadOnly { return }
        if case .edge(let id) = selection,
           let edge = edgeByID[id], let geometry = diagramLayout?.edges.first(where: { $0.id == id }),
           let settings = diagram?.diagram {
            let points = displayedEdgePoints(edge, geometry: geometry, settings: settings)
            if let first = points.first, hypot(screenPoint(for: first).x-point.x, screenPoint(for: first).y-point.y) <= 11 {
                endpointDrag = (id, true); endpointPointer = point; return
            }
            if let last = points.last, hypot(screenPoint(for: last).x-point.x, screenPoint(for: last).y-point.y) <= 11 {
                endpointDrag = (id, false); endpointPointer = point; return
            }
        }
        if case .edge(let id) = selection, let edge = edgeByID[id], let geometry = diagramLayout?.edges.first(where: { $0.id == id }), let settings = diagram?.diagram {
            let handles = edge.waypoints.isEmpty
                ? [routeMidpoint(displayedEdgePoints(edge, geometry: geometry, settings: settings))]
                : edge.waypoints.map { NSPoint(x: $0.x, y: $0.y) }
            for (index, handle) in handles.enumerated() {
                let center = screenPoint(for: handle)
                if hypot(center.x-point.x, center.y-point.y) <= 9 {
                    waypointPreview[id] = edge.waypoints.isEmpty ? [RoutePoint(x: handle.x, y: handle.y)] : edge.waypoints
                    draggingWaypoint = (id, index)
                    return
                }
            }
        }

        if case .container(let id) = selection,
           let diagram, let layout = diagramLayout,
           let container = containerByID[id],
           let rect = containerScreenRect(id, diagram: diagram, layout: layout) {
            let handle = NSRect(x: rect.maxX - 9, y: rect.maxY - 9, width: 18, height: 18)
            if handle.contains(point) {
                if memberPositions(id, diagram: diagram, layout: layout).isEmpty {
                    resizingEmptyContainerID = id
                    emptyContainerResizeStart = point
                    initialEmptyContainerSize = (container.width, container.height)
                    return
                }
                resizingContainerID = id
                resizeStart = point
                initialContainerPadding = container.padding
                didResizeContainer = false
                return
            }
        }
        if selectedNodeIDs.count > 1,
           let selectionBounds = nodeSelectionBounds(for: selectedNodeIDs),
           NSRect(x: selectionBounds.maxX - 9, y: selectionBounds.minY - 9, width: 18, height: 18).contains(point) {
            groupResizeStart = point
            groupResizeCenter = NSPoint(x: selectionBounds.midX, y: selectionBounds.midY)
            groupResizeGeometry = Dictionary(uniqueKeysWithValues: selectedNodeIDs.compactMap { id in
                guard let position = layoutNodeByID[id], let node = nodeByID[id] else { return nil }
                let size = nodeSizePreview[id] ?? (node.width ?? position.width, node.height ?? position.height)
                return (id, size)
            })
            didResizeGroup = false
            return
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
            draggingNodeIDs.removeAll()
            didDragNode = false
            if let edgeID = hitEdge(at: point, diagram: diagram, layout: layout) {
                draggingContainerID = nil
                if event.clickCount == 2, let edge = edgeByID[edgeID], edge.waypoints.count < 32 {
                    let world = worldPoint(for: point)
                    var bends = edge.waypoints
                    // Insert after the nearest existing anchor segment, preserving user order.
                    let anchors = [layoutNodeByID[edge.source].map { NSPoint(x: $0.x, y: $0.y) } ?? world]
                        + bends.map { NSPoint(x: $0.x, y: $0.y) }
                        + [layoutNodeByID[edge.target].map { NSPoint(x: $0.x, y: $0.y) } ?? world]
                    let segment = zip(anchors, anchors.dropFirst()).enumerated().min {
                        distance(world, toSegmentFrom: $0.element.0, to: $0.element.1) < distance(world, toSegmentFrom: $1.element.0, to: $1.element.1)
                    }?.offset ?? bends.count
                    bends.insert(RoutePoint(x: world.x, y: world.y), at: min(segment, bends.count))
                    onSetEdgeWaypoints?(edgeID, bends, layout.nodes)
                }
                selection = .edge(edgeID)
                onSelect?(.edge(edgeID))
            } else if let id = hitContainer(at: point, diagram: diagram, layout: layout) {
                draggingContainerID = id
                containerDragStart = worldPoint(for: point)
                if memberPositions(id, diagram: diagram, layout: layout).isEmpty,
                   let rect = containerWorldRect(id, diagram: diagram, layout: layout) {
                    emptyContainerDragOriginCenter = NSPoint(x: rect.midX, y: rect.midY)
                }
                containerMemberCenters = Dictionary(uniqueKeysWithValues: memberPositions(id, diagram: diagram, layout: layout).map {
                    ($0.id, NSPoint(x: CGFloat($0.x), y: CGFloat($0.y)))
                })
                didMoveContainer = false
                selection = .container(id)
                onSelect?(.container(id))
            } else {
                draggingContainerID = nil
                marqueeStart = point
                selectionMarquee = NSRect(origin: point, size: .zero)
                marqueeBaseSelection = event.modifierFlags.contains(.shift) ? selectedNodeIDs : []
            }
            needsDisplay = true
            return
        }
        let priorSelection = selectedNodeIDs
        if event.modifierFlags.contains(.shift) {
            var updated = priorSelection
            if updated.contains(node.id) {
                updated.remove(node.id)
                setNodeSelection(updated)
                onSelect?(selection)
                needsDisplay = true
                return
            }
            updated.insert(node.id)
            setNodeSelection(updated)
            onSelect?(selection)
        } else if !priorSelection.contains(node.id) || priorSelection.count <= 1 {
            selection = .node(node.id)
            onSelect?(selection)
        }
        let activeIDs = selectedNodeIDs
        guard let position = layoutNodeByID[node.id] else { return }
        if activeIDs.count > 1 {
            draggingNodeIDs = activeIDs
            groupDragStart = worldPoint(for: point)
            groupInitialCenters = Dictionary(uniqueKeysWithValues: activeIDs.compactMap { id in
                guard let nodePosition = layoutNodeByID[id] else { return nil }
                return (id, dragPreview[id] ?? NSPoint(x: CGFloat(nodePosition.x), y: CGFloat(nodePosition.y)))
            })
            didDragGroup = false
            for (id, center) in groupInitialCenters { dragPreview[id] = center }
            scheduleLongPress(for: node.id, at: point)
            needsDisplay = true
            return
        }
        draggingNodeID = node.id
        let center = dragPreview[node.id] ?? NSPoint(x: CGFloat(position.x), y: CGFloat(position.y))
        nodeDropBounds = Dictionary(uniqueKeysWithValues: orderedContainers.compactMap { container -> (String, NSRect)? in
            guard let rect = containerWorldRect(container.id, diagram: diagram, layout: layout) else { return nil }
            return (container.id, rect)
        })
        dropTargetContainerID = containerAtDropPoint(center)
        let pointer = worldPoint(for: point)
        dragPointerOffset = NSPoint(x: center.x - pointer.x, y: center.y - pointer.y)
        dragPreview[node.id] = center
        didDragNode = false
        scheduleLongPress(for: node.id, at: point)
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !isReadOnly, let diagram, let layout = diagramLayout else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let node = hitNode(at: point, diagram: diagram, layout: layout) {
            if !selectedNodeIDs.contains(node.id) {
                selection = .node(node.id)
                onSelect?(selection)
            }
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
        if case .node(let nodeID) = selection {
            nodeStackMenuItems(for: nodeID).forEach(menu.addItem)
            let editText = NSMenuItem(title: "Текст и размещение…", action: #selector(editContextNodeText), keyEquivalent: "")
            editText.target = self
            editText.representedObject = nodeID
            menu.addItem(editText)
        }
        if case .edge(let edgeID) = selection, edgeByID[edgeID]?.waypoints.isEmpty == false {
            let resetRoute = NSMenuItem(title: "Сбросить маршрут этой связи", action: #selector(resetContextRoute), keyEquivalent: "")
            resetRoute.target = self
            menu.addItem(resetRoute)
        }
        let delete = NSMenuItem(title: "Удалить", action: #selector(deleteContextSelection), keyEquivalent: "")
        delete.target = self
        menu.addItem(delete)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func nodeStackMenuItems(for id: String) -> [NSMenuItem] {
        [
            ("Переместить на передний план", #selector(contextMoveNodeToFront(_:))),
            ("Переместить на задний план", #selector(contextMoveNodeToBack(_:))),
            ("Указать z-index…", #selector(contextSetNodeZIndex(_:))),
        ].map { entry in
            let item = NSMenuItem(title: entry.0, action: entry.1, keyEquivalent: "")
            item.target = self
            item.representedObject = id
            return item
        }
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
    @objc private func editContextNodeText(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onEditNodeText?(id)
    }
    @objc private func resetContextRoute() {
        guard case .edge(let id) = selection, let edge = edgeByID[id] else { return }
        onSetEdgeWaypoints?(id, [], diagramLayout?.nodes ?? [])
        waypointPreview.removeValue(forKey: edge.id)
    }
    @objc private func contextMoveNodeToFront(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onMoveNodeInStack?(id, true)
    }
    @objc private func contextMoveNodeToBack(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onMoveNodeInStack?(id, false)
    }
    @objc private func contextSetNodeZIndex(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = "Порядок отображения объекта"
        alert.informativeText = "Значение от −1 000 000 до 1 000 000. Больший z-index отображается поверх меньшего."
        alert.addButton(withTitle: "Применить")
        alert.addButton(withTitle: "Отмена")
        let field = NSTextField(string: String(nodeByID[id]?.effectiveZIndex ?? 0))
        field.frame = NSRect(x: 0, y: 0, width: 180, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let value = Int(field.stringValue), (-1_000_000...1_000_000).contains(value) else { return }
        onSetNodeZIndex?(id, value)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let origin = longPressOrigin, hypot(point.x - origin.x, point.y - origin.y) > 6 {
            cancelLongPress()
        }
        if endpointDrag != nil {
            endpointPointer = point
            needsDisplay = true
            return
        }
        if let handle = draggingWaypoint, var bends = waypointPreview[handle.id] {
            let world = worldPoint(for: point)
            bends[handle.index] = RoutePoint(x: min(1000, max(-1000, world.x)), y: min(1000, max(-1000, world.y)))
            waypointPreview[handle.id] = bends
            needsDisplay = true
            return
        }
        if connectingFromNodeID != nil {
            connectionPointer = point
            needsDisplay = true
            return
        }
        if let start = groupResizeStart, let center = groupResizeCenter {
            let startVector = NSPoint(x: start.x - center.x, y: start.y - center.y)
            let currentVector = NSPoint(x: point.x - center.x, y: point.y - center.y)
            let vectorLengthSquared = max(1, startVector.x * startVector.x + startVector.y * startVector.y)
            let rawFactor = (currentVector.x * startVector.x + currentVector.y * startVector.y) / vectorLengthSquared
            let minFactor = groupResizeGeometry.values.map { max(0.5 / $0.width, 0.5 / $0.height) }.max() ?? 0.1
            let maxFactor = groupResizeGeometry.values.map { min(10 / $0.width, 10 / $0.height) }.min() ?? 10
            let factor = min(maxFactor, max(minFactor, rawFactor))
            for (id, size) in groupResizeGeometry {
                nodeSizePreview[id] = (size.width * factor, size.height * factor)
            }
            didResizeGroup = abs(factor - 1) > 0.005
            needsDisplay = true
            return
        }
        if let start = marqueeStart {
            selectionMarquee = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                      width: abs(point.x - start.x), height: abs(point.y - start.y))
            needsDisplay = true
            return
        }
        if let id = resizingNodeID, let nodeResizeStart, let initialNodeSize {
            var width = min(10, max(0.5, initialNodeSize.width + 2 * Double(point.x - nodeResizeStart.x) / Double(scale)))
            var height = min(10, max(0.5, initialNodeSize.height - 2 * Double(point.y - nodeResizeStart.y) / Double(scale)))
            if nodeByID[id]?.icon != nil && !event.modifierFlags.contains(.shift) {
                let widthFactor = width/initialNodeSize.width, heightFactor = height/initialNodeSize.height
                let factor = abs(widthFactor-1) >= abs(heightFactor-1) ? widthFactor : heightFactor
                let bounded = min(min(10/initialNodeSize.width, 10/initialNodeSize.height),
                                  max(max(0.5/initialNodeSize.width, 0.5/initialNodeSize.height), factor))
                width = initialNodeSize.width*bounded; height = initialNodeSize.height*bounded
            }
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
        if let id = resizingEmptyContainerID, let emptyContainerResizeStart, let initialEmptyContainerSize {
            let startWorld = worldPoint(for: emptyContainerResizeStart)
            let endWorld = worldPoint(for: point)
            emptyContainerSizePreview[id] = (min(20, max(1, initialEmptyContainerSize.width+Double(endWorld.x-startWorld.x))),
                                             min(20, max(1, initialEmptyContainerSize.height+Double(endWorld.y-startWorld.y))))
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
            if let id = draggingContainerID, containerMemberCenters.isEmpty,
               let origin = emptyContainerDragOriginCenter {
                emptyContainerDragPreview[id] = NSPoint(x: origin.x + delta.x, y: origin.y + delta.y)
            }
            didMoveContainer = hypot(delta.x, delta.y) > 0.025
            needsDisplay = true
            return
        }
        if !draggingNodeIDs.isEmpty, let start = groupDragStart {
            let world = worldPoint(for: point)
            let delta = NSPoint(x: world.x - start.x, y: world.y - start.y)
            for (id, center) in groupInitialCenters {
                dragPreview[id] = NSPoint(x: center.x + delta.x, y: center.y + delta.y)
            }
            didDragGroup = hypot(delta.x, delta.y) > 0.015
            needsDisplay = true
            return
        }
        guard let id = draggingNodeID else { return }
        let pointer = worldPoint(for: point)
        let center = NSPoint(x: pointer.x + dragPointerOffset.x, y: pointer.y + dragPointerOffset.y)
        dragPreview[id] = center
        dropTargetContainerID = containerAtDropPoint(center)
        didDragNode = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        cancelLongPress()
        if didTriggerLongPress {
            didTriggerLongPress = false
            return
        }
        if let drag = endpointDrag {
            let point = convert(event.locationInWindow, from: nil)
            if let diagram, let layout = diagramLayout, let node = hitNode(at: point, diagram: diagram, layout: layout) {
                onReattachEdge?(drag.id, drag.source, node.id)
            }
            endpointDrag = nil; endpointPointer = nil
            needsDisplay = true
            return
        }
        if let handle = draggingWaypoint {
            let bends = waypointPreview[handle.id] ?? []
            draggingWaypoint = nil
            onSetEdgeWaypoints?(handle.id, bends, diagramLayout?.nodes ?? [])
            waypointPreview.removeValue(forKey: handle.id)
            needsDisplay = true
            return
        }
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
        if groupResizeStart != nil {
            let factor = groupResizeGeometry.compactMap { id, original -> Double? in
                guard let resized = nodeSizePreview[id] else { return nil }
                return resized.width / original.width
            }.first
            if didResizeGroup, let factor {
                onScaleNodes?(Set(groupResizeGeometry.keys), factor)
            }
            groupResizeStart = nil
            groupResizeCenter = nil
            groupResizeGeometry.removeAll()
            didResizeGroup = false
            return
        }
        if let start = marqueeStart {
            let end = convert(event.locationInWindow, from: nil)
            let rect = NSRect(x: min(start.x, end.x), y: min(start.y, end.y),
                              width: abs(end.x - start.x), height: abs(end.y - start.y))
            var ids = marqueeBaseSelection
            if hypot(end.x - start.x, end.y - start.y) > 3 {
                for id in nodeByID.keys where nodeScreenRect(for: id)?.intersects(rect) == true { ids.insert(id) }
            }
            setNodeSelection(ids)
            onSelect?(selection)
            marqueeStart = nil
            selectionMarquee = nil
            marqueeBaseSelection.removeAll()
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
        if let id = resizingEmptyContainerID {
            if didResizeContainer, let size = emptyContainerSizePreview[id] { onResizeEmptyContainer?(id, size.width, size.height) }
            resizingEmptyContainerID = nil
            emptyContainerResizeStart = nil
            initialEmptyContainerSize = nil
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
            emptyContainerDragOriginCenter = nil
            emptyContainerDragPreview.removeAll()
            didMoveContainer = false
            return
        }
        if !draggingNodeIDs.isEmpty {
            if didDragGroup, let start = groupDragStart {
                let end = worldPoint(for: convert(event.locationInWindow, from: nil))
                onMoveNodes?(draggingNodeIDs, Double(end.x - start.x), Double(end.y - start.y))
            }
            draggingNodeIDs.removeAll()
            groupDragStart = nil
            groupInitialCenters.removeAll()
            didDragGroup = false
            return
        }
        defer {
            draggingNodeID = nil
            didDragNode = false
        }
        guard didDragNode, let id = draggingNodeID, let point = dragPreview[id] else { return }
        onMoveNode?(id, Double(point.x), Double(point.y), dropTargetContainerID)
        nodeDropBounds.removeAll()
        dropTargetContainerID = nil
    }

    private func scheduleLongPress(for nodeID: String, at point: NSPoint) {
        cancelLongPress(resetTrigger: true)
        longPressNodeID = nodeID
        longPressOrigin = point
        longPressTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) }
            catch { return }
            guard let self, self.longPressNodeID == nodeID else { return }
            self.longPressTask = nil
            self.longPressNodeID = nil
            self.longPressOrigin = nil
            self.didTriggerLongPress = true
            self.draggingNodeID = nil
            self.draggingNodeIDs.removeAll()
            self.groupDragStart = nil
            self.groupInitialCenters.removeAll()
            self.didDragNode = false
            self.didDragGroup = false
            self.onEditNodeText?(nodeID)
        }
    }

    private func cancelLongPress(resetTrigger: Bool = false) {
        longPressTask?.cancel()
        longPressTask = nil
        longPressNodeID = nil
        longPressOrigin = nil
        if resetTrigger { didTriggerLongPress = false }
    }

    private func zoom(by factor: CGFloat, around anchor: NSPoint) {
        let world = worldPoint(for: anchor)
        scale = min(300, max(12, scale * factor))
        offset = NSPoint(x: anchor.x - world.x * scale, y: anchor.y - world.y * scale)
        needsDisplay = true
    }

    func worldPoint(for screenPoint: NSPoint) -> NSPoint {
        NSPoint(x: (screenPoint.x - offset.x) / scale, y: (screenPoint.y - offset.y) / scale)
    }

    func screenPoint(for worldPoint: NSPoint) -> NSPoint {
        NSPoint(x: offset.x + worldPoint.x * scale, y: offset.y + worldPoint.y * scale)
    }

    private func screenRect(center: NSPoint, width: Double, height: Double) -> NSRect {
        let point = screenPoint(for: center)
        return NSRect(x: point.x - CGFloat(width) * scale / 2,
                      y: point.y - CGFloat(height) * scale / 2,
                      width: CGFloat(width) * scale,
                      height: CGFloat(height) * scale)
    }

    private var selectedNodeIDs: Set<String> {
        switch selection {
        case .node(let id): return [id]
        case .nodes(let ids): return ids
        default: return []
        }
    }

    private func setNodeSelection(_ ids: Set<String>) {
        let valid = ids.intersection(Set(nodeByID.keys))
        if valid.count == 1, let id = valid.first { selection = .node(id) }
        else if valid.count > 1 { selection = .nodes(valid) }
        else { selection = .project }
    }

    private func nodeScreenRect(for id: String) -> NSRect? {
        guard let node = nodeByID[id], let position = layoutNodeByID[id] else { return nil }
        let center = dragPreview[id] ?? NSPoint(x: CGFloat(position.x), y: CGFloat(position.y))
        let size = nodeSizePreview[id] ?? (node.width ?? position.width, node.height ?? position.height)
        return screenRect(center: center, width: size.width, height: size.height)
    }

    private func nodeSelectionBounds(for ids: Set<String>) -> NSRect? {
        let rects = ids.compactMap { nodeScreenRect(for: $0) }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -5, dy: -5)
    }

    private func drawSelectionOverlay() {
        if let selectionMarquee {
            let path = NSBezierPath(roundedRect: selectionMarquee, xRadius: 3, yRadius: 3)
            path.lineWidth = 1
            let dash: [CGFloat] = [4, 3]
            path.setLineDash(dash, count: dash.count, phase: 0)
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
        guard selectedNodeIDs.count > 1, let rect = nodeSelectionBounds(for: selectedNodeIDs) else { return }
        let outline = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        outline.lineWidth = 1
        let dash: [CGFloat] = [5, 3]
        outline.setLineDash(dash, count: dash.count, phase: 0)
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        outline.stroke()
        let handle = NSRect(x: rect.maxX - 7, y: rect.minY - 7, width: 14, height: 14)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: handle, xRadius: 3, yRadius: 3).fill()
    }

    private func hitNode(at point: NSPoint, diagram: DiagramProject, layout: DiagramLayout) -> DiagramNode? {
        let world = worldPoint(for: point)
        for node in DiagramNodeStackOrder.sorted(diagram.nodes).reversed() {
            guard let position = layoutNodeByID[node.id] else { continue }
            let center = dragPreview[node.id] ?? NSPoint(x: CGFloat(position.x), y: CGFloat(position.y))
            let size = nodeSizePreview[node.id] ?? (node.width ?? position.width, node.height ?? position.height)
            let width = CGFloat(size.width)
            let height = CGFloat(size.height)
            let rect = NSRect(x: center.x - width / 2,
                              y: center.y - height / 2,
                              width: width, height: height).insetBy(dx: -0.08, dy: -0.08)
            if !rect.contains(world) {
                if node.icon != nil, NSRect(x: center.x-max(width, 2.2)/2, y: center.y-height/2-0.3, width: max(width, 2.2), height: 0.3).contains(world) { return node }
                continue
            }
            let contours = CanvasGeometry.paths(node)
            let closed = node.icon.flatMap { CanvasGeometry.icons[$0]?.closed } ?? [true]
            let p = previewPosition(position)
            for (index, contour) in contours.enumerated() {
                let points = contour.map { CanvasGeometry.world($0, in: p) }
                let path = NSBezierPath(); path.move(to: points[0]); appendEdgeSegments(points, to: path)
                if closed.indices.contains(index) && closed[index] { path.close(); if path.contains(world) { return node } }
                if zip(points, points.dropFirst()).contains(where: { distance(world, toSegmentFrom: $0.0, to: $0.1) <= 0.08 }) { return node }
            }
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

    private func containerAtDropPoint(_ point: NSPoint) -> String? {
        orderedContainers.first { nodeDropBounds[$0.id]?.contains(point) == true }?.id
    }

    private func memberPositions(_ containerID: String, diagram: DiagramProject, layout: DiagramLayout) -> [LayoutNode] {
        memberPositionsByContainer[containerID] ?? []
    }

    private func containerWorldRect(_ id: String, diagram: DiagramProject, layout: DiagramLayout) -> NSRect? {
        let nodes = memberPositions(id, diagram: diagram, layout: layout)
        guard let container = containerByID[id] else { return nil }
        if nodes.isEmpty {
            let center = emptyContainerDragPreview[id]
                ?? NSPoint(x: container.x ?? layout.minX+1.6, y: container.y ?? layout.minY+1.2)
            let size = emptyContainerSizePreview[id] ?? (container.width, container.height)
            return NSRect(x: center.x-size.width/2, y: center.y-size.height/2, width: size.width, height: size.height)
        }
        guard let first = nodes.first else { return nil }
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
            let isDropTarget = container.id == dropTargetContainerID && draggingNodeID != nil
            let fill = NSColor(hex: container.style.fill)
            (isDropTarget ? NSColor.controlAccentColor.withAlphaComponent(0.08) : fill.withAlphaComponent(fill.alphaComponent * 0.42)).setFill()
            (isDropTarget ? NSColor.controlAccentColor : NSColor(hex: container.style.stroke)).setStroke()
            path.lineWidth = isDropTarget ? 2.4 : 1.2
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
            let drawing = drawing(edge, points: points)
            let path = NSBezierPath()
            let isSelected = selection == .edge(edge.id)
            if isSelected {
                let highlight = NSBezierPath()
                highlight.lineWidth = max(7, CGFloat(edge.style.penwidth) + 5)
                highlight.lineCapStyle = .round
                highlight.lineJoinStyle = .round
                let highlighted = (drawing.tail.map { [$0.tip] } ?? [])+drawing.shaft+(drawing.head.map { [$0.tip] } ?? [])
                highlight.move(to: highlighted[0])
                appendEdgeSegments(highlighted, to: highlight)
                NSColor.controlAccentColor.withAlphaComponent(0.28).setStroke()
                highlight.stroke()
            }
            path.lineWidth = edgeLineWidth(edge)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            switch edge.style.lineStyle {
            case "dashed": setDash([6, 4], on: path)
            case "dotted": setDash([1.5, 3], on: path)
            default: break
            }
            NSColor(hex: edge.style.color).setStroke()
            let dashed = ["dashed", "dotted"].contains(edge.style.lineStyle)
            var shaft = drawing.shaft
            if dashed {
                if drawing.head != nil { shaft.removeLast() }
                if drawing.tail != nil { shaft.removeFirst() }
            }
            path.move(to: shaft[0])
            appendEdgeSegments(shaft, to: path)
            path.stroke()
            for marker in (dashed ? [drawing.head, drawing.tail] : []).compactMap({ $0 }) {
                let lead = NSBezierPath()
                lead.lineWidth = path.lineWidth
                lead.move(to: marker.guide); lead.line(to: marker.base)
                lead.stroke()
            }
            if isSelected {
                for (index, endpoint) in [points[0], points[points.count-1]].enumerated() {
                    let marker = NSBezierPath(ovalIn: NSRect(x: endpoint.x-6, y: endpoint.y-6, width: 12, height: 12))
                    (index == 0 ? NSColor.systemGreen : NSColor.systemOrange).setFill(); marker.fill()
                    NSColor.white.setStroke(); marker.lineWidth = 1.5; marker.stroke()
                }
                let handles = (waypointPreview[edge.id] ?? edge.waypoints).map { NSPoint(x: $0.x, y: $0.y) }
                let centers = handles.isEmpty ? [routeMidpoint(points.map { worldPoint(for: $0) })] : handles
                for center in centers {
                    let screen = screenPoint(for: center)
                    let marker = NSBezierPath(ovalIn: NSRect(x: screen.x-4, y: screen.y-4, width: 8, height: 8))
                    NSColor.controlAccentColor.setFill(); marker.fill()
                    NSColor.white.setStroke(); marker.lineWidth = 1; marker.stroke()
                }
            }
            if let drag = endpointDrag, drag.id == edge.id, let pointer = endpointPointer {
                let fixed = drag.source ? points.last! : points[0]
                let preview = NSBezierPath(); preview.lineWidth = 2; preview.move(to: fixed); preview.line(to: pointer)
                NSColor.controlAccentColor.setStroke(); preview.stroke()
                let target = NSBezierPath(ovalIn: NSRect(x: pointer.x-6, y: pointer.y-6, width: 12, height: 12))
                NSColor.controlAccentColor.setFill(); target.fill()
            }
            if !edge.label.isEmpty, let x = edgeLayout.labelX, let y = edgeLayout.labelY {
                let followsPath = !edge.waypoints.isEmpty || waypointPreview[edge.id] != nil || edge.routing != nil
                    || edge.sourcePort != "auto" || edge.targetPort != "auto" || nodeByID[edge.source]?.icon != nil || nodeByID[edge.target]?.icon != nil
                    || dragPreview[edge.source] != nil || dragPreview[edge.target] != nil || nodeSizePreview[edge.source] != nil || nodeSizePreview[edge.target] != nil
                var labelPoint = NSPoint(x: x, y: y)
                if followsPath { labelPoint = routeMidpoint(points.map { worldPoint(for: $0) }); labelPoint.y += 0.15 }
                let center = screenPoint(for: labelPoint)
                let textSize = (edge.label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium)])
                let rect = NSRect(x: center.x - textSize.width / 2 - 5, y: center.y - 8,
                                  width: textSize.width + 10, height: 16)
                let pill = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
                NSColor.controlBackgroundColor.withAlphaComponent(0.96).setFill()
                pill.fill()
                drawText(edge.label, in: rect, color: diagram.presentation.theme == "dark" ? .white : NSColor(hex: "#172238"), size: 9, weight: .medium, alignment: .center)
            }
        }
    }

    private func drawArrowheads(diagram: DiagramProject, layout: DiagramLayout) {
        for edgeLayout in layout.edges {
            guard let edge = edgeByID[edgeLayout.id] else { continue }
            guard let drawing = edgeDrawing(for: edge.id) else { continue }
            let color = NSColor(hex: edge.style.color)
            for marker in [drawing.head, drawing.tail].compactMap({ $0 }) {
                drawArrow(marker, color: color, lineWidth: edgeLineWidth(edge))
            }
        }
    }

    private func drawNodes(diagram: DiagramProject, layout: DiagramLayout) {
        for node in DiagramNodeStackOrder.sorted(diagram.nodes) {
            guard let position = layoutNodeByID[node.id] else { continue }
            let center = dragPreview[node.id] ?? NSPoint(x: CGFloat(position.x), y: CGFloat(position.y))
            let size = nodeSizePreview[node.id] ?? (node.width ?? position.width, node.height ?? position.height)
            let rect = screenRect(center: center, width: size.width, height: size.height)
            let selected = selectedNodeIDs.contains(node.id)
            let contours = CanvasGeometry.paths(node)
            let closed = node.icon.flatMap { CanvasGeometry.icons[$0]?.closed } ?? [true]
            let baseContour = contours.indices.filter { closed.indices.contains($0) && closed[$0] }
                .max { contourArea(contours[$0]) < contourArea(contours[$1]) }
            if let baseContour {
                let points = contours[baseContour].map { NSPoint(x: rect.minX+$0.x*rect.width, y: rect.minY+$0.y*rect.height) }
                if let first = points.first {
                    let fill = NSBezierPath(); fill.move(to: first); appendEdgeSegments(points, to: fill); fill.close()
                    NSColor(hex: node.style.fill).setFill(); fill.fill()
                }
            }
            for (index, contour) in contours.enumerated() {
                let path = NSBezierPath()
                let points = contour.map { NSPoint(x: rect.minX+$0.x*rect.width, y: rect.minY+$0.y*rect.height) }
                guard let first = points.first else { continue }
                path.move(to: first); appendEdgeSegments(points, to: path)
                path.lineJoinStyle = .round; path.lineCapStyle = .round
                path.lineWidth = selected ? max(2, CGFloat(node.style.penwidth)) : max(1, CGFloat(node.style.penwidth))
                if closed.indices.contains(index) && closed[index] { path.close() }
                NSColor(hex: node.style.stroke).setStroke()
                path.stroke()
            }
            let fontSize = min(14, max(9, scale * 0.14))
            let textRect = rect.insetBy(dx: min(8, rect.width * 0.08), dy: min(6, rect.height * 0.08))
            let autoContrast = exportBackground == nil && node.icon != nil && diagram.presentation.theme == "dark"
                && ["#172238", "#0F172A"].contains(String(node.style.text.uppercased().prefix(7)))
            let color = autoContrast ? NSColor.white : NSColor(hex: node.style.text)
            let horizontal: NSTextAlignment = switch node.effectiveLabelAlignment {
            case "left": .left
            case "right": .right
            default: .center
            }
            drawText(node.label, in: textRect, color: color, size: fontSize, weight: .semibold,
                     alignment: horizontal, verticalAlignment: node.effectiveLabelVerticalAlignment)
            if selected && selectedNodeIDs.count == 1 {
                drawResizeGlyph(center: NSPoint(x: rect.maxX - 1, y: rect.minY + 1))
                drawConnectionGlyph(center: NSPoint(x: rect.maxX + 3, y: rect.midY))
                toolTip = "Нижний правый значок масштабирует объект; Shift позволяет менять пропорции фигуры. Стрелка справа создаёт связь."
            } else {
                toolTip = nil
            }
        }
    }

    private func drawResizeGlyph(center: NSPoint) {
        let path = NSBezierPath()
        path.lineWidth = 1.8
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let tips = [NSPoint(x: center.x + 5, y: center.y + 5), NSPoint(x: center.x - 5, y: center.y - 5)]
        NSColor.controlAccentColor.setStroke()
        for tip in tips {
            path.move(to: center)
            path.line(to: tip)
            let direction = atan2(tip.y - center.y, tip.x - center.x)
            for wing in [-0.72, 0.72] {
                path.move(to: tip)
                path.line(to: NSPoint(x: tip.x - 2.7*cos(direction + wing), y: tip.y - 2.7*sin(direction + wing)))
            }
        }
        path.stroke()
    }

    private func drawConnectionGlyph(center: NSPoint) {
        let path = NSBezierPath()
        path.lineWidth = 1.8
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: center.x - 5, y: center.y - 4))
        path.line(to: NSPoint(x: center.x + 4, y: center.y + 4))
        path.move(to: NSPoint(x: center.x, y: center.y + 4))
        path.line(to: NSPoint(x: center.x + 4, y: center.y + 4))
        path.line(to: NSPoint(x: center.x + 4, y: center.y))
        NSColor.controlAccentColor.setStroke()
        path.stroke()
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
        guard let source = layoutNodeByID[edge.source], let target = layoutNodeByID[edge.target],
              let sourceNode = nodeByID[edge.source], let targetNode = nodeByID[edge.target] else { return [] }
        let hasPreview = dragPreview[edge.source] != nil || dragPreview[edge.target] != nil
            || nodeSizePreview[edge.source] != nil || nodeSizePreview[edge.target] != nil
        return CanvasGeometry.edgePoints(edge, source: previewPosition(source), target: previewPosition(target),
            sourceNode: sourceNode, targetNode: targetNode, settings: settings,
            proposed: hasPreview ? nil : geometry.points.map { NSPoint(x: $0.x, y: $0.y) }, waypoints: waypointPreview[edge.id],
            proposedNormalized: !hasPreview && waypointPreview[edge.id] == nil && geometry.normalized == true)
    }

    func routeMidpoint(_ points: [NSPoint]) -> NSPoint {
        guard let first = points.first else { return .zero }
        let lengths = zip(points, points.dropFirst()).map { hypot($0.1.x-$0.0.x, $0.1.y-$0.0.y) }
        var remaining = lengths.reduce(0, +)/2
        for (index, length) in lengths.enumerated() {
            if remaining <= length && length > 0 {
                let a = points[index], b = points[index+1], t = remaining/length
                return NSPoint(x: a.x+(b.x-a.x)*t, y: a.y+(b.y-a.y)*t)
            }
            remaining -= length
        }
        return first
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

    private func contourArea(_ points: [NSPoint]) -> CGFloat {
        let closed = Array(points.dropFirst()) + [points.first ?? .zero]
        return abs(zip(points, closed).reduce(CGFloat.zero) { $0 + $1.0.x*$1.1.y-$1.1.x*$1.0.y })/2
    }

    private func hitEdge(at point: NSPoint, diagram: DiagramProject, layout: DiagramLayout) -> String? {
        for edge in layout.edges.reversed() where edge.points.count >= 2 {
            guard let modelEdge = edgeByID[edge.id] else { continue }
            let route = displayedEdgePoints(modelEdge, geometry: edge, settings: diagram.diagram).map { screenPoint(for: $0) }
            let drawing = drawing(modelEdge, points: route)
            let points = (drawing.tail.map { [$0.tip] } ?? [])+drawing.shaft+(drawing.head.map { [$0.tip] } ?? [])
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

    private func drawArrow(_ marker: ArrowMarkerGeometry, color: NSColor, lineWidth: CGFloat) {
        let kind = marker.kind
        if kind == "dot" {
            let center = marker.point(3), radius = 3*marker.scale
            color.setFill(); NSBezierPath(ovalIn: NSRect(x: center.x-radius, y: center.y-radius, width: 2*radius, height: 2*radius)).fill(); return
        }
        let points = marker.polygon
        if ["vee", "crow"].contains(kind) {
            let stem = NSBezierPath(); stem.lineWidth = lineWidth
            stem.move(to: marker.base); stem.line(to: marker.tip)
            color.setStroke(); stem.stroke()
        }
        let arrow = NSBezierPath(); arrow.move(to: points[0]); appendEdgeSegments(points, to: arrow)
        color.setFill(); color.setStroke(); arrow.lineWidth = 1.5*marker.scale
        if !["tee", "vee", "crow"].contains(kind) { arrow.close(); arrow.fill() }
        arrow.stroke()
    }

    private func setDash(_ pattern: [CGFloat], on path: NSBezierPath) {
        pattern.withUnsafeBufferPointer { buffer in
            path.setLineDash(buffer.baseAddress, count: buffer.count, phase: 0)
        }
    }

    private func drawText(_ text: String, in rect: NSRect, color: NSColor, size: CGFloat,
                          weight: NSFont.Weight, alignment: NSTextAlignment, verticalAlignment: String = "middle") {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let measured = (text as NSString).boundingRect(with: NSSize(width: rect.width, height: rect.height),
                                                      options: [.usesLineFragmentOrigin], attributes: attributes)
        var textRect = rect
        textRect.size.height = min(rect.height, max(font.ascender - font.descender, measured.height))
        switch verticalAlignment {
        case "top": textRect.origin.y = rect.maxY - textRect.height
        case "bottom": textRect.origin.y = rect.minY
        default: textRect.origin.y = rect.midY - textRect.height / 2
        }
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }

    private func drawMessage(_ message: String) {
        let rect = bounds.insetBy(dx: 24, dy: 24)
        drawText(message, in: rect, color: .secondaryLabelColor, size: 13, weight: .regular, alignment: .center)
    }
}
