import AppKit
import ApplicationServices
import Dispatch

/// User-approved experiment, isolated from the public Quartz mouse backend.
/// Undocumented field representation researched from Hammerspoon TouchEvents.c/.h:
/// https://github.com/Hammerspoon/hammerspoon/tree/master/extensions/eventtap
@MainActor
enum NativeMagnifyEvents {
    static let comparisonTag: Int64 = 0x53545050494E4348
    static func make(amount: Double, phase: ScrollPhase, location: CGPoint, window: NativeGestureWindow? = nil) -> CGEvent? {
        guard InputCommand.magnify(amount, phase: phase == .began ? .changed : phase).valid,
              let event = CGEvent(source: nil), let type = CGEventType(rawValue: 29),
              let subtype = CGEventField(rawValue: 0x6E), let magnitude = CGEventField(rawValue: 0x71),
              let gesturePhase = CGEventField(rawValue: 0x84) else { return nil }
        let encoded: Int64
        switch phase {
        case .began: encoded = 1
        case .changed: encoded = 2
        case .ended: encoded = 4
        case .cancelled: encoded = 8
        }
        event.type = type
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: comparisonTag)
        event.location = location
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        event.setIntegerValueField(subtype, value: 8)
        event.setDoubleValueField(magnitude, value: amount)
        event.setIntegerValueField(gesturePhase, value: encoded)
        // Refuse unsupported encodings instead of advertising or posting them.
        let expected: NSEvent.Phase
        switch phase {
        case .began: expected = .began
        case .changed: expected = .changed
        case .ended: expected = .ended
        case .cancelled: expected = .cancelled
        }
        guard let cocoa = NSEvent(cgEvent: event), cocoa.type == .magnify,
              cocoa.phase == expected, abs(cocoa.magnification - amount) < 0.00001 else { return nil }
        if let window, !NativeGestureWindowLocation.apply(window, to: event) { return nil }
        return event
    }

    /// The physical comparison contains subtype 4 / AppKit type 36 beside pinch.
    /// Supply its lifecycle with no translation: pinch must not move the pointer
    /// or pan content. Whether Safari needs this companion remains experimental.
    static func translation(phase: ScrollPhase, location: CGPoint, window: NativeGestureWindow? = nil) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        let encoded: Int64
        let expected: NSEvent.Phase
        switch phase {
        case .began: encoded = 1; expected = .began
        case .changed: encoded = 2; expected = .changed
        case .ended: encoded = 4; expected = .ended
        case .cancelled: encoded = 8; expected = .cancelled
        }
        event.type = CGEventType(rawValue: 29)!
        event.flags = []
        event.location = location
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        event.setIntegerValueField(.eventSourceUserData, value: comparisonTag)
        event.setIntegerValueField(CGEventField(rawValue: 110)!, value: 4)
        event.setIntegerValueField(CGEventField(rawValue: 132)!, value: encoded)
        guard let cocoa = NSEvent(cgEvent: event), cocoa.type.rawValue == 36,
              cocoa.phase == expected, cocoa.deltaX == 0, cocoa.deltaY == 0 else { return nil }
        if let window, !NativeGestureWindowLocation.apply(window, to: event) { return nil }
        return event
    }

    static func available() -> Bool {
        [ScrollPhase.began, .changed, .ended, .cancelled].allSatisfy {
            make(amount: $0 == .changed || $0 == .began ? 0.1 : 0, phase: $0, location: .zero) != nil
                && translation(phase: $0, location: .zero) != nil
        }
    }
}
