import Foundation

/// Bounded ring FIFO. Lifecycle/button/action barriers remain ordered; changes
/// coalesce without clipping distance, flattening reversals or adding pinch scales.
struct InputQueue {
    private struct Entry { var command: InputCommand; var time: Double; var direction: Double = 0 }
    static let capacity = 64
    private var entries = [Entry?](repeating: nil, count: capacity)
    private var head = 0
    private(set) var count = 0
    private var lastNavigation: [InputKind: Double] = [:]
    private(set) var coalesced: UInt64 = 0
    private(set) var staleDropped: UInt64 = 0
    private(set) var highWater = 0

    mutating func append(_ command: InputCommand, at time: Double) -> Bool {
        guard command.valid, time.isFinite else { return false }
        if command.kind == .releaseAll { clear() }
        var direction = 0.0
        if command.kind == .pageSwipe || command.kind == .missionControl {
            direction = command.progress! - (lastNavigation[command.kind] ?? command.progress!)
            lastNavigation[command.kind] = command.endsGesture ? nil : command.progress
        }
        if count > 0 {
            let index = (head + count - 1) % Self.capacity
            let last = entries[index]!
            if let combined = merge(last.command, command, fresh: time - last.time <= 0.25,
                                    direction: direction, previousDirection: last.direction) {
                entries[index] = Entry(command: combined, time: time, direction: direction)
                coalesced += 1
                return true
            }
        }
        guard count < Self.capacity else { return false }
        entries[(head + count) % Self.capacity] = Entry(command: command, time: time, direction: direction)
        count += 1; highWater = max(highWater, count)
        return true
    }

    private func merge(_ old: InputCommand, _ next: InputCommand, fresh: Bool,
                       direction: Double, previousDirection: Double) -> InputCommand? {
        guard old.kind == next.kind else { return nil }
        let change = old.phase == .changed && next.phase == .changed
        guard next.kind == .move || (change && [.scroll, .magnify, .pageSwipe, .missionControl].contains(next.kind)) else { return nil }
        guard fresh else { return next }
        var combined = next
        let duration = (old.sampleIntervalMilliseconds ?? 0) + (next.sampleIntervalMilliseconds ?? 0)
        if duration > 250 { return nil }
        switch next.kind {
        case .move, .scroll:
            let a = old.delta!, b = next.delta!
            if next.kind == .scroll && a.dx * b.dx + a.dy * b.dy < 0 { return nil }
            let delta = PointerDelta(dx: a.dx + b.dx, dy: a.dy + b.dy)
            guard next.kind == .scroll ? delta.scrollValid : delta.valid else { return nil }
            combined.delta = delta
        case .magnify:
            let a = old.magnification!, b = next.magnification!
            guard a * b >= 0 else { return nil }
            let amount = (1 + a) * (1 + b) - 1
            guard abs(amount) <= 0.5 else { return nil }
            combined.magnification = amount
        case .pageSwipe, .missionControl:
            // Absolute progress replaces the previous sample, but a reversal
            // remains a barrier so finger-controlled retreat is observable.
            guard direction * previousDirection >= 0 else { return nil }
        default: return nil
        }
        if old.sampleIntervalMilliseconds != nil && next.sampleIntervalMilliseconds != nil {
            combined.sampleIntervalMilliseconds = duration
        }
        return combined.valid ? combined : nil
    }

    mutating func pop(at time: Double) -> InputCommand? {
        while count > 0 {
            let entry = entries[head]!
            entries[head] = nil; head = (head + 1) % Self.capacity; count -= 1
            if entry.command.releases || time - entry.time <= 0.25 { return entry.command }
            staleDropped += 1
        }
        return nil
    }
    private mutating func clear() {
        while count > 0 { entries[head] = nil; head = (head + 1) % Self.capacity; count -= 1 }
        lastNavigation.removeAll(keepingCapacity: true)
    }
    mutating func reset() { clear(); coalesced = 0; staleDropped = 0; highWater = 0 }
}
