import SwiftUI
import UIKit

struct TrackpadSurface: UIViewRepresentable {
    var options: GestureOptions
    var releaseGeneration: UInt64 = 0
    var onInput: (InputCommand) -> Void
    var onHoldStatus: (String) -> Void = { _ in }

    func makeUIView(context: Context) -> TouchSurfaceView {
        let view = TouchSurfaceView()
        view.isMultipleTouchEnabled = true
        view.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.15, alpha: 1)
                : UIColor.secondarySystemBackground.withAlphaComponent(0.7)
        }
        view.layer.cornerRadius = 24
        view.onInput = onInput
        view.onHoldStatus = onHoldStatus
        view.options = options
        view.releaseGeneration = releaseGeneration
        return view
    }

    func updateUIView(_ view: TouchSurfaceView, context: Context) {
        view.onInput = onInput
        view.onHoldStatus = onHoldStatus
        if view.releaseGeneration != releaseGeneration {
            view.reset()
            view.releaseGeneration = releaseGeneration
        }
        if view.options != options { view.reset(); view.options = options }
    }
    static func dismantleUIView(_ view: TouchSurfaceView, coordinator: ()) { view.reset() }
}

final class TouchSurfaceView: UIView {
    var onInput: ((InputCommand) -> Void)?
    var onHoldStatus: ((String) -> Void)?
    var releaseGeneration: UInt64 = 0
    var options = GestureOptions() {
        didSet { engine.options = options }
    }
    private var contacts: [ObjectIdentifier: (id: Int, touch: UITouch)] = [:]
    private var nextID = 0
    private var engine = TrackpadGestureEngine()
    private var holdTask: Task<Void, Never>?
    private var scheduledHoldDeadline: Double?
    private var lastSize = CGSize.zero
    private var lastSampleTime: Double?

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize { reset(); lastSize = bounds.size }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch.type == .direct {
            nextID += 1
            contacts[ObjectIdentifier(touch)] = (nextID, touch)
        }
        sample()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { sample() }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        sample()
        for touch in touches { contacts.removeValue(forKey: ObjectIdentifier(touch)) }
        sample()
        if contacts.isEmpty { holdTask?.cancel(); holdTask = nil }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { reset() }

    private func sample() {
        let dimension = min(bounds.width, bounds.height)
        guard dimension > 0 else { return }
        var points: [Int: TouchPoint] = [:]
        for contact in contacts.values {
            let point = contact.touch.location(in: self)
            points[contact.id] = TouchPoint(x: Double(point.x / dimension * 1000), y: Double(point.y / dimension * 1000))
        }
        let now = ProcessInfo.processInfo.systemUptime
        let interval = lastSampleTime.map { (now - $0) * 1000 }
        lastSampleTime = now
        for var command in engine.update(points, at: now) {
            if command.kind == .scroll || command.kind == .pageSwipe || command.kind == .missionControl {
                command.sampleTimestampMilliseconds = UInt64(now * 1000)
                if command.phase == .began || command.phase == .changed,
                   let interval, interval > 0, interval <= 250 {
                    command.sampleIntervalMilliseconds = interval
                }
            }
            onInput?(command)
        }
        scheduleHold()
    }

    private func scheduleHold() {
        let deadline = engine.holdDeadline
        onHoldStatus?(deadline != nil ? "Hold still to drag…" :
            (options.holdToDrag ? "Slide to move · tap to click" : "Hold to drag is off · enable it in Settings"))
        guard deadline != scheduledHoldDeadline else { return }
        holdTask?.cancel()
        holdTask = nil
        scheduledHoldDeadline = deadline
        guard let deadline else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime) + 0.001
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.scheduledHoldDeadline = nil
            self.sample()
        }
    }

    func reset() {
        holdTask?.cancel(); holdTask = nil
        scheduledHoldDeadline = nil
        lastSampleTime = nil
        contacts.removeAll()
        for command in engine.cancel() { onInput?(command) }
        onHoldStatus?("Slide to move · tap to click")
    }
}
