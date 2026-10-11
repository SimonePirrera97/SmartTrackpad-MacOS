import AppKit
@preconcurrency import ApplicationServices
import Combine
import QuartzCore

@MainActor
protocol MacPointerBackend: AnyObject {
    func perform(_ command: InputCommand)
    func releaseAll()
}

@MainActor
final class QuartzPointerBackend: NSObject, ObservableObject, MacPointerBackend {
    @Published private(set) var permissionGranted = false
    @Published private(set) var inputStatus = "Enable Accessibility to control the pointer"
    @Published private(set) var dragging = false
    @Published var enabled = UserDefaults.standard.object(forKey: "inputEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "inputEnabled"); if !enabled { releaseAll() } }
    }
    @Published var momentumEnabled = UserDefaults.standard.object(forKey: "momentumEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(momentumEnabled, forKey: "momentumEnabled"); if !momentumEnabled { stopMomentum() } }
    }
    @Published var momentumLength = UserDefaults.standard.object(forKey: "momentumLength") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(momentumLength, forKey: "momentumLength"); stopMomentum() }
    }
    private var state = InputState()
    private var scrollRemainder = PointerDelta(dx: 0, dy: 0)
    private var scrollVelocity = ScrollVelocity()
    private var momentumModel: ScrollMomentum?
    private var momentumLink: CADisplayLink?
    private var lastMomentumTime: Double = 0
    private var firstMomentumFrame = false
    private var momentumRunning = false
    private var lastKnownPosition: CGPoint?

    func refreshPermission() {
        permissionGranted = AXIsProcessTrusted() && CGPreflightPostEventAccess()
        if !permissionGranted { inputStatus = "Enable Accessibility to control the pointer" }
        else if inputStatus.hasPrefix("Enable") { inputStatus = "Input control ready" }
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestPostEventAccess()
        refreshPermission()
    }


    func perform(_ command: InputCommand) {
        guard command.valid else { return }
        if command.kind == .releaseAll { releaseAll(); return }
        if command.kind == .stopMomentum { stopMomentum(); return }
        refreshPermission()
        guard enabled, permissionGranted, state.apply(command) else { return }
        switch command.kind {
        case .move: postMove(command.delta!)
        case .click:
            stopMomentum()
            postButton(command.button!, pressed: true, clickCount: command.count!)
            postButton(command.button!, pressed: false, clickCount: command.count!)
            inputStatus = command.button == .right ? "Secondary click sent" : "Click sent"
        case .button:
            stopMomentum()
            postButton(command.button!, pressed: command.pressed!, clickCount: 1)
            dragging = !state.held.isEmpty
            inputStatus = dragging ? "Dragging" : "Input control ready"
        case .scroll:
            handleScroll(command)
        case .releaseAll, .stopMomentum, .action, .magnify, .pageSwipe, .missionControl, .showDesktop, .appControl: break
        }
    }

    private func postMove(_ delta: PointerDelta) {
        guard let position = CGEvent(source: nil)?.location else {
            inputStatus = "Cursor position unavailable"; return
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else { return }
        let bounds = displays.prefix(Int(count)).map { CGDisplayBounds($0) }
        let target = PointerGeometry.clamp(CGPoint(x: position.x + delta.dx, y: position.y + delta.dy), to: bounds)
        let type: CGEventType = state.held.contains(.left) ? .leftMouseDragged
            : state.held.contains(.right) ? .rightMouseDragged : .mouseMoved
        let button: CGMouseButton = state.held.contains(.left) || !state.held.contains(.right) ? .left : .right
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: target, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(target.x - position.x))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(target.y - position.y))
        event.post(tap: .cghidEventTap)
        lastKnownPosition = target
        inputStatus = state.held.isEmpty ? "Pointer events sent" : "Dragging"
    }

    private func postButton(_ button: MouseButton, pressed: Bool, clickCount: Int) {
        guard let position = CGEvent(source: nil)?.location ?? lastKnownPosition else { return }
        let type: CGEventType = button == .left ? (pressed ? .leftMouseDown : .leftMouseUp)
            : (pressed ? .rightMouseDown : .rightMouseUp)
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: position,
                                  mouseButton: button == .left ? .left : .right) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event.post(tap: .cghidEventTap)
        lastKnownPosition = position
    }

    private func handleScroll(_ command: InputCommand) {
        let delta = command.delta!
        let phase = command.phase!
        let now = ProcessInfo.processInfo.systemUptime
        let sampleTime = command.sampleTimestampMilliseconds.map { Double($0) / 1000 } ?? now
        if phase == .began {
            stopMomentum(); scrollRemainder = PointerDelta(dx: 0, dy: 0)
            scrollVelocity.reset()
        }
        if phase == .began || phase == .changed {
            scrollVelocity.sample(delta, at: sampleTime,
                                  interval: command.sampleIntervalMilliseconds.map { $0 / 1000 })
        }
        let phaseValue: Int64
        switch phase {
        case .began: phaseValue = Int64(CGScrollPhase.began.rawValue)
        case .changed: phaseValue = Int64(CGScrollPhase.changed.rawValue)
        case .ended: phaseValue = Int64(CGScrollPhase.ended.rawValue)
        case .cancelled: phaseValue = Int64(CGScrollPhase.cancelled.rawValue)
        }
        postScroll(delta, phase: phaseValue, momentum: 0)
        inputStatus = "Scroll events sent"
        if phase == .ended {
            if momentumEnabled { startMomentum(velocity: scrollVelocity.released(at: sampleTime)) }
            scrollVelocity.reset()
        } else if phase == .cancelled { stopMomentum(); scrollVelocity.reset() }
    }

    private func postScroll(_ delta: PointerDelta, phase: Int64, momentum: Int64) {
        let x = delta.dx + scrollRemainder.dx
        let y = delta.dy + scrollRemainder.dy
        let wheelX = Int32(x.rounded(.towardZero))
        let wheelY = Int32(y.rounded(.towardZero))
        scrollRemainder = PointerDelta(dx: x - Double(wheelX), dy: y - Double(wheelY))
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: wheelY, wheel2: wheelX, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        event.post(tap: .cghidEventTap)
    }

    private func startMomentum(velocity: PointerDelta) {
        // Preserve fractional scroll accumulation at the finger-to-coast handoff.
        let remainder = scrollRemainder
        stopMomentum()
        scrollRemainder = remainder
        guard hypot(velocity.dx, velocity.dy) >= 40 else { return }
        let position = CGEvent(source: nil)?.location
        let screen = NSScreen.screens.first { screen in
            guard let position, let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayBounds(number.uint32Value).contains(position)
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        momentumModel = ScrollMomentum(velocity: velocity, length: momentumLength)
        momentumRunning = true
        firstMomentumFrame = true
        lastMomentumTime = ProcessInfo.processInfo.systemUptime
        let link = screen.displayLink(target: self, selector: #selector(momentumTick(_:)))
        let maximum = screen.maximumFramesPerSecond > 0 ? Float(screen.maximumFramesPerSecond) : 60
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        momentumLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func momentumTick(_ link: CADisplayLink) {
        guard enabled, momentumEnabled else { stopMomentum(); return }
        refreshPermission()
        guard permissionGranted else { stopMomentum(); return }
        let now = ProcessInfo.processInfo.systemUptime
        guard var model = momentumModel,
              let delta = model.step(seconds: now - lastMomentumTime) else { stopMomentum(); return }
        momentumModel = model
        lastMomentumTime = now
        postScroll(delta, phase: 0, momentum: firstMomentumFrame ? 1 : 2)
        firstMomentumFrame = false
    }

    private func stopMomentum() {
        momentumLink?.invalidate(); momentumLink = nil
        momentumModel = nil
        if momentumRunning && CGPreflightPostEventAccess() {
            postScroll(PointerDelta(dx: 0, dy: 0), phase: 0, momentum: 3)
        }
        momentumRunning = false
        scrollRemainder = PointerDelta(dx: 0, dy: 0)
    }

    func releaseAll() {
        stopMomentum()
        let wasScrolling = state.scrolling
        let buttons = state.release()
        if CGPreflightPostEventAccess() {
            for button in buttons { postButton(button, pressed: false, clickCount: 1) }
            if wasScrolling {
                postScroll(PointerDelta(dx: 0, dy: 0), phase: Int64(CGScrollPhase.cancelled.rawValue), momentum: 0)
            }
        }
        dragging = false
        scrollVelocity.reset()
        inputStatus = "Input released"
    }
}
