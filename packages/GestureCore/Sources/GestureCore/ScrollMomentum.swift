import Foundation

struct ScrollMomentum {
    private(set) var velocity: PointerDelta
    private var elapsed = 0.0
    private let decay: Double

    init(velocity: PointerDelta, length: Double = 1) {
        self.velocity = PointerDelta(dx: max(-20000, min(20000, velocity.dx)), dy: max(-20000, min(20000, velocity.dy)))
        decay = 3 / (length.isFinite ? max(0.5, min(2, length)) : 1)
    }

    mutating func step(seconds: Double) -> PointerDelta? {
        guard seconds.isFinite, seconds > 0, seconds <= 0.1,
              velocity.dx.isFinite, velocity.dy.isFinite, elapsed < 4,
              hypot(velocity.dx, velocity.dy) >= 4 else { return nil }
        elapsed += seconds
        let attenuation = exp(-decay * seconds)
        let delta = PointerDelta(dx: velocity.dx * (1 - attenuation) / decay,
                                 dy: velocity.dy * (1 - attenuation) / decay)
        velocity = PointerDelta(dx: velocity.dx * attenuation, dy: velocity.dy * attenuation)
        return delta
    }
}
