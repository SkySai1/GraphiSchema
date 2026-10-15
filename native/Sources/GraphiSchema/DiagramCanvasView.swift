import AppKit

@MainActor
final class DiagramCanvasView: NSView, NSMenuItemValidation {
    var onSelect: ((DiagramSelection) -> Void)?
    var onMoveNode: ((String, Double, Double, String?) -> Void)?
    var onCreateEmptyContainer: ((Double, Double) -> Void)?
    var onDetachNodeFromContainer: ((String) -> Void)?
    var onSetNodeZIndex: ((String, Int) -> Void)?
    var onMoveNodeInStack: ((String, Bool) -> Void)?
    var onMoveNodes: (([String: NSPoint], [String: String]) -> Void)?
    var onResizeNode: ((String, Double, Double) -> Void)?
    var onRotateNodes: ((Set<String>, Double) -> Void)?
    var onSetEdgeZIndex: ((Set<String>, Int?, Bool) -> Void)?
    var onScaleNodes: ((Set<String>, Double) -> Void)?
    var onTransformNode: ((String, Double, Double, Double, Double) -> Void)?
    var onCopySelection: (() -> Void)?
    var onPasteSelection: (() -> Void)?
    var onDuplicateSelection: ((Double, Double, [String: String]) -> Void)?
    var onEditNodeText: ((String) -> Void)?
    var onEditElementText: ((DiagramSelection) -> Void)?
    var onResetSelectedRoutes: (() -> Void)?
    var onCreateEdge: ((String, String, String) -> Void)?
    var onSetEdgeWaypoints: ((String, [RoutePoint], [LayoutNode]) -> Void)?
    var onReattachEdge: ((String, Bool, String, String) -> Void)?
    var onMoveContainer: ((String, Double, Double) -> Void)?
    var onResizeContainer: ((String, Double) -> Void)?
    var onResizeEmptyContainer: ((String, Double, Double) -> Void)?
    var onDropPaletteItem: ((PaletteObject, Double, Double, String?) -> Void)?
    var onRequestStyle: (() -> Void)?
    var onRequestColor: ((DiagramColorParameter) -> Void)?
    var onSetStyle: ((DiagramSelection, DiagramStyleChange) -> Void)?
    var onDeleteSelection: (() -> Void)?

    private struct CrossingInput: Equatable {
        var id: String
        var shaft: [NSPoint]
        var radius: CGFloat
    }
    private var crossingInputs: [CrossingInput] = []
    private var crossingPaths: [String:[NSPoint]] = [:]

    private var diagram: DiagramProject?
    private var diagramLayout: DiagramLayout?
    private var sourceLayout: DiagramLayout?
    private var nodeByID: [String: DiagramNode] = [:]
    private var containerByID: [String: DiagramContainer] = [:]
    private var edgeByID: [String: DiagramEdge] = [:]
    private var layoutNodeByID: [String: LayoutNode] = [:]
    private var memberPositionsByContainer: [String: [LayoutNode]] = [:]
    private var orderedContainers: [DiagramContainer] = []
    private var containersWithChildren: Set<String> = []
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
    private var rotationIDs: Set<String> = []
    private var rotationDelta: Double = 0
    private var rotationDrag: (center: NSPoint, angle: Double)?
    private var rotationCommitTask: Task<Void,Never>?
    private var resizingNodeID: String?
    private var nodeResizeStart: NSPoint?
    private var initialNodeSize: (width: Double, height: Double)?
    private var didResizeNode = false
    private var stretchDirection: NSPoint?
    private var stretchInitialCenter: NSPoint?
    private var dragGestureStart: NSPoint?
    private var singleDragInitialCenter: NSPoint?
    private var lockedDragAxis: Bool? // true: horizontal; false: vertical
    private var pendingShiftToggleID: String?
    private var isCopyDrag = false
    private var nodeSizePreview: [String: (width: Double, height: Double)] = [:]
    private var groupResizeStart: NSPoint?
    private var groupResizeCenter: NSPoint?
    private var groupResizeGeometry: [String: (width: Double, height: Double)] = [:]
    private var didResizeGroup = false
    private var marqueeStart: NSPoint?
    private var selectionMarquee: NSRect?
    private var marqueeBaseEdges: Set<String> = []
    private var marqueeBaseSelection: Set<String> = []
    private var longPressTask: Task<Void, Never>?
    private var longPressSelection: DiagramSelection?
    private var longPressOrigin: NSPoint?
    private var didTriggerLongPress = false
    private var connectingFromNodeID: String?
    private var connectionPointer: NSPoint?
    private var draggingContainerID: String?
    private var containerDragStart: NSPoint?
    private var containerMemberCenters: [String: NSPoint] = [:]
    private var containerEmptyCenters: [String: NSPoint] = [:]
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
    private var endpointDrag: (id: String, source: Bool, origin: NSPoint)?
    private var endpointPointer: NSPoint?
    private var didDragEndpoint = false

    private struct ConnectionTarget {
        let nodeID: String
        let port: String
    }
    private struct AttachmentHandleCache {
        let shape: String
        let icon: String?
        let rotation: Double
        let rect: NSRect
        let handles: [(port: String, center: NSPoint)]
    }
    private var attachmentHandleCache: [String: AttachmentHandleCache] = [:]

    private var draggingWaypoint: (id: String, index: Int)?
    private var waypointPreview: [String: [RoutePoint]] = [:]
    var inverseTrackpad = false
    var alignmentGuides = true
    private var alignmentVertical: CGFloat?
    private var alignmentHorizontal: CGFloat?
    var exportBackground: String?
    var pdfStyle: DiagramPDFCanvasStyle?

