import Foundation

/// Matches backend/graphischema/container_layout.py. Frames use graph inches;
/// title metrics use screen/PDF points, independently of the diagram's scale.
enum DiagramContainerLayout {
    static let fontSize: CGFloat = 11
    static let headerHeight: CGFloat = 28
    static let labelHeight: CGFloat = 16
    static let labelInsetX: CGFloat = 10
    static let labelInsetTop: CGFloat = 6
    static let minimumWidth: CGFloat = 32
    static let minimumEmptyHeight: CGFloat = 36

    static func frames(containers: [DiagramContainer], members: [String: [CGRect]], emptyFrames: [String: CGRect],
                       scale: CGFloat, paddingOverrides: [String: Double] = [:]) -> [String: CGRect] {
        let byID = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, $0) })
        var children: [String: [String]] = [:]
        for container in containers {
            if let parent = container.parentId, byID[parent] != nil { children[parent, default: []].append(container.id) }
        }
        let scale = max(0.001, scale)
        var result: [String: CGRect] = [:]
        var visiting: Set<String> = []
        func envelope(_ id: String) -> CGRect {
            if let cached = result[id] { return cached }
            guard let container = byID[id], visiting.insert(id).inserted else { return emptyFrames[id] ?? .zero }
            defer { visiting.remove(id) }
            let contents = (members[id] ?? []) + (children[id] ?? []).map(envelope)
            var frame: CGRect
            if let first = contents.first {
                let content = contents.dropFirst().reduce(first) { $0.union($1) }
                let padding = CGFloat(paddingOverrides[id] ?? container.padding)/72
                frame = content.insetBy(dx: -padding, dy: -padding)
                frame.size.height += headerHeight/scale
            } else {
                frame = emptyFrames[id] ?? .zero
                let width = max(frame.width, minimumWidth/scale)
                let height = max(frame.height, minimumEmptyHeight/scale)
                frame = CGRect(x: frame.midX-width/2, y: frame.midY-height/2, width: width, height: height)
            }
            if frame.width < minimumWidth/scale {
                let center = frame.midX
                frame.size.width = minimumWidth/scale
                frame.origin.x = center-frame.width/2
            }
            result[id] = frame
            return frame
        }
        for container in containers { _ = envelope(container.id) }
        return result
    }

    static func labelFrame(in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX+labelInsetX, y: frame.maxY-labelInsetTop-labelHeight,
               width: max(0, frame.width-2*labelInsetX), height: labelHeight)
    }
}
