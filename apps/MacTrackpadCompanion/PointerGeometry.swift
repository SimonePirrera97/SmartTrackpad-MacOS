import Foundation
import CoreGraphics

enum PointerGeometry {
    static func clamp(_ point: CGPoint, to displays: [CGRect]) -> CGPoint {
        if displays.contains(where: { $0.contains(point) }) { return point }
        let candidates = displays.filter { $0.width > 0 && $0.height > 0 }.map {
            CGPoint(x: min(max(point.x, $0.minX), $0.maxX - 1),
                    y: min(max(point.y, $0.minY), $0.maxY - 1))
        }
        return candidates.min {
            hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y)
        } ?? point
    }
}
