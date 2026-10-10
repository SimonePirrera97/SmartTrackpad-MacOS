import Foundation

/// Portable three-contact navigation. Distances use the same 1000-unit surface
/// as pointer recognition. The Apple adapter decides how to deliver these steps.
struct NavigationGesture {
    enum Axis: String { case pages, missionControl }
    struct Step: Equatable {
        var axis: Axis
        var phase: ScrollPhase
        /// Signed, absolute progress since the gesture began; reversal is lossless.
        var progress: Double
    }
    var pagesEnabled = false
    var missionControlEnabled = false
    private var identities: Set<Int> = []
    private var origin: TouchPoint?
    private var axis: Axis?
    private var progress = 0.0
    private var suppressed = false

    mutating func update(_ touches: [Int: TouchPoint]) -> [Step] {
        guard touches.values.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return cancel() }
        if touches.isEmpty {
            let result = axis.map { [Step(axis: $0, phase: .ended, progress: progress)] } ?? []
            reset()
            return result
        }
        guard !suppressed else { return [] }
        guard touches.count == 3 else {
            if axis != nil || origin != nil {
                let lifting = touches.count < 3 && Set(touches.keys).isSubset(of: identities)
                let result = axis.map { [Step(axis: $0, phase: lifting ? .ended : .cancelled, progress: progress)] } ?? []
                reset()
                suppressed = true
                return result
            }
            return []
        }
        let center = TouchPoint(x: touches.values.reduce(0) { $0 + $1.x } / 3,
                                y: touches.values.reduce(0) { $0 + $1.y } / 3)
        if origin == nil {
            origin = center
            identities = Set(touches.keys)
            return []
        }
        guard identities == Set(touches.keys) else {
            let result = cancel()
            suppressed = true
            return result
        }
        let dx = center.x - origin!.x
        let dy = center.y - origin!.y
        var result: [Step] = []
        if axis == nil {
            if pagesEnabled, abs(dx) >= 30, abs(dx) > abs(dy) * 1.5 { axis = .pages }
            else if missionControlEnabled, abs(dy) >= 30, abs(dy) > abs(dx) * 1.5 { axis = .missionControl }
            if let axis { result.append(Step(axis: axis, phase: .began, progress: 0)) }
        }
        if let axis {
            let updated = max(-3, min(3, (axis == .pages ? dx : -dy) / 300))
            if updated != progress {
                progress = updated
                result.append(Step(axis: axis, phase: .changed, progress: progress))
            }
        }
        return result
    }

    mutating func cancel() -> [Step] {
        let result = axis.map { [Step(axis: $0, phase: .cancelled, progress: progress)] } ?? []
        reset()
        return result
    }

    private mutating func reset() {
        identities = []; origin = nil; axis = nil; progress = 0; suppressed = false
    }
}
