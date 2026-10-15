import AppKit

/// Drawing geometry only: leave canonical routes and arrow joins intact.
enum LineCrossings {
    static func bridge(_ points: [NSPoint], over lowerPaths: [[NSPoint]], radius: CGFloat = 5) -> [NSPoint] {
        guard points.count > 1, !lowerPaths.isEmpty else { return points }
        var distances: [CGFloat] = [0]
        for (a,b) in zip(points,points.dropFirst()) { distances.append(distances.last!+hypot(b.x-a.x,b.y-a.y)) }
        var crossings: [CGFloat] = []
        for index in 0..<points.count-1 {
            let a = points[index], b = points[index+1], dx = b.x-a.x, dy = b.y-a.y, length = distances[index+1]-distances[index]
            guard length > 1e-8 else { continue }
            for lower in lowerPaths { for (lowerIndex,pair) in zip(lower,lower.dropFirst()).enumerated() {
                let (c,d) = pair
                guard max(a.x,b.x)+1e-8 >= min(c.x,d.x), min(a.x,b.x)-1e-8 <= max(c.x,d.x),
                      max(a.y,b.y)+1e-8 >= min(c.y,d.y), min(a.y,b.y)-1e-8 <= max(c.y,d.y) else { continue }
                let sx = d.x-c.x, sy = d.y-c.y, det = dx*sy-dy*sx
                guard abs(det)>1e-9 else { continue }
                let t = ((c.x-a.x)*sy-(c.y-a.y)*sx)/det, u = ((c.x-a.x)*dy-(c.y-a.y)*dx)/det
                if t >= -1e-8 && t <= 1+1e-8 && u >= -1e-8 && u <= 1+1e-8 {
                    guard straddles(points,index: index,t: t,a: c,b: d),straddles(lower,index: lowerIndex,t: u,a: a,b: b) else { continue }
                    let distance = distances[index]+max(0,min(1,t))*length
                    if distance>radius*2 && distance<distances.last!-radius*2 { crossings.append(distance) }
                }
            } }
        }
        var unique: [CGFloat] = []
        for distance in crossings.sorted() where unique.last.map({ distance-$0>radius*2.5 }) ?? true { unique.append(distance) }
        func sample(_ distance: CGFloat) -> NSPoint {
            var low = 0, high = distances.count-1
            while low+1<high { let mid = (low+high)/2; if distances[mid]<=distance { low = mid } else { high = mid } }
            let a = points[low], b = points[low+1], length = distances[low+1]-distances[low]
            let t = length>0 ? (distance-distances[low])/length : 0
            return .init(x: a.x+(b.x-a.x)*t, y: a.y+(b.y-a.y)*t)
        }
        var result: [NSPoint] = [], cursor = 0
        for distance in unique {
            let start = distance-radius, end = distance+radius
            let a = sample(start), b = sample(end), dx = b.x-a.x, dy = b.y-a.y, length = hypot(b.x-a.x,b.y-a.y)
            guard length>=radius else { continue }
            while cursor<points.count && distances[cursor]<start { result.append(points[cursor]); cursor += 1 }
            var nx = -dy/length, ny = dx/length
            // Native Y points up; SVG uses the reflected equivalent.
            if ny < -1e-8 || (abs(ny)<1e-8 && nx<0) { nx = -nx; ny = -ny }
            for step in 0...16 {
                let t = CGFloat(step)/16, base = sample(start+(end-start)*t), offset = radius*pow(sin(.pi*t),2)
                result.append(.init(x: base.x+nx*offset, y: base.y+ny*offset))
            }
            while cursor<points.count && distances[cursor]<=end { cursor += 1 }
        }
        return result+points[cursor...]
    }
    private static func straddles(_ path: [NSPoint],index: Int,t: CGFloat,a: NSPoint,b: NSPoint) -> Bool {
        let before = t<=1e-8 && index>0 ? path[index-1] : path[index]
        let after = t>=1-1e-8 && index+2<path.count ? path[index+2] : path[index+1]
        func side(_ p: NSPoint) -> CGFloat { (b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x) }
        return side(before)*side(after) < -1e-12
    }

}
