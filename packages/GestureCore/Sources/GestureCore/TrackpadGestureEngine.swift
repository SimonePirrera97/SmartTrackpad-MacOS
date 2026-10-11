import Foundation

struct GestureOptions: Equatable {
    var tapToClick = true
    var twoFingerTap = true
    var holdToDrag = true
    var threeFingerDrag = false
    var nativePinch = false
    var interactiveMissionControl = false
    var pageSwipes = false
    var holdDuration = 0.45
    var tapDuration = 0.28
    var movementThreshold = 12.0
}

/// Complete contact snapshots and monotonic seconds in; platform-neutral commands out.
struct TrackpadGestureEngine {
    var options = GestureOptions()
    private var previous: [Int: TouchPoint] = [:]
    private var pointerMotion = PointerMotion()
    private var origins: [Int: TouchPoint] = [:]
    private var began: Double = 0
    private var peak = 0
    private var travel = 0.0
    private var dragging = false
    private var dragContacts = 1
    private var scrolling = false
    private var suppressed = false
    private var lastTap: (time: Double, point: TouchPoint, count: Int)?
    private var lastUpdate: Double?
    private var twoFingerBase: (distance: Double, angle: Double)?
    private var holdAnchor: (point: TouchPoint, time: Double)?
    private var pinchMotion = PinchMotion()
    private(set) var pinchScale: Double?
    private var pinching = false
    private var previousPinchScale = 1.0
    private var navigation = NavigationGesture()

    /// Deadline follows the latest stationary interval, independently of tap travel.
    var holdDeadline: Double? {
        guard options.holdToDrag, !dragging, !suppressed, peak == 1,
              previous.count == 1, let holdAnchor else { return nil }
        return holdAnchor.time + options.holdDuration
    }

    mutating func update(_ touches: [Int: TouchPoint], at time: Double) -> [InputCommand] {
        guard time.isFinite, time >= (lastUpdate ?? time),
              touches.values.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return cancel() }
        lastUpdate = time
        pinchScale = pinchMotion.update(touches)
        let pointerDelta = pointerMotion.update(touches)
        var output: [InputCommand] = []
        if previous.isEmpty && !touches.isEmpty {
            began = time; peak = 0; travel = 0; origins = touches; suppressed = false
            output.append(.stopMomentum)
        }
        for (id, point) in touches {
            if origins[id] == nil { origins[id] = point }
            if let origin = origins[id] {
                travel = max(travel, hypot(point.x - origin.x, point.y - origin.y))
            }
        }
        peak = max(peak, touches.count)
        if peak > 1 || travel > options.movementThreshold { lastTap = nil }
        if touches.count > 3 || (touches.count == 3 && !options.threeFingerDrag && !options.interactiveMissionControl && !options.pageSwipes) { suppressed = true }
        if touches.count == 1 && previous.count == 1 && Set(touches.keys) != Set(previous.keys) { suppressed = true }

        navigation.pagesEnabled = options.pageSwipes && !options.threeFingerDrag
        navigation.missionControlEnabled = options.interactiveMissionControl && !options.threeFingerDrag
        if navigation.pagesEnabled || navigation.missionControlEnabled {
            let steps = suppressed ? navigation.cancel() : navigation.update(touches)
            output.append(contentsOf: steps.map {
                .navigation($0.axis == .pages ? .pageSwipe : .missionControl, progress: $0.progress, phase: $0.phase)
            })
            // A navigation contact group never leaks scroll, pointer or lift clicks.
            if touches.count == 3 || !steps.isEmpty {
                if scrolling { output.append(.scroll(PointerDelta(dx: 0, dy: 0), phase: .cancelled)); scrolling = false }
                if dragging { output.append(.button(.left, pressed: false)); dragging = false }
                if pinching { output.append(.magnify(0, phase: .cancelled)); pinching = false }
                lastTap = nil; holdAnchor = nil
                if touches.count < 3 { suppressed = true }
                previous = touches
                return output
            }
        }

        if pinching {
            let stable = options.nativePinch && touches.count == 2 && Set(touches.keys) == Set(previous.keys)
            if stable, let scale = pinchScale, let changes = PinchMotion.changes(from: previousPinchScale, to: scale) {
                output.append(contentsOf: changes)
                previousPinchScale = scale
            } else {
                output.append(.magnify(0, phase: touches.count < 2 ? .ended : .cancelled))
                pinching = false
                suppressed = true
            }
            previous = touches
            holdAnchor = nil
            return output
        }