    var isGridVisible = true { didSet { needsDisplay = true } }
    var isReadOnly = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("diagram-canvas")
        registerForDraggedTypes([PaletteItem.pasteboardType])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, !rotationIDs.isEmpty { finishRotation(cancel: true); return }
        if event.keyCode == 53, endpointDrag != nil || connectingFromNodeID != nil {
            endpointDrag = nil; endpointPointer = nil; didDragEndpoint = false
            connectingFromNodeID = nil; connectionPointer = nil
            needsDisplay = true
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            deleteSelection(nil)
            return
        }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copy(nil); return
            case "v": paste(nil); return
            case "d": duplicate(nil); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) { onCopySelection?() }
    @objc func paste(_ sender: Any?) { if !isReadOnly { onPasteSelection?() } }
    @objc func duplicate(_ sender: Any?) { if !isReadOnly { onDuplicateSelection?(0.35, -0.35, [:]) } }
    @objc func deleteSelection(_ sender: Any?) { if !isReadOnly { onDeleteSelection?() } }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !isReadOnly, selectedNodeIDs.count == 1, let id = selectedNodeIDs.first else { return }
        for handle in nodeStretchFrames(for: id) {
            let cursor: NSCursor = handle.direction.x == 0 ? .resizeUpDown : handle.direction.y == 0 ? .resizeLeftRight : .crosshair
            addCursorRect(handle.frame, cursor: cursor)
        }
    }

    func update(diagram: DiagramProject?, layout: DiagramLayout?, selection: DiagramSelection) {
        // Selecting an element synchronously refreshes the canvas through the controller.
        // Keep the in-flight gesture when the project and layout have not changed.
        if self.diagram == diagram, sourceLayout == layout {
            self.selection = selection
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            return
        }
        let wasEmpty = diagramLayout == nil
        let changedProject = self.diagram?.project.id != diagram?.project.id
        if changedProject { finishRotation(cancel: true) }
        let previousSelection = self.selection
        let previousEdges = Dictionary(uniqueKeysWithValues: (self.diagram?.edges ?? []).map { ($0.id, $0) })
        let previousNodes = nodeByID
        self.diagram = diagram
        sourceLayout = layout
        nodeByID = Dictionary(uniqueKeysWithValues: (diagram?.nodes ?? []).map { ($0.id, $0) })
        if let diagram {
            let base = layout ?? DiagramLayout(engine: diagram.diagram.layoutEngine, width: 4, height: 2.5,
                                               minX: 0, minY: 0, nodes: [], edges: [])
            diagramLayout = layoutWithPendingGeometry(diagram, base: base, previousEdges: previousEdges, previousNodes: previousNodes)
        } else {
            diagramLayout = nil
        }
        self.selection = selection
        window?.invalidateCursorRects(for: self)
        nodeByID = Dictionary(uniqueKeysWithValues: (diagram?.nodes ?? []).map { ($0.id, $0) })
        containerByID = Dictionary(uniqueKeysWithValues: (diagram?.containers ?? []).map { ($0.id, $0) })
        edgeByID = Dictionary(uniqueKeysWithValues: (diagram?.edges ?? []).map { ($0.id, $0) })
        if changedProject { attachmentHandleCache.removeAll() }
        else { attachmentHandleCache = attachmentHandleCache.filter { nodeByID[$0.key] != nil } }
        layoutNodeByID = Dictionary(uniqueKeysWithValues: (diagramLayout?.nodes ?? []).map { ($0.id, $0) })
        rebuildContainerGeometryIndex()
        let activeDragIDs = draggingNodeIDs
            .union(draggingNodeID.map { Set([$0]) } ?? [])
            .union(resizingNodeID.map { Set([$0]) } ?? [])
            .union(draggingContainerID == nil ? [] : Set(containerMemberCenters.keys))
        dragPreview = dragPreview.filter { activeDragIDs.contains($0.key) && nodeByID[$0.key] != nil }
        nodeSizePreview = nodeSizePreview.filter { $0.key == resizingNodeID || groupResizeGeometry[$0.key] != nil }
        waypointPreview.removeAll()
        containerPaddingPreview.removeAll()
        emptyContainerSizePreview.removeAll()
        if draggingContainerID == nil { emptyContainerDragPreview.removeAll() }
        if draggingNodeID == nil, draggingNodeIDs.isEmpty {
            nodeDropBounds.removeAll()
            dropTargetContainerID = nil
        }
        if changedProject || endpointDrag.map({ edgeByID[$0.id] == nil }) == true {
            endpointDrag = nil; endpointPointer = nil; didDragEndpoint = false
        }
        if changedProject || connectingFromNodeID.map({ nodeByID[$0] == nil }) == true {
            connectingFromNodeID = nil; connectionPointer = nil
        }
        if wasEmpty, diagramLayout != nil { shouldFitOnLayout = true }
        needsDisplay = true
        let selectedEmptyContainer: Bool
        if case .container(let id) = selection, let diagram {
            selectedEmptyContainer = isEmptyContainer(id) && diagram.containers.contains(where: { $0.id == id })
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
                             height: maxY - minY, minX: minX, minY: minY, nodes: nodes, edges: edges, containers: base.containers)
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
        return node.shape == previous.shape && node.icon == previous.icon && node.effectiveRotation == previous.effectiveRotation
    }

    private func rebuildContainerGeometryIndex() {
        memberPositionsByContainer.removeAll(keepingCapacity: true)
        guard let diagram else { orderedContainers = []; containersWithChildren.removeAll(); return }
        containersWithChildren = Set(diagram.containers.compactMap(\.parentId))
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

    /// Build a vector scene at 72 pt/in. Page fitting happens once, outside the
    /// canvas, so labels, strokes, arrowheads and containers keep their ratios.
    func pdfSceneData() -> Data {
        scale = 72; offset = .zero; shouldFitOnLayout = false
        guard let diagram, let layout = diagramLayout else { return Data() }
        var frame = NSRect.null
        for node in diagram.nodes {
            if let rect = nodeVisualRect(for: node.id) { frame = frame.union(rect) }
        }
        for rect in containerWorldRects(diagram: diagram, layout: layout, atScale: 72).values {
            frame = frame.union(NSRect(x: rect.minX*72, y: rect.minY*72, width: rect.width*72, height: rect.height*72))
        }
        for edge in diagram.edges {
            let points = edgePoints(for: edge.id).map { screenPoint(for: $0) }
            for point in points { frame = frame.union(NSRect(x: point.x, y: point.y, width: 0.01, height: 0.01)) }
            if let drawing = edgeDrawing(for: edge.id) {
                for marker in [drawing.head, drawing.tail].compactMap({ $0 }) {
                    frame = frame.union(NSRect(x: marker.tip.x-8*marker.scale, y: marker.tip.y-8*marker.scale,
                                              width: 16*marker.scale, height: 16*marker.scale))
                }
            }
            guard !edge.label.isEmpty else { continue }
            let geometry = layout.edges.first { $0.id == edge.id }
            let center = pdfStyle?.edgeLabels[edge.id]
                ?? NSPoint(x: geometry?.labelX ?? 0, y: geometry?.labelY ?? 0)
            let size = (edge.label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: edge.style.effectiveFontSize, weight: .medium)])
            frame = frame.union(NSRect(x: center.x*72-size.width/2-5, y: center.y*72-max(16,size.height+4)/2,
                                      width: size.width+10, height: max(16,size.height+4)))
        }
        if frame.isNull || frame.isEmpty { frame = NSRect(x: 0, y: 0, width: 180, height: 120) }
        let pen = max(diagram.nodes.map(\.style.penwidth).max() ?? 1,
                      diagram.edges.map(\.style.penwidth).max() ?? 1,
                      diagram.containers.map { $0.style.effectivePenwidth }.max() ?? 1)
        frame = frame.insetBy(dx: -max(8, pen), dy: -max(8, pen))
        offset = NSPoint(x: -frame.minX, y: -frame.minY)
        setFrameSize(frame.size)
        bounds = NSRect(origin: .zero, size: frame.size)
        layoutSubtreeIfNeeded()
        return dataWithPDF(inside: bounds)
    }

    func fitToContent(minimumScale: CGFloat = 16, maximumScale: CGFloat = 220) {
        guard let diagram, let layout = diagramLayout, layout.width > 0, layout.height > 0, bounds.width > 1, bounds.height > 1 else {
            shouldFitOnLayout = true
            return
        }
        let availableWidth = max(1, bounds.width-48), availableHeight = max(1, bounds.height-48)
        func contentBounds(at candidate: CGFloat) -> NSRect {
            var frame = NSRect(x: layout.minX, y: layout.minY, width: layout.width, height: layout.height)
            for node in diagram.nodes {
                guard let position = layoutNodeByID[node.id] else { continue }
                let p = previewPosition(position)
                frame = frame.union(CanvasGeometry.visualBounds(NSRect(x: p.x-p.width/2,y: p.y-p.height/2,width: p.width,height: p.height),rotation: displayedNode(node).effectiveRotation))
            }
            for container in containerWorldRects(diagram: diagram, layout: layout, atScale: candidate).values {
                frame = frame.union(container)
            }
            return frame
        }
        if diagram.containers.isEmpty {
            let content = contentBounds(at: scale)
            let fitScale = min(availableWidth/max(0.01,content.width), availableHeight/max(0.01,content.height))
            scale = min(maximumScale, max(minimumScale, fitScale))
        } else {
            // Fixed-size headers must be included at the final export/viewport
            // scale, rather than shrunk with Graphviz's original bounding box.
            var lower = minimumScale, upper = max(minimumScale, maximumScale)
            for _ in 0..<24 {
                let candidate = (lower+upper)/2
                let frame = contentBounds(at: candidate)
                if frame.width*candidate <= availableWidth && frame.height*candidate <= availableHeight { lower = candidate }
                else { upper = candidate }
            }
            scale = lower
        }
        let frame = contentBounds(at: scale)
        offset = NSPoint(
            x: (bounds.width-frame.width*scale)/2-frame.minX*scale,
            y: (bounds.height-frame.height*scale)/2-frame.minY*scale
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
            ?? NSColor(hex: diagram?.presentation.canvasBackground ?? "#FFFFFF")
        background.setFill()
        bounds.fill()
        guard let diagram, let layout = diagramLayout else {
            drawMessage("Подготовка геометрии диаграммы…")
            return
        }
        if isGridVisible { drawGrid() }
        if isCopyDrag {
            // Draw the unchanged source graph and then the copy preview. The model
            // receives the entire duplication as one command on mouseUp.
            let centers = dragPreview
            let emptyCenters = emptyContainerDragPreview
            dragPreview.removeAll()
            emptyContainerDragPreview.removeAll()
            drawContainers(diagram: diagram, layout: layout, showSelection: false)
            drawEdges(diagram: diagram, layout: layout)
            drawNodes(diagram: diagram, layout: layout, showSelection: false)
            drawArrowheads(diagram: diagram, layout: layout)
            dragPreview = centers
            emptyContainerDragPreview = emptyCenters
            if didDragNode || didDragGroup || didMoveContainer {
                let ids = Set(centers.keys)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.cgContext.setAlpha(0.7)
                if let root = draggingContainerID {
                    var containers: Set<String> = [root]
                    var expanded = true
                    while expanded {
                        expanded = false
                        for container in diagram.containers where container.parentId.map(containers.contains) == true {
                            if containers.insert(container.id).inserted { expanded = true }
                        }
                    }
                    drawContainers(diagram: diagram, layout: layout, onlyIDs: containers)
                }
                drawNodes(diagram: diagram, layout: layout, onlyIDs: ids)
                NSGraphicsContext.restoreGraphicsState()
            }
        } else {
            drawContainers(diagram: diagram, layout: layout)
            drawEdges(diagram: diagram, layout: layout)
            drawNodes(diagram: diagram, layout: layout)
            drawArrowheads(diagram: diagram, layout: layout)
            drawConnectionPreview()
            drawEdgeEndpointHandles()
        }
        drawSelectionOverlay()
        drawAttachmentOverlay()
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

    private func displayedNode(_ node: DiagramNode) -> DiagramNode {
        guard rotationIDs.contains(node.id) else { return node }
        var result = node; result.rotation = node.effectiveRotation+rotationDelta; return result
    }

    override func rotate(with event: NSEvent) {
        guard !isReadOnly, !selectedNodeIDs.isEmpty else { super.rotate(with: event); return }
        if rotationIDs.isEmpty { rotationIDs = selectedNodeIDs; rotationDelta = 0 }
        rotationDelta += Double(event.rotation)
        attachmentHandleCache.removeAll(); needsDisplay = true
        rotationCommitTask?.cancel()
        if event.phase == .cancelled { finishRotation(cancel: true) }
        else if event.phase == .ended { finishRotation() }
        else {
            rotationCommitTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                self?.finishRotation()
            }
        }
    }

    override func endGesture(with event: NSEvent) {
        if rotationDrag == nil { finishRotation() }
        super.endGesture(with: event)
    }

    private func finishRotation(cancel: Bool = false) {
        rotationCommitTask?.cancel(); rotationCommitTask = nil
        let ids = rotationIDs, delta = rotationDelta
        rotationIDs = []; rotationDelta = 0; rotationDrag = nil
        attachmentHandleCache.removeAll(); needsDisplay = true
        if !cancel && abs(delta)>0.001 { onRotateNodes?(ids,delta) }
    }

    private func nodeVisualRect(for id: String) -> NSRect? {
        guard let rect = nodeScreenRect(for: id), let node = nodeByID[id] else { return nil }
        return CanvasGeometry.visualBounds(rect,rotation: displayedNode(node).effectiveRotation)
    }
    private func rotationHandle(for id: String) -> NSRect? {
        guard let rect = nodeVisualRect(for: id) else { return nil }
        return Self.controlFrame(center: .init(x: rect.midX,y: rect.maxY+24))
    }

    static func scrollDirection(precise: Bool, natural: Bool, inverse: Bool) -> CGFloat {
        guard precise else { return 1 }
        return natural == inverse ? -1 : 1
    }

    static func scrollOffsetDelta(x: CGFloat, y: CGFloat, precise: Bool, natural: Bool, inverse: Bool) -> NSPoint {
        let direction = scrollDirection(precise: precise, natural: natural, inverse: inverse)
        // Scroll deltas use device coordinates (Y down); this NSView has Y up.
        return NSPoint(x: x * direction, y: -y * direction)
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
        max(0.25, CGFloat(edge.style.penwidth)*min(scale/72, 1.4))
    }

    private func drawing(_ edge: DiagramEdge, points: [NSPoint]) -> EdgeDrawingGeometry {
        ArrowGeometry.make(points, head: ["forward", "both"].contains(edge.direction) ? edge.style.arrowhead : "none",
                           tail: edge.direction == "both" ? edge.style.arrowtail : "none", lineWidth: edgeLineWidth(edge),
                           markerScale: pdfStyle?.arrowSize ?? 1)
    }

    var nodePositions: [LayoutNode] { diagramLayout?.nodes ?? [] }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        cancelLongPress(resetTrigger: true)
        let point = convert(event.locationInWindow, from: nil)
        dragGestureStart = worldPoint(for: point)
        lockedDragAxis = nil
        pendingShiftToggleID = nil
        isCopyDrag = false
        if event.modifierFlags.contains(.option) {
            panStart = point
            initialOffset = offset
            return
        }
        if isReadOnly { return }
        if case .node(let id) = selection, let frame = rotationHandle(for: id), frame.contains(point), let rect = nodeScreenRect(for: id) {
            let center = NSPoint(x: rect.midX,y: rect.midY)
            rotationIDs = [id]; rotationDelta = 0
            rotationDrag = (center,atan2(point.y-center.y,point.x-center.x)*180 / .pi)
            return
        }
        if case .edge(let id) = selection,
           let edge = edgeByID[id], let geometry = diagramLayout?.edges.first(where: { $0.id == id }),
           let settings = diagram?.diagram {
            let points = displayedEdgePoints(edge, geometry: geometry, settings: settings)
            if let first = points.first, hypot(screenPoint(for: first).x-point.x, screenPoint(for: first).y-point.y) <= 11 {
                endpointDrag = (id, true, point); endpointPointer = point; didDragEndpoint = false
                needsDisplay = true
                return
            }
            if let last = points.last, hypot(screenPoint(for: last).x-point.x, screenPoint(for: last).y-point.y) <= 11 {
                endpointDrag = (id, false, point); endpointPointer = point; didDragEndpoint = false
                needsDisplay = true
                return
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
                    scheduleElementLongPress(.edge(id), at: point)
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
                if isEmptyContainer(id) {
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
           Self.controlFrame(center: Self.resizeControlCenter(for: selectionBounds)).contains(point) {
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
           let position = layoutNodeByID[id],
           let rect = nodeScreenRect(for: id) {
            let size = nodeSizePreview[id] ?? (node.width ?? position.width, node.height ?? position.height)
            let controlRect = nodeVisualRect(for: id) ?? rect
            let resizeHandle = Self.controlFrame(center: Self.resizeControlCenter(for: controlRect))
            if resizeHandle.contains(point) {
                resizingNodeID = id
                stretchDirection = nil
                stretchInitialCenter = nil
                nodeResizeStart = point
                initialNodeSize = size
                didResizeNode = false
                return
            }
            let connector = Self.controlFrame(center: Self.connectionControlCenter(for: controlRect))
            if connector.contains(point) {
                connectingFromNodeID = id
                connectionPointer = point
                needsDisplay = true
                return
            }
            if let handle = nodeStretchFrames(for: id).first(where: { $0.frame.contains(point) }) {
                resizingNodeID = id
                stretchDirection = handle.direction
                stretchInitialCenter = dragPreview[id] ?? NSPoint(x: position.x, y: position.y)
                nodeResizeStart = point
                initialNodeSize = size
                didResizeNode = false
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
                let ids = event.modifierFlags.contains(.shift) ? selection.edgeIDs.symmetricDifference([edgeID]) : [edgeID]
                selection = .edgeGroup(ids)
                onSelect?(selection)
                if event.clickCount == 1 && !event.modifierFlags.contains(.shift) { scheduleElementLongPress(.edge(edgeID), at: point) }
            } else if let id = hitContainer(at: point, diagram: diagram, layout: layout) {
                selection = .container(id)
                onSelect?(.container(id))
                draggingContainerID = id
                isCopyDrag = event.modifierFlags.contains(.command)
                containerDragStart = worldPoint(for: point)
                containerEmptyCenters.removeAll()
                var containerIDs: Set<String> = [id]
                var expanded = true
                while expanded {
                    expanded = false
                    for container in diagram.containers where container.parentId.map(containerIDs.contains) == true {
                        if containerIDs.insert(container.id).inserted { expanded = true }
                    }
                }
                let frames = containerWorldRects(diagram: diagram, layout: layout)
                for containerID in containerIDs where isEmptyContainer(containerID) {
                    if let rect = frames[containerID] {
                        containerEmptyCenters[containerID] = NSPoint(x: rect.midX, y: rect.midY)
                    }
                }
                if isEmptyContainer(id), let rect = frames[id] {
                    emptyContainerDragOriginCenter = NSPoint(x: rect.midX, y: rect.midY)
                }
                containerMemberCenters = Dictionary(uniqueKeysWithValues: memberPositions(id, diagram: diagram, layout: layout).map {
                    ($0.id, NSPoint(x: CGFloat($0.x), y: CGFloat($0.y)))
                })
                didMoveContainer = false
                if !isCopyDrag { scheduleElementLongPress(.container(id), at: point) }
            } else {
                draggingContainerID = nil
                marqueeStart = point
                selectionMarquee = NSRect(origin: point, size: .zero)
                marqueeBaseSelection = event.modifierFlags.contains(.shift) ? selectedNodeIDs : []
                marqueeBaseEdges = event.modifierFlags.contains(.shift) ? selection.edgeIDs : []
            }
            needsDisplay = true
            return
        }
        let priorSelection = selectedNodeIDs
        if event.modifierFlags.contains(.shift) && !event.modifierFlags.contains(.command) {
            var updated = priorSelection
            if updated.contains(node.id) {
                pendingShiftToggleID = node.id
            } else {
                updated.insert(node.id)
                setNodeSelection(updated)
                onSelect?(selection)
            }
        } else if !priorSelection.contains(node.id) || priorSelection.count <= 1 {
            selection = .node(node.id)
            onSelect?(selection)
        }
        let activeIDs = selectedNodeIDs
        isCopyDrag = event.modifierFlags.contains(.command)
        guard let position = layoutNodeByID[node.id] else { return }
        if activeIDs.count > 1 {
            draggingNodeIDs = activeIDs
            captureNodeDropBounds()
            groupDragStart = worldPoint(for: point)
            groupInitialCenters = Dictionary(uniqueKeysWithValues: activeIDs.compactMap { id in
                guard let nodePosition = layoutNodeByID[id] else { return nil }
                return (id, dragPreview[id] ?? NSPoint(x: CGFloat(nodePosition.x), y: CGFloat(nodePosition.y)))
            })
            didDragGroup = false
            for (id, center) in groupInitialCenters { dragPreview[id] = center }
            if !isCopyDrag { scheduleLongPress(for: node.id, at: point) }
            needsDisplay = true
            return
        }
        draggingNodeID = node.id
        let center = dragPreview[node.id] ?? NSPoint(x: CGFloat(position.x), y: CGFloat(position.y))
        singleDragInitialCenter = center
        captureNodeDropBounds()
        dropTargetContainerID = node.containerId ?? containerAtDropPoint(center)
        let pointer = worldPoint(for: point)
        dragPointerOffset = NSPoint(x: center.x - pointer.x, y: center.y - pointer.y)
        dragPreview[node.id] = center
        didDragNode = false
        if !isCopyDrag { scheduleLongPress(for: node.id, at: point) }
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !isReadOnly, let diagram, let layout = diagramLayout else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        if let node = hitNode(at: point, diagram: diagram, layout: layout) {
            if !selectedNodeIDs.contains(node.id) {
                selection = .node(node.id)
                onSelect?(selection)
            }
        } else if let edgeID = hitEdge(at: point, diagram: diagram, layout: layout) {
            if !selection.edgeIDs.contains(edgeID) { selection = .edge(edgeID); onSelect?(selection) }
        } else if let id = hitContainer(at: point, diagram: diagram, layout: layout) {
            selection = .container(id)
            onSelect?(selection)
        } else {
            selection = .project
            onSelect?(.project)
            let menu = NSMenu()
            let create = NSMenuItem(title: "Создать пустой контейнер", action: #selector(contextCreateEmptyContainer(_:)), keyEquivalent: "")
            create.target = self
            create.representedObject = NSValue(point: worldPoint(for: point))
            create.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)
            menu.addItem(create)
            menu.addItem(.separator())
            colorContextItems().forEach(menu.addItem)
            return menu
        }
        needsDisplay = true
        let menu = NSMenu()
        let style = NSMenuItem(title: "Оформление и свойства…", action: #selector(openContextStyle), keyEquivalent: "")
        style.target = self
        menu.addItem(style)
        colorContextItems().forEach(menu.addItem)
        menu.addItem(.separator())
        quickStyleContextItems().forEach(menu.addItem)
        menu.addItem(.separator())
        let duplicate = NSMenuItem(title: "Дублировать", action: #selector(duplicate(_:)), keyEquivalent: "")
        duplicate.target = self
        menu.addItem(duplicate)
        if !selectedNodeIDs.isEmpty {
            let rotate = NSMenuItem(title: "Поворот",action: nil,keyEquivalent: ""); let choices = NSMenu()
            for (title,angle) in [("На 90° против часовой",90.0),("На 90° по часовой",-90.0),("На 180°",180.0),("Сбросить поворот",0.0)] {
                let item = NSMenuItem(title: title,action: #selector(contextRotate(_:)),keyEquivalent: ""); item.target = self; item.representedObject = angle; choices.addItem(item)
            }
            rotate.submenu = choices; menu.addItem(rotate)
        }
        if !selection.edgeIDs.isEmpty {
            for (title,action) in [("Линию на передний план",#selector(contextEdgeFront(_:))),("Линию на задний план",#selector(contextEdgeBack(_:))),("Z-index линии…",#selector(contextEdgeZ(_:)))] {
                let item = NSMenuItem(title: title,action: action,keyEquivalent: ""); item.target = self; menu.addItem(item)
            }
        }
        if case .node(let nodeID) = selection {
            nodeStackMenuItems(for: nodeID).forEach(menu.addItem)
            if let detach = detachContainerMenuItem(for: nodeID) { menu.addItem(detach) }
            let editText = NSMenuItem(title: "Текст и размещение…", action: #selector(editContextNodeText), keyEquivalent: "")
            editText.target = self
            editText.representedObject = nodeID
            menu.addItem(editText)
        }
        if selection.edgeIDs.contains(where: { edgeByID[$0]?.waypoints.isEmpty == false }) {
            let resetRoute = NSMenuItem(title: "Сбросить маршрут этой связи", action: #selector(resetContextRoute), keyEquivalent: "")
            resetRoute.target = self
            menu.addItem(resetRoute)
        }
        if case .container = selection {
            let edit = NSMenuItem(title: "Текст контейнера…", action: #selector(editContextElementText), keyEquivalent: ""); edit.target = self; menu.addItem(edit)
        } else if case .edge = selection {
            let edit = NSMenuItem(title: "Текст связи…", action: #selector(editContextElementText), keyEquivalent: ""); edit.target = self; menu.addItem(edit)
        }
        let delete = NSMenuItem(title: "Удалить", action: #selector(deleteContextSelection), keyEquivalent: "")
        delete.target = self
        menu.addItem(delete)
        return menu
    }

    private func colorContextItems() -> [NSMenuItem] {
        DiagramColorParameter.allCases.map { parameter in
            let title: String
            if case .edge = selection, parameter == .stroke { title = "Цвет линии…" }
            else if case .edge = selection, parameter == .text { title = "Цвет подписи…" }
            else { title = "Цвет: \(parameter.title.lowercased())…" }
            let item = NSMenuItem(title: title, action: #selector(contextEditColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = parameter.rawValue
            switch selection {
            case .project: item.isEnabled = parameter == .fill
            case .edge, .edges: item.isEnabled = parameter != .fill
            default: break
            }
            return item
        }
    }

    @objc private func contextRotate(_ sender: NSMenuItem) {
        guard let angle = sender.representedObject as? Double else { return }
        if angle == 0 {
            // A single model command can reset a group with differing angles.
            onResetNodeRotations?(selectedNodeIDs)
        } else { onRotateNodes?(selectedNodeIDs,angle) }
    }
    var onResetNodeRotations: ((Set<String>) -> Void)?
    @objc private func contextEdgeFront(_ sender: Any?) { onSetEdgeZIndex?(selection.edgeIDs,nil,true) }
    @objc private func contextEdgeBack(_ sender: Any?) { onSetEdgeZIndex?(selection.edgeIDs,nil,false) }
    @objc private func contextEdgeZ(_ sender: Any?) {
        let alert = NSAlert(); alert.messageText = "Z-index выбранных линий"
        let field = NSTextField(string: String(selection.edgeIDs.compactMap { edgeByID[$0]?.effectiveZIndex }.first ?? 0))
        field.frame = NSRect(x: 0,y: 0,width: 240,height: 24); alert.accessoryView = field
        alert.addButton(withTitle: "Применить"); alert.addButton(withTitle: "Отмена")
        let ids = selection.edgeIDs
        if alert.runModal() == .alertFirstButtonReturn,let value = Int(field.stringValue),(-1_000_000...1_000_000).contains(value) { onSetEdgeZIndex?(ids,value,true) }
    }

    @objc private func contextEditColor(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let parameter = DiagramColorParameter(rawValue: value) else { return }
        onRequestColor?(parameter)
    }

    private func quickStyleContextItems() -> [NSMenuItem] {
        switch selection {
        case .node, .nodes:
            let styles = selectedNodeIDs.compactMap { nodeByID[$0]?.style }
            guard !styles.isEmpty else { return [] }
            return [
                styleSubmenu("Стиль контура", choices: DiagramStyleOptions.nodeLines, current: styles.map(\.effectiveLineStyle), change: DiagramStyleChange.lineStyle),
                widthSubmenu("Толщина контура", current: styles.map(\.penwidth)),
            ]
        case .container(let id):
            guard let style = containerByID[id]?.style else { return [] }
            return [widthSubmenu("Толщина границы", current: [style.effectivePenwidth])]
        case .edge, .edges:
            let edges = selection.edgeIDs.sorted().compactMap { edgeByID[$0] }
            guard !edges.isEmpty else { return [] }
            let direction = styleSubmenu("Направление", choices: DiagramStyleOptions.directions, current: edges.map { $0.direction }, change: DiagramStyleChange.direction)
            direction.submenu?.addItem(.separator())
            direction.submenu?.addItem(styleItem("Поменять начало и конец", change: .reverse))
            return [
                styleSubmenu("Стиль линии", choices: DiagramStyleOptions.edgeLines, current: edges.map { $0.style.lineStyle }, change: DiagramStyleChange.lineStyle),
                styleSubmenu("Маршрут", choices: DiagramStyleOptions.routes, current: edges.map { $0.routing ?? "" }, change: { .routing($0.isEmpty ? nil : $0) }),
                widthSubmenu("Толщина линии", current: edges.map { $0.style.penwidth }),
                styleSubmenu("Фон подписи", choices: [("transparent", "Прозрачный"), ("opaque", "Непрозрачный")],
                             current: edges.map { $0.style.effectiveLabelBackgroundTransparent ? "transparent" : "opaque" },
                             change: { .labelBackgroundTransparent($0 == "transparent") }),
                styleSubmenu("Наконечник у цели", choices: DiagramStyleOptions.arrows, current: edges.map { $0.style.arrowhead }, change: DiagramStyleChange.arrowhead),
                styleSubmenu("Наконечник у источника", choices: DiagramStyleOptions.arrows, current: edges.map { $0.style.arrowtail }, change: DiagramStyleChange.arrowtail),
                direction,
            ]
        case .project: return []
        }
    }

    private func widthSubmenu(_ title: String, current: [Double]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        // Include custom widths so that the menu always marks the actual value.
        for value in Set(DiagramStyleOptions.widths + current).sorted() {
            let choice = styleItem(String(format: "%g pt", value), change: .penwidth(value))
            choice.state = current.allSatisfy { $0 == value } ? .on : current.contains(value) ? .mixed : .off
            submenu.addItem(choice)
        }
        item.submenu = submenu
        return item
    }

    private func styleSubmenu(_ title: String, choices: [(value: String, title: String)], current: [String],
                              change: (String) -> DiagramStyleChange) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        for value in choices {
            let choice = styleItem(value.title, change: change(value.value))
            choice.state = current.allSatisfy { $0 == value.value } ? .on : current.contains(value.value) ? .mixed : .off
            submenu.addItem(choice)
        }
        item.submenu = submenu
        return item
    }

    private func styleItem(_ title: String, change: DiagramStyleChange) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(contextSetStyle(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = DiagramStyleCommand(selection: selection, change: change)
        return item
    }

    @objc private func contextSetStyle(_ sender: NSMenuItem) {
        guard !isReadOnly, let command = sender.representedObject as? DiagramStyleCommand else { return }
        onSetStyle?(command.selection, command.change)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard !isReadOnly else { return false }
        if item.action == #selector(contextEditColor(_:)), let value = item.representedObject as? String,
           let parameter = DiagramColorParameter(rawValue: value) {
            switch selection {
            case .project: return parameter == .fill
            case .edge, .edges: return parameter != .fill
            default: return true
            }
        }
        return true
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

    func detachContainerMenuItem(for id: String) -> NSMenuItem? {
        guard nodeByID[id]?.containerId != nil else { return nil }
        let item = NSMenuItem(title: "Извлечь из контейнера", action: #selector(contextDetachNodeFromContainer(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = id
        return item
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
    @objc private func contextCreateEmptyContainer(_ sender: NSMenuItem) {
        guard !isReadOnly, let value = sender.representedObject as? NSValue else { return }
        let position = value.pointValue
        let previousScale = scale, previousOffset = offset
        onCreateEmptyContainer?(Double(position.x), Double(position.y))
        // The clicked position must stay under the pointer when the new selection refreshes.
        scale = previousScale; offset = previousOffset
        needsDisplay = true
    }
    @objc private func deleteContextSelection() { onDeleteSelection?() }
    @objc private func editContextNodeText(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onEditNodeText?(id)
    }
    @objc private func contextDetachNodeFromContainer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onDetachNodeFromContainer?(id)
    }
    @objc private func resetContextRoute() {
        onResetSelectedRoutes?()
        for id in selection.edgeIDs { waypointPreview.removeValue(forKey: id) }
    }
    @objc private func editContextElementText() { onEditElementText?(selection) }
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
        if let drag = rotationDrag {
            let angle = atan2(point.y-drag.center.y,point.x-drag.center.x)*180 / .pi
            var delta = angle-drag.angle
            if delta>180 { delta -= 360 }; if delta < -180 { delta += 360 }
            rotationDelta = event.modifierFlags.contains(.shift) ? (delta/15).rounded()*15 : delta
            attachmentHandleCache.removeAll(); needsDisplay = true; return
        }
        if let origin = longPressOrigin, hypot(point.x - origin.x, point.y - origin.y) > 6 {
            cancelLongPress()
        }
        if let drag = endpointDrag {
            endpointPointer = point
            didDragEndpoint = didDragEndpoint || hypot(point.x-drag.origin.x, point.y-drag.origin.y) > 3
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
            if let direction = stretchDirection, let origin = stretchInitialCenter {
                let delta = CanvasGeometry.rotated(NSPoint(x: point.x-nodeResizeStart.x,y: point.y-nodeResizeStart.y),around: .zero,degrees: -(nodeByID[id]?.effectiveRotation ?? 0))
                let deltaX = Double(delta.x) / Double(scale)
                let deltaY = Double(delta.y) / Double(scale)
                var width = direction.x == 0 ? initialNodeSize.width : min(10, max(0.5, initialNodeSize.width + deltaX * Double(direction.x)))
                var height = direction.y == 0 ? initialNodeSize.height : min(10, max(0.5, initialNodeSize.height + deltaY * Double(direction.y)))
                if direction.x != 0, direction.y != 0, event.modifierFlags.contains(.shift) {
                    let widthFactor = width / initialNodeSize.width, heightFactor = height / initialNodeSize.height
                    let factor = abs(widthFactor - 1) >= abs(heightFactor - 1) ? widthFactor : heightFactor
                    let bounded = min(min(10 / initialNodeSize.width, 10 / initialNodeSize.height),
                                      max(max(0.5 / initialNodeSize.width, 0.5 / initialNodeSize.height), factor))
                    width = initialNodeSize.width * bounded
                    height = initialNodeSize.height * bounded
                }
                nodeSizePreview[id] = (width, height)
                let shift = CanvasGeometry.rotated(NSPoint(x: (width-initialNodeSize.width)*direction.x/2,y: (height-initialNodeSize.height)*direction.y/2),around: .zero,degrees: nodeByID[id]?.effectiveRotation ?? 0)
                dragPreview[id] = NSPoint(x: origin.x+shift.x,y: origin.y+shift.y)
                didResizeNode = abs(width - initialNodeSize.width) > 0.001 || abs(height - initialNodeSize.height) > 0.001
                needsDisplay = true
                return
            }
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
            let world = constrainedDragPointer(point, event: event)
            let delta = NSPoint(x: world.x - containerDragStart.x, y: world.y - containerDragStart.y)
            for (nodeID, center) in containerMemberCenters {
                dragPreview[nodeID] = NSPoint(x: center.x + delta.x, y: center.y + delta.y)
            }
            for (containerID, center) in containerEmptyCenters {
                emptyContainerDragPreview[containerID] = NSPoint(x: center.x + delta.x, y: center.y + delta.y)
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
            let world = constrainedDragPointer(point, event: event)
            let delta = NSPoint(x: world.x - start.x, y: world.y - start.y)
            for (id, center) in groupInitialCenters {
                dragPreview[id] = NSPoint(x: center.x + delta.x, y: center.y + delta.y)
            }
            dropTargetContainerID = containerAtDropPoint(world)
            didDragGroup = hypot(delta.x, delta.y) > 0.015
            needsDisplay = true
            return
        }
        guard let id = draggingNodeID else { return }
        let pointer = constrainedDragPointer(point, event: event)
        let center = NSPoint(x: pointer.x + dragPointerOffset.x, y: pointer.y + dragPointerOffset.y)
        dragPreview[id] = center
        dropTargetContainerID = nodeDropTarget(for: id, center: center, pointer: pointer)
        if let start = dragGestureStart { didDragNode = hypot(pointer.x - start.x, pointer.y - start.y) > 0.015 }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragGestureStart = nil
            alignmentVertical = nil; alignmentHorizontal = nil
            singleDragInitialCenter = nil
            lockedDragAxis = nil
            pendingShiftToggleID = nil
            isCopyDrag = false
        }
        cancelLongPress()
        if rotationDrag != nil { finishRotation(); return }
        if didTriggerLongPress {
            didTriggerLongPress = false
            return
        }
        if let drag = endpointDrag {
            let point = convert(event.locationInWindow, from: nil)
            let target = connectionTarget(at: point)
            let moved = didDragEndpoint || hypot(point.x-drag.origin.x, point.y-drag.origin.y) > 3
            // Finish the gesture before the model callback synchronously refreshes the canvas.
            endpointDrag = nil; endpointPointer = nil; didDragEndpoint = false
            if moved, let target { onReattachEdge?(drag.id, drag.source, target.nodeID, target.port) }
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
            let target = connectionTarget(at: point, excluding: sourceID)
            connectingFromNodeID = nil
            connectionPointer = nil
            if let target { onCreateEdge?(sourceID, target.nodeID, target.port) }
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
                for id in nodeByID.keys where nodeVisualRect(for: id)?.intersects(rect) == true { ids.insert(id) }
            }
            if ids.isEmpty {
                var edgeIDs = marqueeBaseEdges
                if hypot(end.x - start.x, end.y - start.y) > 3 {
                    for id in edgeByID.keys {
                        if let drawing = edgeDrawing(for: id), zip(drawing.shaft,drawing.shaft.dropFirst()).contains(where: { CanvasGeometry.segmentIntersectsRect($0.0,$0.1,rect) }) { edgeIDs.insert(id) }
                    }
                }
                selection = .edgeGroup(edgeIDs)
            } else { setNodeSelection(ids) }
            onSelect?(selection)
            marqueeBaseEdges.removeAll()
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
            if didResizeNode, let size = nodeSizePreview[id] {
                if stretchDirection != nil, let center = dragPreview[id] {
                    onTransformNode?(id, Double(center.x), Double(center.y), size.width, size.height)
                } else { onResizeNode?(id, size.width, size.height) }
            }
            dragPreview.removeValue(forKey: id)
            nodeSizePreview.removeValue(forKey: id)
            stretchDirection = nil
            stretchInitialCenter = nil
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
                let end = constrainedDragPointer(convert(event.locationInWindow, from: nil), event: event)
                if isCopyDrag { onDuplicateSelection?(Double(end.x - start.x), Double(end.y - start.y), [:]) }
                else { onMoveContainer?(id, Double(end.x - start.x), Double(end.y - start.y)) }
            }
            draggingContainerID = nil
            containerDragStart = nil
            containerMemberCenters.keys.forEach { dragPreview.removeValue(forKey: $0) }
            containerMemberCenters.removeAll()
            containerEmptyCenters.removeAll()
            emptyContainerDragOriginCenter = nil
            emptyContainerDragPreview.removeAll()
            didMoveContainer = false
            needsDisplay = true
            return
        }
        if !draggingNodeIDs.isEmpty {
            let ids = draggingNodeIDs
            let start = groupDragStart
            let end = constrainedDragPointer(convert(event.locationInWindow, from: nil), event: event)
            let shouldCommit = didDragGroup
            var containerIDs: [String: String] = [:]
            var destinations: [String: NSPoint] = [:]
            if let start {
                for (id, initial) in groupInitialCenters {
                    let center = NSPoint(x: initial.x + end.x - start.x, y: initial.y + end.y - start.y)
                    destinations[id] = center
                    if let target = nodeDropTarget(for: id, center: center) { containerIDs[id] = target }
                }
            }
            draggingNodeIDs.removeAll()
            groupDragStart = nil
            groupInitialCenters.removeAll()
            didDragGroup = false
            ids.forEach { dragPreview.removeValue(forKey: $0) }
            nodeDropBounds.removeAll(); dropTargetContainerID = nil
            if shouldCommit {
                if isCopyDrag, let start { onDuplicateSelection?(Double(end.x - start.x), Double(end.y - start.y), containerIDs) }
                else { onMoveNodes?(destinations, containerIDs) }
            } else if let id = pendingShiftToggleID {
                setNodeSelection(selectedNodeIDs.subtracting([id]))
                onSelect?(selection)
            }
            needsDisplay = true
            return
        }
        let id = draggingNodeID
        let pointer = constrainedDragPointer(convert(event.locationInWindow, from: nil), event: event)
        let center = NSPoint(x: pointer.x + dragPointerOffset.x, y: pointer.y + dragPointerOffset.y)
        let target = id.flatMap { nodeDropTarget(for: $0, center: center, pointer: pointer) }
        let shouldCommit = didDragNode
        draggingNodeID = nil
        didDragNode = false
        if let id { dragPreview.removeValue(forKey: id) }
        nodeDropBounds.removeAll(); dropTargetContainerID = nil
        if shouldCommit, let id {
            if isCopyDrag, let origin = singleDragInitialCenter {
                onDuplicateSelection?(Double(center.x - origin.x), Double(center.y - origin.y), target.map { [id: $0] } ?? [:])
            } else { onMoveNode?(id, Double(center.x), Double(center.y), target) }
        } else if let id = pendingShiftToggleID {
            setNodeSelection(selectedNodeIDs.subtracting([id]))
            onSelect?(selection)
        }
        needsDisplay = true
    }

    private func scheduleLongPress(for nodeID: String, at point: NSPoint) {
        scheduleElementLongPress(.node(nodeID), at: point)
    }

    private func scheduleElementLongPress(_ target: DiagramSelection, at point: NSPoint) {
        cancelLongPress(resetTrigger: true)
        longPressSelection = target
        longPressOrigin = point
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(600))
        longPressTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            guard let self, self.longPressSelection == target else { return }
            self.longPressTask = nil
            self.longPressSelection = nil
            self.longPressOrigin = nil
            self.didTriggerLongPress = true
            self.draggingNodeID = nil
            self.draggingNodeIDs.removeAll()
            self.groupDragStart = nil
            self.groupInitialCenters.removeAll()
            self.didDragNode = false
            self.didDragGroup = false
            if let waypoint = self.draggingWaypoint { self.waypointPreview.removeValue(forKey: waypoint.id) }
            self.draggingWaypoint = nil
            self.draggingContainerID = nil
            self.containerDragStart = nil
            self.didMoveContainer = false
            self.dragPreview.removeAll()
            self.emptyContainerDragPreview.removeAll()
            self.containerMemberCenters.removeAll()
            self.containerEmptyCenters.removeAll()
            self.emptyContainerDragOriginCenter = nil
            self.nodeDropBounds.removeAll()
            self.dropTargetContainerID = nil
            self.needsDisplay = true
            if case .node(let id) = target { self.onEditNodeText?(id) }
            else { self.onEditElementText?(target) }
        }
    }

    private func constrainedDragPointer(_ point: NSPoint, event: NSEvent) -> NSPoint {
        var pointer = worldPoint(for: point)
        guard let start = dragGestureStart else { return pointer }
        if event.modifierFlags.contains(.shift) {
            let delta = NSPoint(x: pointer.x - start.x, y: pointer.y - start.y)
            if lockedDragAxis == nil, hypot(delta.x, delta.y) > 0.015 { lockedDragAxis = abs(delta.x) >= abs(delta.y) }
            if let horizontal = lockedDragAxis { pointer = horizontal ? .init(x: pointer.x, y: start.y) : .init(x: start.x, y: pointer.y) }
        } else { lockedDragAxis = nil }
        var movingIDs = draggingNodeIDs
        if let id = draggingNodeID { movingIDs.insert(id) }
        if draggingContainerID != nil { movingIDs.formUnion(containerMemberCenters.keys) }
        var frames = movingIDs.sorted().compactMap { id -> NSRect? in
            guard let position = layoutNodeByID[id] else { return nil }
            return NSRect(x: position.x-position.width/2, y: position.y-position.height/2, width: position.width, height: position.height)
        }
        if frames.isEmpty, let id = draggingContainerID, let diagram, let layout = diagramLayout,
           let frame = containerWorldRects(diagram: diagram, layout: layout)[id] {
            if let origin = emptyContainerDragOriginCenter { frames = [frame.offsetBy(dx: origin.x-frame.midX, dy: origin.y-frame.midY)] }
            else { frames = [frame] }
        }
        guard let first = frames.first else { return pointer }
        let peers = layoutNodeByID.keys.sorted().filter { !movingIDs.contains($0) }.compactMap { id -> NSRect? in
            guard let position = layoutNodeByID[id] else { return nil }
            return NSRect(x: position.x-position.width/2, y: position.y-position.height/2, width: position.width, height: position.height)
        }
        let result = DiagramAlignment.snap(moving: frames.dropFirst().reduce(first) { $0.union($1) }, peers: peers,
            delta: .init(x: pointer.x-start.x, y: pointer.y-start.y), scale: scale, enabled: alignmentGuides,
            lockedHorizontal: lockedDragAxis)
        alignmentVertical = result.vertical; alignmentHorizontal = result.horizontal
        return .init(x: start.x+result.delta.x, y: start.y+result.delta.y)
    }

    private func cancelLongPress(resetTrigger: Bool = false) {
        longPressTask?.cancel()
        longPressTask = nil
        longPressSelection = nil
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
        let rects = ids.compactMap { nodeVisualRect(for: $0) }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -5, dy: -5)
    }

    private func drawSelectionOverlay() {
        if alignmentGuides {
            let path = NSBezierPath(); path.lineWidth = 1; path.setLineDash([4, 3], count: 2, phase: 0)
            if let x = alignmentVertical.map({ screenPoint(for: .init(x: $0, y: 0)).x }) { path.move(to: .init(x: x, y: bounds.minY)); path.line(to: .init(x: x, y: bounds.maxY)) }
            if let y = alignmentHorizontal.map({ screenPoint(for: .init(x: 0, y: $0)).y }) { path.move(to: .init(x: bounds.minX, y: y)); path.line(to: .init(x: bounds.maxX, y: y)) }
            NSColor.systemPink.setStroke(); path.stroke()
        }
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
        drawResizeGlyph(center: Self.resizeControlCenter(for: rect))
    }

    private func nodeLabelContains(_ point: NSPoint, node: DiagramNode, rect: NSRect) -> Bool {
        let local = CanvasGeometry.rotated(point,around: .init(x: rect.midX,y: rect.midY),degrees: -node.effectiveRotation)
        return rect.contains(local) && NodeLabelLayout(node: node,in: rect,scale: scale).contains(local)
    }

    private func hitNode(at point: NSPoint, diagram: DiagramProject, layout: DiagramLayout) -> DiagramNode? {
        for original in DiagramNodeStackOrder.sorted(diagram.nodes).reversed() {
            let node = displayedNode(original)
            guard let rect = nodeScreenRect(for: node.id) else { continue }
            let lineWidth = CGFloat(node.style.penwidth)
            if CanvasGeometry.contains(point, node: node, in: rect, tolerance: 3+lineWidth/2)
                || nodeLabelContains(point,node: node,rect: rect) { return node }
        }
        return nil
    }

    func nodeID(at point: NSPoint) -> String? {
        guard let diagram, let layout = diagramLayout else { return nil }
        return hitNode(at: point, diagram: diagram, layout: layout)?.id
    }

    private func hitContainer(at point: NSPoint, diagram: DiagramProject, layout: DiagramLayout) -> String? {
        let world = worldPoint(for: point)
        let frames = containerWorldRects(diagram: diagram, layout: layout)
        for container in orderedContainers {
            if frames[container.id]?.contains(world) == true { return container.id }
        }
        return nil
    }

    private func containerAtDropPoint(_ point: NSPoint) -> String? {
        orderedContainers.first { nodeDropBounds[$0.id]?.contains(point) == true }?.id
    }

    private func captureNodeDropBounds() {
        guard let diagram, let layout = diagramLayout else { return }
        // Freeze world-space target bounds for the gesture, including asynchronous layout refreshes.
        nodeDropBounds = containerWorldRects(diagram: diagram, layout: layout)
    }

    private func nodeDropTarget(for id: String, center: NSPoint, pointer: NSPoint? = nil) -> String? {
        nodeByID[id]?.containerId ?? pointer.flatMap(containerAtDropPoint) ?? containerAtDropPoint(center)
    }

    private func memberPositions(_ containerID: String, diagram: DiagramProject, layout: DiagramLayout) -> [LayoutNode] {
        memberPositionsByContainer[containerID] ?? []
    }

    private func isEmptyContainer(_ id: String) -> Bool {
        memberPositionsByContainer[id]?.isEmpty != false && !containersWithChildren.contains(id)
    }

    private func containerWorldRect(_ id: String, diagram: DiagramProject, layout: DiagramLayout) -> NSRect? {
        containerWorldRects(diagram: diagram, layout: layout)[id]
    }

    private func containerWorldRects(diagram: DiagramProject, layout: DiagramLayout, atScale: CGFloat? = nil) -> [String: NSRect] {
        if let style = pdfStyle { return style.containerFrames }
        guard !diagram.containers.isEmpty else { return [:] }
        var members: [String: [NSRect]] = [:]
        for node in layout.nodes {
            guard let parent = nodeByID[node.id]?.containerId else { continue }
            let center = dragPreview[node.id] ?? NSPoint(x: node.x, y: node.y)
            let size = nodeSizePreview[node.id] ?? (node.width, node.height)
            members[parent, default: []].append(CanvasGeometry.visualBounds(NSRect(x: center.x-size.width/2, y: center.y-size.height/2,
                                                       width: size.width, height: size.height),rotation: nodeByID[node.id].map { displayedNode($0).effectiveRotation } ?? 0))
        }
        let previous = Dictionary(uniqueKeysWithValues: (layout.containers ?? []).map { ($0.id, $0) })
        var emptyFrames: [String: NSRect] = [:]
        for container in diagram.containers {
            let center = emptyContainerDragPreview[container.id]
                ?? NSPoint(x: container.x ?? previous[container.id]?.x ?? layout.minX+1.6,
                           y: container.y ?? previous[container.id]?.y ?? layout.minY+1.2)
            let size = emptyContainerSizePreview[container.id] ?? (container.width, container.height)
            emptyFrames[container.id] = NSRect(x: center.x-size.width/2, y: center.y-size.height/2,
                                              width: size.width, height: size.height)
        }
        return DiagramContainerLayout.frames(containers: diagram.containers, members: members, emptyFrames: emptyFrames,
                                             scale: atScale ?? scale, paddingOverrides: containerPaddingPreview,
                                             headerHeight: pdfStyle?.containerHeaderHeight ?? DiagramContainerLayout.headerHeight)
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

    private func drawContainers(diagram: DiagramProject, layout: DiagramLayout, onlyIDs: Set<String>? = nil, showSelection: Bool = true) {
        let frames = containerWorldRects(diagram: diagram, layout: layout)
        for container in orderedContainers.reversed() where onlyIDs?.contains(container.id) != false {
            guard let world = frames[container.id] else { continue }
            let rect = NSRect(x: offset.x+world.minX*scale, y: offset.y+world.minY*scale,
                              width: world.width*scale, height: world.height*scale)
            let path = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
            let isDropTarget = container.id == dropTargetContainerID && (draggingNodeID != nil || !draggingNodeIDs.isEmpty)
            let fill = NSColor(hex: container.style.resolved(.fill, theme: diagram.presentation.theme))
            (isDropTarget ? NSColor.controlAccentColor.withAlphaComponent(0.08) : fill.withAlphaComponent(fill.alphaComponent * 0.42)).setFill()
            (isDropTarget ? NSColor.controlAccentColor : NSColor(hex: container.style.resolved(.stroke, theme: diagram.presentation.theme))).setStroke()
            path.lineWidth = isDropTarget ? max(2.4, CGFloat(container.style.effectivePenwidth)) : CGFloat(container.style.effectivePenwidth)
            path.fill()
            path.stroke()
            let titleFrame = pdfStyle.map {
                NSRect(x: rect.minX+10, y: rect.maxY-6-($0.containerHeaderHeight-12),
                       width: max(0, rect.width-20), height: $0.containerHeaderHeight-12)
            } ?? DiagramContainerLayout.labelFrame(in: rect)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: titleFrame).addClip()
            let title = container.label.components(separatedBy: .newlines).joined(separator: " ")
            drawText(title, in: titleFrame, color: NSColor(hex: container.style.resolved(.text, theme: diagram.presentation.theme)),
                     size: pdfStyle?.containerFontSize ?? DiagramContainerLayout.fontSize, weight: .bold, alignment: .left)
            NSGraphicsContext.restoreGraphicsState()
            if showSelection && selection == .container(container.id) {
                let handleRect = NSRect(x: rect.maxX - 5, y: rect.maxY - 5, width: 10, height: 10)
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: handleRect).fill()
            }
        }
    }

    private func orderedEdgeLayouts(_ layout: DiagramLayout,diagram: DiagramProject) -> [LayoutEdge] {
        let index = Dictionary(uniqueKeysWithValues: layout.edges.map { ($0.id,$0) })
        return DiagramEdgeStackOrder.sorted(diagram.edges).compactMap { index[$0.id] }
    }
    private func bridgedShafts(diagram: DiagramProject, layout: DiagramLayout) -> [String:[NSPoint]] {
        let inputs = orderedEdgeLayouts(layout,diagram: diagram).compactMap { geometry -> CrossingInput? in
            guard let edge = edgeByID[geometry.id] else { return nil }
            let points = displayedEdgePoints(edge,geometry: geometry,settings: diagram.diagram).map { screenPoint(for: $0) }
            return CrossingInput(id: edge.id,shaft: drawing(edge,points: points).shaft,radius: max(5,edgeLineWidth(edge)*1.5))
        }
        if inputs == crossingInputs { return crossingPaths }
        crossingInputs = inputs; crossingPaths.removeAll(keepingCapacity: true)
        var lower: [[NSPoint]] = []
        for input in inputs {
            crossingPaths[input.id] = LineCrossings.bridge(input.shaft,over: lower,radius: input.radius)
            lower.append(input.shaft)
        }
        return crossingPaths
    }

    private func drawEdges(diagram: DiagramProject, layout: DiagramLayout) {
        let bridges = bridgedShafts(diagram: diagram,layout: layout)
        for edgeLayout in orderedEdgeLayouts(layout,diagram: diagram) {
            guard let edge = edgeByID[edgeLayout.id], edgeLayout.points.count >= 2 else { continue }
            let points = displayedEdgePoints(edge, geometry: edgeLayout, settings: diagram.diagram).map { screenPoint(for: $0) }
            guard points.count >= 2 else { continue }
            let drawing = drawing(edge, points: points)
            let path = NSBezierPath()
            let isSelected = selection.edgeIDs.contains(edge.id)
            if isSelected {
                let highlight = NSBezierPath()
                highlight.lineWidth = max(7, CGFloat(edge.style.penwidth) + 5)
                highlight.lineCapStyle = .round
                highlight.lineJoinStyle = .round
                let highlighted = (drawing.tail.map { [$0.tip] } ?? [])+(bridges[edge.id] ?? drawing.shaft)+(drawing.head.map { [$0.tip] } ?? [])
                highlight.move(to: highlighted[0])
                appendEdgeSegments(highlighted, to: highlight)
                NSColor.controlAccentColor.withAlphaComponent(0.28).setStroke()
                highlight.stroke()
            }
            path.lineWidth = edgeLineWidth(edge)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let dashScale = pdfStyle == nil ? 1 : CGFloat(edge.style.penwidth)/1.5
            switch edge.style.lineStyle {
            case "dashed": setDash([6*dashScale, 4*dashScale], on: path)
            case "dotted": setDash([1.5*dashScale, 3*dashScale], on: path)
            default: break
            }
            NSColor(hex: edge.style.resolved(.stroke, theme: diagram.presentation.theme)).setStroke()
            let dashed = ["dashed", "dotted"].contains(edge.style.lineStyle)
            var shaft = bridges[edge.id] ?? drawing.shaft
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
                let handles = (waypointPreview[edge.id] ?? edge.waypoints).map { NSPoint(x: $0.x, y: $0.y) }
                let centers = handles.isEmpty ? [routeMidpoint(points.map { worldPoint(for: $0) })] : handles
                for center in centers {
                    let screen = screenPoint(for: center)
                    let marker = NSBezierPath(ovalIn: NSRect(x: screen.x-4, y: screen.y-4, width: 8, height: 8))
                    NSColor.controlAccentColor.setFill(); marker.fill()
                    NSColor.white.setStroke(); marker.lineWidth = 1; marker.stroke()
                }
            }
            if !edge.label.isEmpty, let x = edgeLayout.labelX, let y = edgeLayout.labelY {
                let followsPath = endpointDrag?.id == edge.id || !edge.waypoints.isEmpty || waypointPreview[edge.id] != nil || edge.routing != nil
                    || edge.sourcePort != "auto" || edge.targetPort != "auto" || nodeByID[edge.source]?.icon != nil || nodeByID[edge.target]?.icon != nil
                    || rotationIDs.contains(edge.source) || rotationIDs.contains(edge.target) || dragPreview[edge.source] != nil || dragPreview[edge.target] != nil || nodeSizePreview[edge.source] != nil || nodeSizePreview[edge.target] != nil
                var labelPoint = NSPoint(x: x, y: y)
                if followsPath { labelPoint = routeMidpoint(points.map { worldPoint(for: $0) }); labelPoint.y += 0.15 }
                if let position = pdfStyle?.edgeLabels[edge.id] { labelPoint = position }
                let center = screenPoint(for: labelPoint)
                let fontSize = CGFloat(edge.style.effectiveFontSize)
                let textSize = (edge.label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium)])
                let labelHeight = max(16, textSize.height + 4)
                let rect = NSRect(x: center.x - textSize.width / 2 - 5, y: center.y - labelHeight / 2,
                                  width: textSize.width + 10, height: labelHeight)
                if let anchor = pdfStyle?.labelLeaders[edge.id] {
                    let leader = NSBezierPath(); leader.lineWidth = 0.5
                    leader.move(to: screenPoint(for: anchor)); leader.line(to: center)
                    NSColor(hex: edge.style.resolved(.stroke, theme: "light")).withAlphaComponent(0.45).setStroke()
                    leader.stroke()
                }
                if !edge.style.effectiveLabelBackgroundTransparent {
                    let pill = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
                    NSColor(hex: diagram.presentation.theme == "dark" ? "#352C43" : "#FFFFFF").setFill()
                    pill.fill()
                }
                drawText(edge.label, in: rect, color: NSColor(hex: edge.style.resolved(.text, theme: diagram.presentation.theme)), size: fontSize, weight: .medium, alignment: .center)
            }
        }
    }

    private func drawArrowheads(diagram: DiagramProject, layout: DiagramLayout) {
        for edgeLayout in orderedEdgeLayouts(layout,diagram: diagram) {
            guard let edge = edgeByID[edgeLayout.id] else { continue }
            guard let drawing = edgeDrawing(for: edge.id) else { continue }
            let color = NSColor(hex: edge.style.resolved(.stroke, theme: diagram.presentation.theme))
            for marker in [drawing.head, drawing.tail].compactMap({ $0 }) {
                drawArrow(marker, color: color, lineWidth: edgeLineWidth(edge))
            }
        }
    }

    private func drawEdgeEndpointHandles() {
        for id in selection.edgeIDs {
            let points = edgePoints(for: id)
            guard let first = points.first, let last = points.last else { continue }
            for (index, point) in [first, last].enumerated() {
                let center = screenPoint(for: point)
                let marker = NSBezierPath(ovalIn: NSRect(x: center.x-6, y: center.y-6, width: 12, height: 12))
                (index == 0 ? NSColor.systemGreen : NSColor.systemOrange).setFill(); marker.fill()
                NSColor.white.setStroke(); marker.lineWidth = 1.5; marker.stroke()
            }
        }
    }

    private func drawNodes(diagram: DiagramProject, layout: DiagramLayout, onlyIDs: Set<String>? = nil, showSelection: Bool = true) {
        for original in DiagramNodeStackOrder.sorted(diagram.nodes) where onlyIDs?.contains(original.id) != false {
            let node = displayedNode(original)
            guard let position = layoutNodeByID[node.id] else { continue }
            let center = dragPreview[node.id] ?? NSPoint(x: CGFloat(position.x), y: CGFloat(position.y))
            let size = nodeSizePreview[node.id] ?? (node.width ?? position.width, node.height ?? position.height)
            let rect = screenRect(center: center, width: size.width, height: size.height)
            let selected = showSelection && selectedNodeIDs.contains(node.id)
            NSGraphicsContext.saveGraphicsState()
            let transform = AffineTransform(translationByX: rect.midX,byY: rect.midY)
            var rotation = transform; rotation.rotate(byDegrees: CGFloat(node.effectiveRotation)); rotation.translate(x: -rect.midX,y: -rect.midY)
            (rotation as NSAffineTransform).concat()
            let contours = CanvasGeometry.paths(node)
            let closed = node.icon.flatMap { CanvasGeometry.icons[$0]?.closed } ?? [true]
            let fill = NSBezierPath(); fill.windingRule = .nonZero
            for contour in CanvasGeometry.fillPaths(node) {
                let points = contour.map { NSPoint(x: rect.minX+$0.x*rect.width, y: rect.minY+$0.y*rect.height) }
                if let first = points.first { fill.move(to: first); appendEdgeSegments(points, to: fill); fill.close() }
            }
            NSColor(hex: node.style.resolved(.fill, theme: diagram.presentation.theme)).setFill(); fill.fill()
            for (index, contour) in contours.enumerated() {
                let path = NSBezierPath()
                let points = contour.map { NSPoint(x: rect.minX+$0.x*rect.width, y: rect.minY+$0.y*rect.height) }
                guard let first = points.first else { continue }
                path.move(to: first); appendEdgeSegments(points, to: path)
                path.lineJoinStyle = .round; path.lineCapStyle = .round
                path.lineWidth = CGFloat(node.style.penwidth)
                setDash(node.style.borderDashPattern, on: path)
                if closed.indices.contains(index) && closed[index] { path.close() }
                NSColor(hex: node.style.resolved(.stroke, theme: diagram.presentation.theme)).setStroke()
                path.stroke()
            }
            let color = NSColor(hex: node.style.resolved(.text, theme: diagram.presentation.theme))
            NodeLabelLayout(node: node, in: rect, scale: scale).draw(color: color)
            NSGraphicsContext.restoreGraphicsState()
            if selected && selectedNodeIDs.count == 1 {
                for handle in nodeStretchFrames(for: node.id) {
                    let frame = handle.frame.insetBy(dx: 3, dy: 3)
                    let marker = NSBezierPath(roundedRect: frame, xRadius: 2, yRadius: 2)
                    NSColor.windowBackgroundColor.setFill(); marker.fill()
                    NSColor.controlAccentColor.setStroke(); marker.lineWidth = 1; marker.stroke()
                }
                let visual = nodeVisualRect(for: node.id) ?? rect
                drawResizeGlyph(center: Self.resizeControlCenter(for: visual))
                drawConnectionGlyph(center: Self.connectionControlCenter(for: visual))
                if let handle = rotationHandle(for: node.id) {
                    let circle = NSBezierPath(ovalIn: handle); NSColor.windowBackgroundColor.setFill(); circle.fill()
                    NSColor.controlAccentColor.setStroke(); circle.lineWidth = 1; circle.stroke()
                    drawText("↻",in: handle,color: .controlAccentColor,size: 17,weight: .medium,alignment: .center)
                }
                toolTip = "Маркеры по сторонам и углам растягивают фигуру; Shift на угловом маркере сохраняет пропорции. Круглый значок масштабирует, стрелка создаёт связь. Cmd + перетаскивание копирует, Shift ограничивает перемещение одной осью."
            } else {
                toolTip = nil
            }
        }
    }

    private static func resizeControlCenter(for rect: NSRect) -> NSPoint {
        NSPoint(x: rect.maxX + 13, y: rect.minY - 13)
    }

    private static func connectionControlCenter(for rect: NSRect) -> NSPoint {
        NSPoint(x: rect.maxX + 13, y: max(rect.midY, rect.minY + 13))
    }

    private static func controlFrame(center: NSPoint) -> NSRect {
        NSRect(x: center.x - 11, y: center.y - 11, width: 22, height: 22)
    }

    func nodeControlFrames(for id: String) -> (resize: NSRect, connection: NSRect)? {
        guard let rect = nodeVisualRect(for: id) else { return nil }
        return (Self.controlFrame(center: Self.resizeControlCenter(for: rect)),
                Self.controlFrame(center: Self.connectionControlCenter(for: rect)))
    }

    func nodeStretchFrames(for id: String) -> [(direction: NSPoint, frame: NSRect)] {
        guard let rect = nodeScreenRect(for: id) else { return [] }
        return [NSPoint(x: -1, y: -1), NSPoint(x: 0, y: -1), NSPoint(x: 1, y: -1),
                NSPoint(x: -1, y: 0), NSPoint(x: 1, y: 0),
                NSPoint(x: -1, y: 1), NSPoint(x: 0, y: 1), NSPoint(x: 1, y: 1)].map { direction in
            let center = CanvasGeometry.rotated(NSPoint(x: rect.midX + direction.x * rect.width / 2,
                                 y: rect.midY + direction.y * rect.height / 2),around: .init(x: rect.midX,y: rect.midY),degrees: nodeByID[id].map { displayedNode($0).effectiveRotation } ?? 0)
            return (direction, NSRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
        }
    }

    static func resizeGlyphTriangles(center: NSPoint) -> [[NSPoint]] {
        let direction = NSPoint(x: 1 / sqrt(2), y: -1 / sqrt(2))
        let perpendicular = NSPoint(x: -direction.y, y: direction.x)
        return [CGFloat(-1), CGFloat(1)].map { sign in
            let tip = NSPoint(x: center.x + sign * direction.x * 7, y: center.y + sign * direction.y * 7)
            let base = NSPoint(x: center.x + sign * direction.x * 1.5, y: center.y + sign * direction.y * 1.5)
            return [tip,
                    NSPoint(x: base.x + perpendicular.x * 3.2, y: base.y + perpendicular.y * 3.2),
                    NSPoint(x: base.x - perpendicular.x * 3.2, y: base.y - perpendicular.y * 3.2)]
        }
    }

    private func drawControlCircle(center: NSPoint) {
        let circle = NSBezierPath(ovalIn: Self.controlFrame(center: center))
        NSColor.controlBackgroundColor.setFill()
        circle.fill()
        NSColor.controlAccentColor.setStroke()
        circle.lineWidth = 1.2
        circle.stroke()
    }

    private func drawResizeGlyph(center: NSPoint) {
        drawControlCircle(center: center)
        NSColor.controlAccentColor.setFill()
        for triangle in Self.resizeGlyphTriangles(center: center) {
            let path = NSBezierPath()
            path.move(to: triangle[0]); path.line(to: triangle[1]); path.line(to: triangle[2]); path.close()
            path.fill()
        }
    }

    private func drawConnectionGlyph(center: NSPoint) {
        drawControlCircle(center: center)
        let path = NSBezierPath()
        path.lineWidth = 1.8
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: center.x - 6, y: center.y))
        path.line(to: NSPoint(x: center.x + 6, y: center.y))
        path.move(to: NSPoint(x: center.x + 2, y: center.y + 4))
        path.line(to: NSPoint(x: center.x + 6, y: center.y))
        path.line(to: NSPoint(x: center.x + 2, y: center.y - 4))
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    private func connectionPreviewPoints() -> [NSPoint] {
        guard let sourceID = connectingFromNodeID, let pointer = connectionPointer,
              let node = nodeByID[sourceID], let position = layoutNodeByID[sourceID],
              let settings = diagram?.diagram else { return [] }
        let source = previewPosition(position)
        if let target = connectionTarget(at: pointer, excluding: sourceID),
           let targetNode = nodeByID[target.nodeID], let targetPosition = layoutNodeByID[target.nodeID] {
            let edge = DiagramEdge(id: "connection-preview", source: sourceID, target: target.nodeID,
                label: "", direction: "forward",
                style: EdgeStyle(lineStyle: "solid", color: "#64748B", penwidth: 1.5, arrowhead: "normal",
                                 arrowtail: "none", constraint: true, weight: 1, minlen: 1),
                sourcePort: "auto", targetPort: target.port)
            return CanvasGeometry.edgePoints(edge, source: source, target: previewPosition(targetPosition),
                sourceNode: displayedNode(node), targetNode: displayedNode(targetNode), settings: settings)
        }
        let end = worldPoint(for: pointer)
        let start = CanvasGeometry.attachment(displayedNode(node), at: source, toward: end, port: "auto")
        return CanvasGeometry.route(start, end, routing: settings.edgeRouting, horizontal: ["LR", "RL"].contains(settings.direction))
    }

    private func drawConnectionPreview() {
        let points = connectionPreviewPoints().map { screenPoint(for: $0) }
        guard points.count >= 2 else { return }
        let drawing = ArrowGeometry.make(points, head: "normal", tail: "none", lineWidth: 2)
        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineJoinStyle = .round
        setDash([5, 4], on: path)
        path.move(to: drawing.shaft[0])
        appendEdgeSegments(drawing.shaft, to: path)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
        if let head = drawing.head { drawArrow(head, color: .controlAccentColor, lineWidth: 2) }
    }

    private func attachmentHitRadius(in rect: NSRect) -> CGFloat {
        min(10, max(2, min(rect.width, rect.height)*0.16))
    }

    /// Screen-space handles use the same contour attachments as the saved route.
    func attachmentHandles(for id: String) -> [(port: String, center: NSPoint)] {
        guard let original = nodeByID[id], let position = layoutNodeByID[id], let rect = nodeScreenRect(for: id) else { return [] }
        let node = displayedNode(original)
        if let cached = attachmentHandleCache[id], cached.shape == node.shape, cached.icon == node.icon, cached.rotation == node.effectiveRotation, cached.rect == rect {
            return cached.handles
        }
        let ports = ["n", "e", "s", "w"] + CanvasGeometry.vertices(node).indices.map { "vertex:\($0)" }
            + ["ne", "se", "sw", "nw"]
        let minimumGap = min(4, attachmentHitRadius(in: rect)*0.5)
        var handles: [(port: String, center: NSPoint)] = []
        for port in ports {
            let center = screenPoint(for: CanvasGeometry.attachment(node, at: previewPosition(position), toward: .zero, port: port))
            if !handles.contains(where: { hypot($0.center.x-center.x, $0.center.y-center.y) < minimumGap }) {
                handles.append((port, center))
            }
        }
        attachmentHandleCache[id] = AttachmentHandleCache(shape: node.shape, icon: node.icon, rotation: node.effectiveRotation, rect: rect, handles: handles)
        return handles
    }

    private func connectionTarget(at point: NSPoint, excluding excludedID: String? = nil) -> ConnectionTarget? {
        guard let diagram else { return nil }
        // The foremost visible figure wins, including when it covers a port of another figure.
        for original in DiagramNodeStackOrder.sorted(diagram.nodes).reversed() {
            let node = displayedNode(original)
            guard let rect = nodeScreenRect(for: node.id) else { continue }
            let radius = attachmentHitRadius(in: rect)
            let tolerance = 3+CGFloat(node.style.penwidth)/2
            let reach = max(radius, tolerance)
            guard CanvasGeometry.visualBounds(rect,rotation: node.effectiveRotation).insetBy(dx: -reach, dy: -reach).contains(point) else { continue }
            let hitsBody = CanvasGeometry.contains(point, node: node, in: rect, tolerance: tolerance)
                || nodeLabelContains(point,node: node,rect: rect)
            if node.id == excludedID {
                if hitsBody { return nil }
                continue
            }
            let nearest = attachmentHandles(for: node.id).min {
                hypot($0.center.x-point.x, $0.center.y-point.y) < hypot($1.center.x-point.x, $1.center.y-point.y)
            }
            if let nearest, hypot(nearest.center.x-point.x, nearest.center.y-point.y) <= radius {
                return ConnectionTarget(nodeID: node.id, port: nearest.port)
            }
            if hitsBody {
                return ConnectionTarget(nodeID: node.id, port: "auto")
            }
        }
        return nil
    }

    private func drawAttachmentOverlay() {
        guard !isReadOnly, let diagram, let pointer = endpointPointer ?? connectionPointer,
              endpointDrag != nil || connectingFromNodeID != nil else { return }
        let target = connectionTarget(at: pointer, excluding: connectingFromNodeID)
        let accent = NSColor.controlAccentColor
        var foreground: [(node: DiagramNode, rect: NSRect)] = []
        for original in DiagramNodeStackOrder.sorted(diagram.nodes).reversed() {
            let node = displayedNode(original)
            guard let rect = nodeScreenRect(for: node.id), CanvasGeometry.visualBounds(rect,rotation: node.effectiveRotation).insetBy(dx: -12, dy: -12).intersects(bounds) else { continue }
            defer { foreground.append((node, rect)) }
            guard node.id != connectingFromNodeID else { continue }
            if target?.nodeID == node.id {
                let outline = NSBezierPath(); outline.lineWidth = 2; outline.lineJoinStyle = .round
                for contour in CanvasGeometry.fillPaths(node) {
                    let points = contour.map { CanvasGeometry.rotated(NSPoint(x: rect.minX+$0.x*rect.width,y: rect.minY+$0.y*rect.height),around: .init(x: rect.midX,y: rect.midY),degrees: node.effectiveRotation) }
                    if let first = points.first { outline.move(to: first); appendEdgeSegments(points, to: outline); outline.close() }
                }
                accent.withAlphaComponent(0.65).setStroke(); outline.stroke()
            }
            for handle in attachmentHandles(for: node.id) {
                if foreground.contains(where: { CanvasGeometry.contains(handle.center, node: $0.node, in: $0.rect, tolerance: 0) }) { continue }
                let active = target?.nodeID == node.id && target?.port == handle.port
                let radius: CGFloat = active ? 6 : min(4, attachmentHitRadius(in: rect)*0.65)
                let circle = NSBezierPath(ovalIn: NSRect(x: handle.center.x-radius, y: handle.center.y-radius, width: radius*2, height: radius*2))
                (active ? accent : NSColor.controlBackgroundColor).setFill(); circle.fill()
                accent.withAlphaComponent(active ? 1 : 0.8).setStroke(); circle.lineWidth = active ? 2 : 1.2; circle.stroke()
            }
        }
        guard let target, let node = nodeByID[target.nodeID] else { return }
        if target.port == "auto" {
            let route: [NSPoint]
            if let drag = endpointDrag {
                let points = edgePoints(for: drag.id)
                route = drag.source ? Array(points.prefix(1)) : Array(points.suffix(1))
            } else { route = Array(connectionPreviewPoints().suffix(1)) }
            if let point = route.first {
                let center = screenPoint(for: point)
                let circle = NSBezierPath(ovalIn: NSRect(x: center.x-6, y: center.y-6, width: 12, height: 12))
                accent.setStroke(); circle.lineWidth = 2; circle.stroke()
            }
        }
        let portTitle = CanvasGeometry.portChoices(node).first { $0.0 == target.port }?.1 ?? target.port
        let text = "\(node.label.components(separatedBy: .newlines).first ?? node.id) · \(portTitle)"
        let width = min(280, max(100, (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width+16))
        let rect = NSRect(x: max(4, min(pointer.x+14, bounds.maxX-width-4)),
                          y: max(4, min(pointer.y+16, bounds.maxY-24)), width: width, height: 22)
        NSColor.controlBackgroundColor.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        drawText(text, in: rect.insetBy(dx: 6, dy: 0), color: .labelColor, size: 10, weight: .medium, alignment: .left)
    }

    private func displayedEdgePoints(_ edge: DiagramEdge, geometry: LayoutEdge, settings: DiagramSettings) -> [NSPoint] {
        if let drag = endpointDrag, drag.id == edge.id, didDragEndpoint, let pointer = endpointPointer {
            if let target = connectionTarget(at: pointer) {
                var preview = edge
                let previousID = drag.source ? edge.source : edge.target
                if drag.source { preview.source = target.nodeID; preview.sourcePort = target.port }
                else { preview.target = target.nodeID; preview.targetPort = target.port }
                if previousID != target.nodeID { preview.waypoints = [] }
                if let source = layoutNodeByID[preview.source], let target = layoutNodeByID[preview.target],
                   let sourceNode = nodeByID[preview.source], let targetNode = nodeByID[preview.target] {
                    return CanvasGeometry.edgePoints(preview, source: previewPosition(source), target: previewPosition(target),
                        sourceNode: displayedNode(sourceNode), targetNode: displayedNode(targetNode), settings: settings)
                }
            }
            let fixedID = drag.source ? edge.target : edge.source
            if let position = layoutNodeByID[fixedID], let node = nodeByID[fixedID] {
                let free = worldPoint(for: pointer)
                let fixed = CanvasGeometry.attachment(displayedNode(node), at: previewPosition(position), toward: free,
                    port: drag.source ? edge.targetPort : edge.sourcePort)
                return CanvasGeometry.route(drag.source ? free : fixed, drag.source ? fixed : free,
                    routing: edge.routing ?? settings.edgeRouting, horizontal: ["LR", "RL"].contains(settings.direction))
            }
        }
        guard let source = layoutNodeByID[edge.source], let target = layoutNodeByID[edge.target],
              let sourceNode = nodeByID[edge.source], let targetNode = nodeByID[edge.target] else { return [] }
        let hasPreview = rotationIDs.contains(edge.source) || rotationIDs.contains(edge.target) || dragPreview[edge.source] != nil || dragPreview[edge.target] != nil
            || nodeSizePreview[edge.source] != nil || nodeSizePreview[edge.target] != nil
        return CanvasGeometry.edgePoints(edge, source: previewPosition(source), target: previewPosition(target),
            sourceNode: displayedNode(sourceNode), targetNode: displayedNode(targetNode), settings: settings,
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
        if let node = nodeByID[position.id] {
            result.width = node.width ?? result.width
            result.height = node.height ?? result.height
        }
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
        let bridges = bridgedShafts(diagram: diagram,layout: layout)
        for edge in orderedEdgeLayouts(layout,diagram: diagram).reversed() where edge.points.count >= 2 {
            guard let modelEdge = edgeByID[edge.id] else { continue }
            let route = displayedEdgePoints(modelEdge, geometry: edge, settings: diagram.diagram).map { screenPoint(for: $0) }
            let drawing = drawing(modelEdge, points: route)
            let points = (drawing.tail.map { [$0.tip] } ?? [])+(bridges[edge.id] ?? drawing.shaft)+(drawing.head.map { [$0.tip] } ?? [])
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
