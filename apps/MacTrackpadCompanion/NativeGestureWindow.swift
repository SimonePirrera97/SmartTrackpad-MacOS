import AppKit
import ApplicationServices
import Darwin

/// Apple-only routing context; never crosses the portable wire contract.
struct NativeGestureWindow: Equatable {
    let number: UInt32
    let process: pid_t
    let bounds: CGRect // Quartz desktop coordinates, including negative-origin displays.

    func localPoint(for screenPoint: CGPoint) -> CGPoint {
        CGPoint(x: screenPoint.x - bounds.minX, y: bounds.maxY - screenPoint.y)
    }

    @MainActor
    static func activeWindow(at point: CGPoint) -> Self? {
        guard NativeGestureWindowLocation.available, let app = NSWorkspace.shared.frontmostApplication,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return selectWindow(from: windows, for: app.processIdentifier, at: point)
    }

    static func selectWindow(from windows: [[String: Any]], for process: pid_t, at point: CGPoint) -> Self? {
        // Window list is front-to-back. Do not route through an overlapping window
        // or assume the pointer is over the primary display's active window.
        for window in windows {
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let values = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: values), bounds.contains(point),
                  let pid = window[kCGWindowOwnerPID as String] as? NSNumber,
                  let number = window[kCGWindowNumber as String] as? NSNumber else { continue }
            guard pid.int32Value == process else { return nil }
            guard number.uint32Value > 0, pid.int32Value > 0 else { return nil }
            return Self(number: number.uint32Value, process: pid.int32Value, bounds: bounds)
        }
        return nil
    }
}

/// Private SPI declared in WebKit Tools/TestRunnerShared/spi/CoreGraphicsTestSPI.h.
/// Loaded without hard linkage; no event posting or system settings changes here.
@MainActor
enum NativeGestureWindowLocation {
    private typealias SetLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private typealias GetLocation = @convention(c) (CGEvent) -> CGPoint
    private static let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
    private static var setter: SetLocation? {
        guard let handle, let symbol = dlsym(handle, "CGEventSetWindowLocation") else { return nil }
        return unsafeBitCast(symbol, to: SetLocation.self)
    }
    private static var getter: GetLocation? {
        guard let handle, let symbol = dlsym(handle, "CGEventGetWindowLocation") else { return nil }
        return unsafeBitCast(symbol, to: GetLocation.self)
    }

    static var available: Bool { setter != nil && getter != nil }

    static func apply(_ window: NativeGestureWindow, to event: CGEvent) -> Bool {
        guard window.number > 0, window.process > 0,
              window.bounds.width > 0, window.bounds.height > 0,
              let setter, let getter else { return false }
        let local = window.localPoint(for: event.location)
        guard local.x.isFinite, local.y.isFinite else { return false }
        let original = event.location
        event.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(window.number))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.number))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.number))
        setter(event, local)
        let decoded = getter(event)
        return event.location == original && NSEvent(cgEvent: event)?.windowNumber == Int(window.number)
            && abs(decoded.x - local.x) < 0.001 && abs(decoded.y - local.y) < 0.001
    }

    static func point(in event: CGEvent) -> CGPoint? { getter?(event) }
}
