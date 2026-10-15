import AppKit

enum DiagramAlignment {
    struct Result { var delta: NSPoint; var vertical: CGFloat?; var horizontal: CGFloat? }
    /// A fixed screen tolerance becomes a world tolerance at the current zoom.
    /// Stable peer order and center-first anchors prevent jitter on equal distances.
    static func snap(moving: NSRect, peers: [NSRect], delta: NSPoint, scale: CGFloat,
                     enabled: Bool, lockedHorizontal: Bool? = nil) -> Result {
        var result = Result(delta: delta)
        guard enabled, scale > 0 else { return result }
        let moved = moving.offsetBy(dx: delta.x, dy: delta.y), tolerance = 6 / scale
        func match(_ anchors: [CGFloat], _ targets: [CGFloat]) -> (CGFloat, CGFloat)? {
            var best: (CGFloat, CGFloat)?
            for anchor in anchors { for target in targets {
                let shift = target - anchor
                if abs(shift) <= tolerance && (best == nil || abs(shift) < abs(best!.0) - 1e-9) { best = (shift, target) }
            } }
            return best
        }
        if lockedHorizontal != false, let x = match([moved.midX, moved.minX, moved.maxX], peers.flatMap { [$0.midX, $0.minX, $0.maxX] }) {
            result.delta.x += x.0; result.vertical = x.1
        }
        if lockedHorizontal != true, let y = match([moved.midY, moved.minY, moved.maxY], peers.flatMap { [$0.midY, $0.minY, $0.maxY] }) {
            result.delta.y += y.0; result.horizontal = y.1
        }
        return result
    }
}
