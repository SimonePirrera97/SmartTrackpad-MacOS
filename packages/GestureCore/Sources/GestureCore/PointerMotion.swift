import Foundation

struct TouchPoint: Equatable, Codable { let x: Double; let y: Double }

/// Coordinates use 1000 units per shortest surface dimension; +y points down.
struct PointerMotion {
    private var previous: (id: Int, point: TouchPoint)?

    mutating func update(_ touches: [Int: TouchPoint]) -> PointerDelta? {
        guard touches.count == 1, let touch = touches.first,
              touch.value.x.isFinite, touch.value.y.isFinite else {
            previous = nil
            return nil
        }
        defer { previous = (touch.key, touch.value) }
        guard let previous, previous.id == touch.key else { return nil }
        let delta = PointerDelta(dx: touch.value.x - previous.point.x, dy: touch.value.y - previous.point.y)
        guard delta.valid, delta.dx != 0 || delta.dy != 0 else { return nil }
        return delta
    }

    mutating func reset() { previous = nil }
}
