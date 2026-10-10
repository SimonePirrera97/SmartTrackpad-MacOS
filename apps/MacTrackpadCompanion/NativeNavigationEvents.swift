import AppKit
import ApplicationServices
import Dispatch

/// Isolated experimental Apple event representations; no system preference changes.
/// Field references: Hammerspoon TouchEvents and oomol-lab/dockswipe.
enum NativeNavigationEvents {
    static func pageSwipe(progress: Double, location: CGPoint) -> CGEvent? {
        guard progress.isFinite, abs(progress) <= 3, abs(progress) >= 0.25,
              let event = CGEvent(source: nil) else { return nil }
        event.type = CGEventType(rawValue: 29)!
        event.location = location
        event.flags = CGEventFlags(rawValue: 256)
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        event.setIntegerValueField(CGEventField(rawValue: 110)!, value: 16)
        event.setIntegerValueField(CGEventField(rawValue: 115)!, value: progress > 0 ? 4 : 8)
        guard let cocoa = NSEvent(cgEvent: event), cocoa.type == .swipe,
              cocoa.deltaX != 0, (cocoa.deltaX > 0) == (progress > 0) else { return nil }
        return event
    }

    static func dock(progress: Double, phase: ScrollPhase, velocity: Double = 0, location: CGPoint) -> [CGEvent]? {
        guard progress.isFinite, abs(progress) <= 3, velocity.isFinite, abs(velocity) <= 30,
              let control = CGEvent(source: nil), let marker = CGEvent(source: nil) else { return nil }
        let encoded: Double
        switch phase {
        case .began: encoded = 1
        case .changed: encoded = 2
        case .ended: encoded = 4
        case .cancelled: encoded = 8
        }
        control.type = CGEventType(rawValue: 30)!
        marker.type = CGEventType(rawValue: 29)!
        let axis = Double(Float(bitPattern: 2))
        for (raw, value) in [(110, 23.0), (123, 2.0), (165, 2.0), (119, axis), (139, axis),
                             (124, progress), (132, encoded), (134, encoded), (41, 33231.0)] {
            control.setDoubleValueField(CGEventField(rawValue: UInt32(raw))!, value: value)
        }
        control.setIntegerValueField(CGEventField(rawValue: 135)!, value: Int64(Float(progress).bitPattern))
        control.setIntegerValueField(CGEventField(rawValue: 136)!, value: 0)
        if phase == .ended || phase == .cancelled {
            control.setDoubleValueField(CGEventField(rawValue: 129)!, value: velocity)
            control.setDoubleValueField(CGEventField(rawValue: 130)!, value: velocity)
        }
        marker.setDoubleValueField(CGEventField(rawValue: 41)!, value: 33231)
        for event in [control, marker] {
            event.location = location
            event.timestamp = DispatchTime.now().uptimeNanoseconds
        }
        guard control.type.rawValue == 30,
              abs(control.getDoubleValueField(CGEventField(rawValue: 124)!) - progress) < 0.000001,
              control.getDoubleValueField(CGEventField(rawValue: 132)!) == encoded else { return nil }
        return [control, marker]
    }

    static var pagesAvailable: Bool {
        pageSwipe(progress: -0.5, location: .zero) != nil && pageSwipe(progress: 0.5, location: .zero) != nil
    }
    static var missionControlAvailable: Bool {
        [ScrollPhase.began, .changed, .ended, .cancelled].allSatisfy {
            dock(progress: 0.25, phase: $0, location: .zero) != nil
        }
    }
}
