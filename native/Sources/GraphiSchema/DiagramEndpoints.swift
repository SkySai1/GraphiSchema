import AppKit

/// Container envelopes can serve as endpoints without introducing visible nodes.
enum DiagramEndpoints {
    static func frames(project: DiagramProject,nodes: [LayoutNode],previous: [LayoutNode] = [],scale: CGFloat = 72) -> [String:NSRect] {
        let figures = Dictionary(uniqueKeysWithValues: project.nodes.map { ($0.id,$0) })
        let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.id,$0) })
        var members: [String:[NSRect]] = [:], empty: [String:NSRect] = [:]
        for position in nodes {
            guard let node = figures[position.id],let parent = node.containerId else { continue }
            members[parent,default: []].append(CanvasGeometry.visualBounds(NSRect(x: position.x-position.width/2,y: position.y-position.height/2,width: position.width,height: position.height),rotation: node.effectiveRotation))
        }
        for container in project.containers {
            let x = container.x ?? old[container.id]?.x ?? 1.6, y = container.y ?? old[container.id]?.y ?? 1.2
            empty[container.id] = NSRect(x: x-container.width/2,y: y-container.height/2,width: container.width,height: container.height)
        }
        return DiagramContainerLayout.frames(containers: project.containers,members: members,emptyFrames: empty,scale: scale)
    }
    static func positions(nodes: [LayoutNode],frames: [String:NSRect]) -> [String:LayoutNode] {
        var result = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id,$0) })
        for (id,rect) in frames { result[id] = LayoutNode(id: id,x: rect.midX,y: rect.midY,width: rect.width,height: rect.height) }
        return result
    }
}
