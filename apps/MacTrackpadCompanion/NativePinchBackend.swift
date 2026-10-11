import AppKit
import ApplicationServices
import Combine

@MainActor
final class NativePinchBackend: ObservableObject {
    let available = NativeMagnifyEvents.available()
    @Published var enabled = UserDefaults.standard.object(forKey: "experimentalPinchEnabled") as? Bool ?? true {
        didSet { if persistSettings { UserDefaults.standard.set(enabled, forKey: "experimentalPinchEnabled") }; if !enabled { cancel() } }
    }
    @Published private(set) var status = "Pinch ready."
    private(set) var active = false
    private var anchor = CGPoint.zero
    private var targetWindow: NativeGestureWindow?
    private var nativeStarted = false
    private let persistSettings: Bool
    private let postEvent: (CGEvent) -> Void
    private let cursorPosition: () -> CGPoint?
    private let windowResolver: (CGPoint) -> NativeGestureWindow?
    private let frontmostProcess: () -> pid_t?
    private let postingAccess: () -> Bool

    init(persistSettings: Bool = true,
         postEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
         cursorPosition: @escaping () -> CGPoint? = { CGEvent(source: nil)?.location },
         windowResolver: @escaping (CGPoint) -> NativeGestureWindow? = { NativeGestureWindow.activeWindow(at: $0) },
         frontmostProcess: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
         postingAccess: @escaping () -> Bool = { CGPreflightPostEventAccess() }) {
        self.persistSettings = persistSettings
        self.postEvent = postEvent
        self.cursorPosition = cursorPosition
        self.windowResolver = windowResolver
        self.frontmostProcess = frontmostProcess
        self.postingAccess = postingAccess
        if !persistSettings { enabled = true }
        if !available { status = "Pinch to zoom is unavailable on this Mac." }
    }

    func perform(_ command: InputCommand) {
        guard command.kind == .magnify, command.valid, available, enabled else { cancel(); return }
        let phase = command.phase!
        if phase == .began {
            cancel()
            guard let position = cursorPosition() else { status = "Pinch cursor location unavailable"; return }
            anchor = position
            targetWindow = windowResolver(position)
            active = true
            nativeStarted = false
        } else if !active { return }
        if let targetWindow, frontmostProcess() != targetWindow.process {
            cancel()
            status = "Pinch cancelled: target app changed."
            return
        }
        // The physical capture begins with a real scale delta. A zero begin can
        // enter a receiving app's default zoom before content handles the change.
        // Keep the portable zero begin as target acquisition only; preserve the
        // first nonzero delta in the native began event.
        if !nativeStarted {
            if phase == .ended || phase == .cancelled {
                active = false
                targetWindow = nil
                status = "Pinch ended without a scale change"
                return
            }
            if command.magnification == 0 { return }
        }
        let nativePhase: ScrollPhase = nativeStarted ? phase : .began
        guard let event = NativeMagnifyEvents.make(amount: command.magnification!, phase: nativePhase, location: anchor, window: targetWindow),
              let companion = NativeMagnifyEvents.translation(phase: nativePhase, location: anchor, window: targetWindow) else {
            cancel()
            status = "Pinch to zoom is unavailable."
            return
        }
        postEvent(event)
        postEvent(companion)
        nativeStarted = phase == .began || phase == .changed
        active = phase == .began || phase == .changed
        status = active ? "Zooming" : "Pinch ended"
        if !active { targetWindow = nil }
    }

    func cancel() {
        guard active else { return }
        if nativeStarted, postingAccess(),
           let event = NativeMagnifyEvents.make(amount: 0, phase: .cancelled, location: anchor, window: targetWindow),
           let companion = NativeMagnifyEvents.translation(phase: .cancelled, location: anchor, window: targetWindow) {
            postEvent(event)
            postEvent(companion)
        }
        active = false
        nativeStarted = false
        targetWindow = nil
        status = "Pinch cancelled"
    }
}
