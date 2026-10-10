import Foundation

/// Time-based smoothing uses client sample intervals instead of packet arrival jitter.
struct ScrollVelocity {
    private var velocity = PointerDelta(dx: 0, dy: 0)
    private var lastTime: Double?

    mutating func sample(_ delta: PointerDelta, at time: Double, interval: Double?) {
        guard delta.scrollValid, time.isFinite, time >= (lastTime ?? time) else { reset(); return }
        let dt = interval ?? lastTime.map { time - $0 }
        defer { lastTime = time }
        guard let dt, dt >= 0.001, dt <= 0.25 else { return }
        let measured = PointerDelta(dx: max(-20000, min(20000, delta.dx / dt)),
                                    dy: max(-20000, min(20000, delta.dy / dt)))
        let weight = lastTime == nil ? 1 : 1 - exp(-dt / 0.035)
        velocity = PointerDelta(dx: velocity.dx + weight * (measured.dx - velocity.dx),
                                dy: velocity.dy + weight * (measured.dy - velocity.dy))
    }

    func released(at time: Double) -> PointerDelta {
        guard let lastTime, time.isFinite, time >= lastTime, time - lastTime <= 0.12 else {
            return PointerDelta(dx: 0, dy: 0)
        }
        let attenuation = exp(-(time - lastTime) / 0.08)
        return PointerDelta(dx: velocity.dx * attenuation, dy: velocity.dy * attenuation)
    }

    mutating func reset() { velocity = PointerDelta(dx: 0, dy: 0); lastTime = nil }
}
