import AppKit
import ApplicationServices
import Combine

@MainActor
final class NativeNavigationBackend: ObservableObject {
    let pagesAvailable = NativeNavigationEvents.pagesAvailable
    let missionControlAvailable = NativeNavigationEvents.missionControlAvailable
    let desktopAvailable = DesktopAction.available
    // Navigation starts enabled each launch; the switch pauses it for this session.
    @Published var enabled = true {
        didSet { if !enabled { cancel() } }
    }
    @Published private(set) var status = "Navigation ready."
    private(set) var active: InputKind?
    private var anchor = CGPoint.zero
    private var progress = 0.0
    private var previousTime = 0.0
    private var velocity = 0.0
    private var dockStarted = false
    private var closing = false
    private let postEvent: (CGEvent, CGEventTapLocation) -> Void
    private let cursorPosition: () -> CGPoint?
    private let missionControlState: () -> Bool?
    private let postingAccess: () -> Bool
    private let toggleDesktop: () -> Bool

    init(postEvent: @escaping (CGEvent, CGEventTapLocation) -> Void = { $0.post(tap: $1) },
         cursorPosition: @escaping () -> CGPoint? = { CGEvent(source: nil)?.location },
         missionControlState: @escaping () -> Bool? = { NativeNavigationBackend.missionControlVisible() },
         postingAccess: @escaping () -> Bool = { CGPreflightPostEventAccess() },
         toggleDesktop: @escaping () -> Bool = { DesktopAction.toggle() }) {
        self.postEvent = postEvent
        self.cursorPosition = cursorPosition
        self.missionControlState = missionControlState
        self.postingAccess = postingAccess
        self.toggleDesktop = toggleDesktop
    }

    /// Read-only Dock metadata, as used by Hammerspoon's Mission Control group.
    /// Distinguishes closing Mission Control from the excluded App Exposé gesture.
    static func missionControlVisible() -> Bool? {
        guard let dock = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        for child in children {
            var identifier: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXIdentifierAttribute as CFString, &identifier) == .success,
               identifier as? String == "mc" { return true }
        }
        return false
    }

    func perform(_ command: InputCommand) {
        guard command.valid, enabled else { cancel(); return }
        if command.kind == .showDesktop {
            cancel()
            status = toggleDesktop() ? "Show Desktop toggle requested." : "Show Desktop unavailable."
            return
        }
        guard command.kind == .pageSwipe || command.kind == .missionControl,
              command.kind == .pageSwipe ? pagesAvailable : missionControlAvailable else { return }
        let phase = command.phase!
        if phase == .began {
            cancel()
            guard let point = cursorPosition() else { return }
            anchor = point
            active = command.kind
            progress = 0; velocity = 0
            previousTime = ProcessInfo.processInfo.systemUptime
            dockStarted = false
            let state = missionControlState()
            closing = state == true
            if state == nil { status = "Mission Control visibility unavailable; closing cannot be confirmed." }
            return
        }
        guard active == command.kind else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if phase == .changed {
            let next = command.progress!
            let interval = command.sampleIntervalMilliseconds.map { $0 / 1000 } ?? (now - previousTime)
            velocity = interval > 0 && interval < 0.1 ? max(-30, min(30, (next - progress) / interval)) : 0
            previousTime = now
            progress = next
            if command.kind == .missionControl {
                // On the ordinary desktop, downward movement must not open App Exposé.
                if !dockStarted && ((closing && progress >= 0) || (!closing && progress <= 0)) {
                    status = closing ? "Swipe down to close Mission Control." : "Downward swipe ignored: Mission Control not detected."
                    return
                }
                if !dockStarted {
                    guard postDock(phase: .began) else { cancel(); return }
                    dockStarted = true
                } else if !postDock(phase: .changed) { cancel(); return }
                status = closing ? "Mission Control closing progress sent." : "Mission Control opening progress sent."
            }
            return
        }
        if command.kind == .pageSwipe {
            if phase == .ended, abs(command.progress!) >= 0.25,
               let event = NativeNavigationEvents.pageSwipe(progress: command.progress!, location: anchor) {
                postEvent(event, .cghidEventTap)
                status = "Page swipe sent to the app under the pointer."
            } else { status = "Page swipe cancelled." }
        } else if dockStarted {
            progress = command.progress!
            // A retreat near the origin cancels. Other releases leave the native Dock
            // to settle using signed progress and velocity; no discrete toggle fallback.
            let terminal: ScrollPhase = phase == .cancelled || abs(progress) < 0.1 || (closing ? progress >= 0 : progress <= 0) ? .cancelled : .ended
            if now - previousTime > 0.1 { velocity = 0 }
            _ = postDock(phase: terminal)
            status = terminal == .cancelled ? "Mission Control gesture cancelled." : "Mission Control gesture released."
        }
        active = nil; dockStarted = false
    }

    private func postDock(phase: ScrollPhase) -> Bool {
        guard let events = NativeNavigationEvents.dock(progress: closing ? min(0, progress) : max(0, progress), phase: phase, velocity: velocity, location: anchor) else { return false }
        for event in events { postEvent(event, .cgSessionEventTap) }
        return true
    }

    func cancel() {
        if dockStarted, postingAccess() { _ = postDock(phase: .cancelled) }
        active = nil; dockStarted = false
        progress = 0; velocity = 0
    }
}
