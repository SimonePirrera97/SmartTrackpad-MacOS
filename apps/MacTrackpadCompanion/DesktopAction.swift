import Foundation
import ApplicationServices
import Darwin

/// Explicit Show Desktop button: toggles the OS action rather than simulating keys.
/// Dynamic lookup lets capability negotiation omit an unavailable private symbol.
/// Reference: LinearMouse Modules/DockKit/Sources/DockKit/DockKit.swift.
@MainActor
enum DesktopAction {
    private typealias Notify = @convention(c) (CFString, Int32) -> Int32
    private static let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    private static var notify: Notify? {
        guard let handle, let symbol = dlsym(handle, "CoreDockSendNotification") else { return nil }
        return unsafeBitCast(symbol, to: Notify.self)
    }
    static var available: Bool { notify != nil }
    static func toggle() -> Bool {
        guard let notify else { return false }
        return notify("com.apple.showdesktop.awake" as CFString, 0) == 0
    }
}
