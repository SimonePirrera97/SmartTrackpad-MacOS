import Foundation

/// Stable two-contact scale, independent of any native or shortcut zoom backend.
struct PinchMotion {
    private var ids: [Int] = []
    private var initialDistance: Double = 0
    private var initialAngle: Double = 0
    private var cancelled = false

    mutating func update(_ touches: [Int: TouchPoint]) -> Double? {
        guard touches.count == 2, touches.values.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            reset(); return nil
        }
        let sorted = touches.sorted { $0.key < $1.key }
        let nextIDs = sorted.map(\.key)
        let dx = sorted[1].value.x - sorted[0].value.x
        let dy = sorted[1].value.y - sorted[0].value.y
        let distance = hypot(dx, dy)
        let angle = atan2(dy, dx)
        if ids != nextIDs {
            ids = nextIDs
            initialDistance = distance
            initialAngle = angle
            cancelled = distance < 60
            return nil
        }
        let rotation = atan2(sin(angle - initialAngle), cos(angle - initialAngle))
        if abs(rotation) > 0.2 || distance < 20 { cancelled = true }
        guard !cancelled, initialDistance > 0 else { return nil }
        return distance / initialDistance
    }

    mutating func reset() {
        ids = []; initialDistance = 0; initialAngle = 0; cancelled = false
    }

    static func changes(from previous: Double, to scale: Double) -> [InputCommand]? {
        guard previous.isFinite, scale.isFinite, previous > 0, scale > 0 else { return nil }
        let ratio = scale / previous
        guard ratio.isFinite, ratio > 0 else { return nil }
        if abs(ratio - 1) < 0.000001 { return [] }
        let count = ceil(abs(log(ratio)) / log(1.5))
        guard count.isFinite, count <= 16 else { return nil }
        let steps = max(1, Int(count))
        let amount = max(-0.5, min(0.5, pow(ratio, 1 / Double(steps)) - 1))
        return Array(repeating: .magnify(amount, phase: .changed), count: steps)
    }
}
