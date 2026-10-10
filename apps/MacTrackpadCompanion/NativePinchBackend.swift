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
    @Published private(set) var comparing = false
    @Published private(set) var comparisonStatus = ""
    private var comparisonMonitor: Any?
    private var comparisonTap: CFMachPort?
    private var comparisonSource: CFRunLoopSource?
    private var comparisonTimeout: Task<Void, Never>?
    private var comparisonCounts: [String: Int] = [:]
    private var comparisonSamples: [String] = []
    private var comparisonStarted = Date()

    var comparisonReport: String {
        let counts = comparisonCounts.keys.sorted().map { "\($0): \(comparisonCounts[$0]!)" }.joined(separator: ", ")
        return "Pinch comparison (gesture/scroll metadata only)\n\(comparisonStatus)\n\(counts)\n" + comparisonSamples.joined(separator: "\n")
    }

    /// User-started, bounded observation; never reads keys, document contents or clipboard data.
    func startComparison() {
        stopComparison()
        comparisonCounts.removeAll()
        comparisonSamples.removeAll()
        comparisonStarted = Date()
        // AppKit's global monitor omitted native magnify events in the first
        // physical report. Observe only gesture/scroll Quartz types, listen-only.
        let mask = (CGEventMask(1) << 22) | (CGEventMask(1) << 29) | (CGEventMask(1) << 30)
        comparisonTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let backend = Unmanaged<NativePinchBackend>.fromOpaque(context).takeUnretainedValue()
                // The source is installed exclusively on the main run loop.
                MainActor.assumeIsolated {
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let tap = backend.comparisonTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    } else if event.getIntegerValueField(.eventSourceUserData) != NativeMagnifyEvents.comparisonTag,
                              let cocoa = NSEvent(cgEvent: event) {
                        backend.recordComparison(cocoa, origin: "Quartz-observed")
                    }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        var method = "Quartz gesture/scroll observer"
        if let comparisonTap,
           let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, comparisonTap, 0) {
            comparisonSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: comparisonTap, enable: true)
        } else {
            if let comparisonTap { CFMachPortInvalidate(comparisonTap) }
            comparisonTap = nil
            method = "Limited pinch observer"
            comparisonMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.magnify, .scrollWheel, .beginGesture, .endGesture]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != NativeMagnifyEvents.comparisonTag else { return }
                    self?.recordComparison(event, origin: "AppKit-observed")
                }
            }
            guard comparisonMonitor != nil else {
                comparisonStatus = "Comparison observer unavailable; no permission settings changed."
                return
            }
        }
        comparing = true
        comparisonStatus = "Recording for 30 seconds via \(method): MacBook pinch first, then iPad over the same content."
        comparisonTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.stopComparison()
        }
    }

    func stopComparison() {
        comparisonTimeout?.cancel()
        comparisonTimeout = nil
        if let comparisonTap { CGEvent.tapEnable(tap: comparisonTap, enable: false); CFMachPortInvalidate(comparisonTap) }
        if let comparisonSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), comparisonSource, .commonModes) }
        comparisonTap = nil; comparisonSource = nil
        if let comparisonMonitor { NSEvent.removeMonitor(comparisonMonitor) }
        comparisonMonitor = nil
        if comparing { comparisonStatus = "Comparison finished. Copy diagnostics to share the captured metadata." }
        comparing = false
    }

    private func recordComparison(_ event: NSEvent, origin: String) {
        guard comparing else { return }
        let kind = "\(origin)/\(event.type.rawValue)"
        comparisonCounts[kind, default: 0] += 1
        // Retain a few representative samples per kind, with a strict total bound.
        guard comparisonCounts[kind]! <= 12, comparisonSamples.count < 72 else { return }
        let cg = event.cgEvent
        let location = cg?.location ?? .zero
        let time = String(format: "%.3f", Date().timeIntervalSince(comparisonStarted))
        let magnitude = event.type == .magnify ? String(format: "%.5f", event.magnification) : "-"
        let wheel = event.type == .scrollWheel ? String(format: "%.3f,%.3f", event.scrollingDeltaX, event.scrollingDeltaY) : "-"
        let phase = event.type == .magnify || event.type == .scrollWheel || event.type.rawValue == 36 ? event.phase.rawValue : 0
        let momentum = event.type == .scrollWheel ? event.momentumPhase.rawValue : 0
        let byteCount = cg?.data.map { CFDataGetLength($0) } ?? 0
        let routed = cg.flatMap { NativeGestureWindowLocation.point(in: $0) }.map { "\($0.x),\($0.y)" } ?? "unavailable"
        let fieldSummary = [55, 110, 111, 117, 132, 133, 138].map { raw in
            "\(String(raw, radix: 16))=\(CGEventField(rawValue: UInt32(raw)).map { cg?.getIntegerValueField($0) ?? 0 } ?? 0)"
        }.joined(separator: ",")
        comparisonSamples.append("t=\(time) \(kind) phase=\(phase) momentum=\(momentum) flags=\(event.modifierFlags.rawValue) window=\(event.windowNumber) cgLocation=\(location.x),\(location.y) windowLocation=\(event.locationInWindow.x),\(event.locationInWindow.y) encodedWindowLocation=\(routed) magnify=\(magnitude) wheel=\(wheel) bytes=\(byteCount) \(fieldSummary)")
    }

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
        if let cocoa = NSEvent(cgEvent: event) { recordComparison(cocoa, origin: "iPad-sent") }
        postEvent(event)
        if let cocoa = NSEvent(cgEvent: companion) { recordComparison(cocoa, origin: "iPad-sent") }
        postEvent(companion)
        nativeStarted = phase == .began || phase == .changed
        active = phase == .began || phase == .changed
        status = active ? (targetWindow == nil ? "Zooming" : "Zooming") : "Pinch ended"
        if !active { targetWindow = nil }
    }

    func cancel() {
        guard active else { return }
        if nativeStarted, postingAccess(),
           let event = NativeMagnifyEvents.make(amount: 0, phase: .cancelled, location: anchor, window: targetWindow),
           let companion = NativeMagnifyEvents.translation(phase: .cancelled, location: anchor, window: targetWindow) {
            if let cocoa = NSEvent(cgEvent: event) { recordComparison(cocoa, origin: "iPad-sent") }
            postEvent(event)
            if let cocoa = NSEvent(cgEvent: companion) { recordComparison(cocoa, origin: "iPad-sent") }
            postEvent(companion)
        }
        active = false
        nativeStarted = false
        targetWindow = nil
        status = "Pinch cancelled"
    }
}
