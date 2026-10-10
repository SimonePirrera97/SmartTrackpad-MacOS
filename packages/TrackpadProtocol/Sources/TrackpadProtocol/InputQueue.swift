import Foundation

/// FIFO barriers preserve button/scroll lifecycle order. High-rate motion is coalesced.
struct InputQueue {
    private struct Entry { var command: InputCommand; var time: Double }
    private var entries: [Entry] = []
    static let capacity = 64
    var count: Int { entries.count }

    mutating func append(_ command: InputCommand, at time: Double) -> Bool {
        guard command.valid, time.isFinite else { return false }
        if command.kind == .releaseAll { entries.removeAll() }
        if let last = entries.last, last.command.kind == command.kind,
           command.kind == .move || (command.kind == .scroll && command.phase == .changed && last.command.phase == .changed),
           let old = last.command.delta, let delta = command.delta {
            var combined = command
            let fresh = time - last.time <= 0.25
            let sum = PointerDelta(dx: (fresh ? old.dx : 0) + delta.dx,
                                   dy: (fresh ? old.dy : 0) + delta.dy)
            if command.kind == .scroll, fresh {
                // Preserve large flick distance and reversals; never clip a combined
                // scroll or collapse opposite-direction samples into a zero sample.
                let reversed = old.dx * delta.dx + old.dy * delta.dy < 0
                let duration = (last.command.sampleIntervalMilliseconds ?? 0) + (command.sampleIntervalMilliseconds ?? 0)
                if !sum.scrollValid || reversed || duration > 250 {
                    guard entries.count < Self.capacity else { return false }
                    entries.append(Entry(command: command, time: time))
                    return true
                }
            }
            combined.delta = command.kind == .scroll ? sum
                : PointerDelta(dx: max(-128, min(128, sum.dx)), dy: max(-128, min(128, sum.dy)))
            if fresh, let previousInterval = last.command.sampleIntervalMilliseconds,
               let interval = command.sampleIntervalMilliseconds {
                combined.sampleIntervalMilliseconds = min(250, previousInterval + interval)
            }
            entries[entries.count - 1] = Entry(command: combined, time: time)
            return true
        }
        guard entries.count < Self.capacity else { return false }
        entries.append(Entry(command: command, time: time))
        return true
    }

    mutating func pop(at time: Double) -> InputCommand? {
        while !entries.isEmpty {
            let entry = entries.removeFirst()
            let release = entry.command.kind == .releaseAll
                || (entry.command.kind == .button && entry.command.pressed == false)
                || entry.command.endsGesture
            if release || time - entry.time <= 0.25 { return entry.command }
        }
        return nil
    }

    mutating func reset() { entries.removeAll() }
}
