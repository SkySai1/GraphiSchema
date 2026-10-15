import AppKit

/// A diagram fragment keeps references until insertion, when every copied ID is remapped.
struct DiagramClipboard: Codable {
    static let pasteboardType = NSPasteboard.PasteboardType("local.graphischema.diagram-fragment")
    var formatVersion = 1
    var projectId: String
    var rootContainerIds: [String]
    var containers: [DiagramContainer]
    var nodes: [DiagramNode]
    var edges: [DiagramEdge]

    static func capture(_ selection: DiagramSelection, from project: DiagramProject,
                        layout: DiagramLayout?) -> DiagramClipboard? {
        var containerIds: Set<String> = []
        var nodeIds: Set<String> = []
        var edgeIds: Set<String> = []
        var roots: [String] = []
        switch selection {
        case .project: return nil
        case .node(let id): nodeIds = [id]
        case .nodes(let ids): nodeIds = ids
        case .edge, .edges: edgeIds = selection.edgeIDs
        case .container(let id):
            roots = [id]
            containerIds = [id]
            var expanded = true
            while expanded {
                expanded = false
                for container in project.containers where container.parentId.map(containerIds.contains) == true {
                    if containerIds.insert(container.id).inserted { expanded = true }
                }
            }
            nodeIds = Set(project.nodes.filter { $0.containerId.map(containerIds.contains) == true }.map(\.id))
        }
        let positions = Dictionary(uniqueKeysWithValues: (layout?.nodes ?? []).map { ($0.id, $0) })
        let nodes = project.nodes.filter { nodeIds.contains($0.id) }.map { node in
            var result = node
            let position = positions[node.id]
            result.x = (project.diagram.layoutMode == "manual" ? node.x : position?.x) ?? position?.x ?? node.x ?? 0
            result.y = (project.diagram.layoutMode == "manual" ? node.y : position?.y) ?? position?.y ?? node.y ?? 0
            result.width = min(10, max(0.5, node.width ?? position?.width ?? 1))
            result.height = min(10, max(0.5, node.height ?? position?.height ?? 0.62))
            return result
        }
        let containers = project.containers.filter { containerIds.contains($0.id) }.map { container in
            var result = container
            result.x = container.x ?? (layout?.minX ?? 0) + 1.6
            result.y = container.y ?? (layout?.minY ?? 0) + 1.2
            return result
        }
        let edges = project.edges.filter {
            edgeIds.contains($0.id) || (nodeIds.contains($0.source) && nodeIds.contains($0.target))
        }
        guard !nodes.isEmpty || !containers.isEmpty || !edges.isEmpty else { return nil }
        return DiagramClipboard(projectId: project.project.id, rootContainerIds: roots,
                                containers: containers, nodes: nodes, edges: edges)
    }

    func inserting(into project: DiagramProject, layout: DiagramLayout?, delta: NSPoint, containerOverrides: [String: String] = [:])
        -> (project: DiagramProject, selection: DiagramSelection)? {
        guard formatVersion == 1, delta.x.isFinite, delta.y.isFinite,
              Set(nodes.map(\.id)).count == nodes.count,
              Set(containers.map(\.id)).count == containers.count,
              Set(edges.map(\.id)).count == edges.count,
              !nodes.isEmpty || !containers.isEmpty || !edges.isEmpty else { return nil }
        var result = project
        var usedIds = Set(project.nodes.map(\.id) + project.containers.map(\.id) + project.edges.map(\.id))
        func newId(_ prefix: String) -> String {
            var value: String
            repeat { value = prefix + "_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
            while !usedIds.insert(value).inserted
            return value
        }
        let nodeIds = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, newId("node")) })
        let containerIds = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, newId("zone")) })
        let validContainers = Set(project.containers.map(\.id))
        let validNodes = Set(project.nodes.map(\.id))
        let sameProject = projectId == project.project.id
        let positions = Dictionary(uniqueKeysWithValues: (layout?.nodes ?? []).map { ($0.id, $0) })
        for index in result.nodes.indices {
            let node = result.nodes[index]
            if result.diagram.layoutMode == "auto" || node.x == nil || node.y == nil {
                result.nodes[index].x = positions[node.id]?.x ?? node.x ?? 0
                result.nodes[index].y = positions[node.id]?.y ?? node.y ?? 0
            }
        }
        func translated(_ value: Double?, by offset: CGFloat) -> Double {
            min(1000, max(-1000, (value ?? 0) + Double(offset)))
        }
        let copiedContainers = containers.map { container in
            var copy = container
            copy.id = containerIds[container.id]!
            copy.parentId = container.parentId.flatMap {
                containerIds[$0] ?? (sameProject && validContainers.contains($0) ? $0 : nil)
            }
            copy.x = translated(container.x, by: delta.x)
            copy.y = translated(container.y, by: delta.y)
            return copy
        }
        let copiedNodes = nodes.map { node in
            var copy = node
            copy.id = nodeIds[node.id]!
            copy.containerId = node.containerId.flatMap {
                containerIds[$0] ?? (sameProject && validContainers.contains($0) ? $0 : nil)
            }
            if copy.containerId == nil, let target = containerOverrides[node.id], validContainers.contains(target) {
                copy.containerId = target
            }
            copy.x = translated(node.x, by: delta.x)
            copy.y = translated(node.y, by: delta.y)
            return copy
        }
        var copiedEdges: [DiagramEdge] = []
        for edge in edges {
            guard let source = nodeIds[edge.source] ?? (sameProject && validNodes.contains(edge.source) ? edge.source : nil),
                  let target = nodeIds[edge.target] ?? (sameProject && validNodes.contains(edge.target) ? edge.target : nil) else { continue }
            var copy = edge
            copy.id = newId("edge")
            copy.source = source
            copy.target = target
            if nodeIds[edge.source] != nil && nodeIds[edge.target] != nil {
                copy.waypoints = edge.waypoints.map {
                    RoutePoint(x: translated($0.x, by: delta.x), y: translated($0.y, by: delta.y))
                }
            }
            copiedEdges.append(copy)
        }
        guard !copiedContainers.isEmpty || !copiedNodes.isEmpty || !copiedEdges.isEmpty else { return nil }
        result.diagram.layoutMode = "manual"
        result.containers += copiedContainers
        result.nodes += copiedNodes
        result.edges += copiedEdges
        let selection: DiagramSelection
        if let root = rootContainerIds.first.flatMap({ containerIds[$0] }) { selection = .container(root) }
        else if copiedNodes.count == 1 { selection = .node(copiedNodes[0].id) }
        else if !copiedNodes.isEmpty { selection = .nodes(Set(copiedNodes.map(\.id))) }
        else { selection = .edgeGroup(Set(copiedEdges.map(\.id))) }
        return (result, selection)
    }
}