        // Once scrolling starts, latch that gesture. Finger-spacing/angle jitter
        // during a fast flick must not cancel it or discard its momentum.
        if touches.count == 2 {
            let points = touches.sorted { $0.key < $1.key }.map(\.value)
            let dx = points[1].x - points[0].x
            let dy = points[1].y - points[0].y
            let distance = hypot(dx, dy)
            let angle = atan2(dy, dx)
            if previous.count != 2 || Set(previous.keys) != Set(touches.keys) { twoFingerBase = (distance, angle) }
            if let base = twoFingerBase, !scrolling, !suppressed {
                let rotation = atan2(sin(angle - base.angle), cos(angle - base.angle))
                let centerTravel = hypot(centroid(touches).x - centroid(origins).x,
                                         centroid(touches).y - centroid(origins).y)
                let scaleTravel = abs(distance - base.distance)
                if options.nativePinch, abs(rotation) <= 0.2,
                   scaleTravel > max(12, base.distance * 0.06), scaleTravel > centerTravel * 1.2,
                   let scale = pinchScale, let changes = PinchMotion.changes(from: 1, to: scale) {
                    pinching = true
                    previousPinchScale = scale
                    lastTap = nil
                    output.append(.magnify(0, phase: .began))
                    output.append(contentsOf: changes)
                    previous = touches
                    holdAnchor = nil
                    return output
                }
                if scaleTravel > max(30, base.distance * 0.15) && scaleTravel > centerTravel * 1.2
                    || (abs(rotation) > 0.2 && centerTravel < options.movementThreshold * 2) {
                    suppressed = true
                }
            }
        } else { twoFingerBase = nil }

        if dragging && touches.count != dragContacts {
            output.append(.button(.left, pressed: false)); dragging = false; suppressed = true
        }
        if touches.count == 3 && previous.count == 3 && Set(touches.keys) != Set(previous.keys) { suppressed = true }
        if touches.count < 3 && previous.count == 3 {
            // Finger removal cannot turn a system action into a click or scroll.
            suppressed = true
        }
        if scrolling && touches.count != 2 {
            output.append(.scroll(PointerDelta(dx: 0, dy: 0), phase: .ended)); scrolling = false
        }

        if touches.isEmpty && !previous.isEmpty {
            if !suppressed && !dragging && time - began <= options.tapDuration && travel <= options.movementThreshold {
                if peak == 1 && options.tapToClick {
                    let point = origins.values.first!
                    let count: Int
                    if let tap = lastTap, time - tap.time <= 0.35,
                       hypot(point.x - tap.point.x, point.y - tap.point.y) <= 30 {
                        count = tap.count == 3 ? 1 : tap.count + 1
                    } else { count = 1 }
                    lastTap = (time, point, count)
                    output.append(.click(.left, count: count))
                } else if peak == 2 && options.twoFingerTap {
                    lastTap = nil
                    output.append(.click(.right))
                }
            }
            previous = [:]; origins = [:]; peak = 0; holdAnchor = nil
            return output
        }

        if !suppressed, touches.count == 1, peak == 1 {
            let point = touches.values.first!
            if holdAnchor == nil || hypot(point.x - holdAnchor!.point.x, point.y - holdAnchor!.point.y) > options.movementThreshold {
                holdAnchor = (point, time)
            }
            if !dragging && options.holdToDrag && time >= holdAnchor!.time + options.holdDuration {
                output.append(.button(.left, pressed: true)); dragging = true; dragContacts = 1; lastTap = nil
            }
            if let delta = pointerDelta { output.append(.move(delta)) }
        } else if !suppressed, touches.count == 3, options.threeFingerDrag,
                  Set(touches.keys) == Set(previous.keys), travel > options.movementThreshold {
            let center = centroid(touches)
            let old = centroid(previous)
            let delta = PointerDelta(dx: center.x - old.x, dy: center.y - old.y)
            if delta.valid && (delta.dx != 0 || delta.dy != 0) {
                if !dragging { output.append(.button(.left, pressed: true)); dragging = true; dragContacts = 3 }
                output.append(.move(delta))
            }
        } else if !suppressed, touches.count == 2, Set(touches.keys) == Set(previous.keys) {
            let center = centroid(touches)
            let old = centroid(previous)
            let delta = PointerDelta(dx: center.x - old.x, dy: center.y - old.y)
            if delta.scrollValid && (delta.dx != 0 || delta.dy != 0) && travel > options.movementThreshold {
                output.append(.scroll(delta, phase: scrolling ? .changed : .began))
                scrolling = true
                lastTap = nil
            }
        }
        previous = touches
        if suppressed || peak != 1 || touches.count != 1 { holdAnchor = nil }
        return output
    }

    mutating func cancel() -> [InputCommand] {
        var output: [InputCommand] = navigation.cancel().map {
            .navigation($0.axis == .pages ? .pageSwipe : .missionControl, progress: $0.progress, phase: $0.phase)
        }
        if dragging { output.append(.button(.left, pressed: false)) }
        if scrolling { output.append(.scroll(PointerDelta(dx: 0, dy: 0), phase: .cancelled)) }
        if pinching { output.append(.magnify(0, phase: .cancelled)) }
        pinching = false
        previousPinchScale = 1
        previous = [:]; origins = [:]; dragging = false; scrolling = false
        dragContacts = 1
        peak = 0; travel = 0; suppressed = false; lastTap = nil
        lastUpdate = nil
        twoFingerBase = nil
        holdAnchor = nil
        pinchMotion.reset()
        pinchScale = nil
        pointerMotion.reset()
        return output
    }

    private func centroid(_ points: [Int: TouchPoint]) -> TouchPoint {
        let count = Double(points.count)
        return TouchPoint(x: points.values.reduce(0) { $0 + $1.x } / count,
                          y: points.values.reduce(0) { $0 + $1.y } / count)
    }
}
