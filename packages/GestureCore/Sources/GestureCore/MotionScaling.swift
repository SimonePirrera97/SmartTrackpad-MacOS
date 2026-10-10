import Foundation

enum MotionScaling {
    static func commands(_ command: InputCommand, factor: Double) -> [InputCommand] {
        guard factor.isFinite, let delta = command.delta else { return [command] }
        let x = delta.dx * factor
        let y = delta.dy * factor
        var scaled = command
        if command.kind != .scroll {
            scaled.delta = PointerDelta(dx: max(-128, min(128, x)), dy: max(-128, min(128, y)))
            return [scaled]
        }
        // Preserve scaled flick distance without exceeding an individual wire packet.
        let count = ceil(max(abs(x), abs(y)) / 2048)
        guard count.isFinite, count <= 16 else { return [] }
        let steps = max(1, Int(count))
        scaled.delta = PointerDelta(dx: x / Double(steps), dy: y / Double(steps))
        if let interval = command.sampleIntervalMilliseconds {
            scaled.sampleIntervalMilliseconds = interval / Double(steps)
        }
        return (0..<steps).map { index in
            var part = scaled
            if index > 0 && command.phase == .began { part.phase = .changed }
            return part
        }
    }
}
