import Foundation

enum MouseButton: String, Codable, Sendable { case left, right }
enum StandardAction: String, Codable, Sendable, CaseIterable {
    case copy, cut, paste, undo, redo, missionControl
}
enum InputKind: String, Codable, Sendable { case move, click, button, scroll, releaseAll, stopMomentum, action, magnify, pageSwipe, missionControl, showDesktop, appControl }
extension InputKind {
    var capability: String {
        switch self {
        case .move: "pointer.move"
        case .click: "mouse.click"
        case .button: "mouse.button"
        case .scroll: "scroll.pixel"
        case .releaseAll: "input.releaseAll"
        case .stopMomentum: "scroll.stopMomentum"
        case .action: "action.standard"
        case .appControl: "action.appControls.v2"
        case .magnify: "gesture.magnify.experimental"
        case .pageSwipe: "gesture.pages.experimental"
        case .missionControl: "gesture.missionControl.experimental"
        case .showDesktop: "action.showDesktop.experimental"
        }
    }
    static let supportedCapabilities = ["pointer.move", "mouse.click", "mouse.button", "scroll.pixel", "input.releaseAll", "scroll.stopMomentum", "action.standard", "scroll.pixel.highRange", "gesture.magnify.experimental", "gesture.pages.experimental", "gesture.missionControl.experimental", "action.showDesktop.experimental", "settings.trackpadPreferences", "action.appControls.v2", "input.binary.v1", "input.ack.v1"]
}
enum ScrollPhase: String, Codable, Sendable { case began, changed, ended, cancelled }

struct InputCommand: Codable, Sendable, Equatable {
    let kind: InputKind
    var delta: PointerDelta? = nil
    var button: MouseButton? = nil
    var pressed: Bool? = nil
    var count: Int? = nil
    var phase: ScrollPhase? = nil
    var action: StandardAction? = nil
    var sampleTimestampMilliseconds: UInt64? = nil
    var sampleIntervalMilliseconds: Double? = nil
    var magnification: Double? = nil
    var progress: Double? = nil
    var appControl: AppControlRequest? = nil

    var endsGesture: Bool {
        [.scroll, .magnify, .pageSwipe, .missionControl].contains(kind) && (phase == .ended || phase == .cancelled)
    }

    /// Delivered even when stale, so a late packet can never leave input held.
    var releases: Bool {
        kind == .releaseAll || (kind == .button && pressed == false) || endsGesture
    }

    var valid: Bool {
        guard kind == .appControl || appControl == nil else { return false }
        guard kind == .action || action == nil else { return false }
        guard kind == .pageSwipe || kind == .missionControl || progress == nil else { return false }
        guard kind == .magnify || magnification == nil else { return false }
        guard kind == .scroll || kind == .pageSwipe || kind == .missionControl || (sampleTimestampMilliseconds == nil && sampleIntervalMilliseconds == nil) else { return false }
        if let interval = sampleIntervalMilliseconds {
            guard interval.isFinite, interval > 0, interval <= 250,
                  phase == .began || phase == .changed else { return false }
        }
        switch kind {
        case .move:
            return delta?.valid == true && button == nil && pressed == nil && count == nil && phase == nil
        case .click:
            return button != nil && (1...3).contains(count ?? 0) && delta == nil && pressed == nil && phase == nil
        case .button:
            return button != nil && pressed != nil && delta == nil && count == nil && phase == nil
        case .scroll:
            return delta?.scrollValid == true && phase != nil && button == nil && pressed == nil && count == nil
                && (!(phase == .ended || phase == .cancelled) || (delta?.dx == 0 && delta?.dy == 0))
        case .releaseAll, .stopMomentum, .showDesktop:
            return delta == nil && button == nil && pressed == nil && count == nil && phase == nil
        case .appControl:
            return appControl?.valid == true && delta == nil && button == nil && pressed == nil && count == nil && phase == nil
        case .action:
            return action != nil && delta == nil && button == nil && pressed == nil && count == nil && phase == nil
        case .pageSwipe, .missionControl:
            guard let progress, progress.isFinite, abs(progress) <= 3, phase != nil else { return false }
            return delta == nil && button == nil && pressed == nil && count == nil
                && (phase != .began || progress == 0)
        case .magnify:
            guard let magnification, magnification.isFinite, abs(magnification) <= 0.5, phase != nil else { return false }
            return delta == nil && button == nil && pressed == nil && count == nil
                && (phase == .changed || magnification == 0)
        }
    }

    static func move(_ delta: PointerDelta) -> Self { Self(kind: .move, delta: delta) }
    static func click(_ button: MouseButton, count: Int = 1) -> Self { Self(kind: .click, button: button, count: count) }
    static func button(_ button: MouseButton, pressed: Bool) -> Self { Self(kind: .button, button: button, pressed: pressed) }
    static func scroll(_ delta: PointerDelta, phase: ScrollPhase) -> Self { Self(kind: .scroll, delta: delta, phase: phase) }
    static let releaseAll = Self(kind: .releaseAll)
    static let showDesktop = Self(kind: .showDesktop)
    static func navigation(_ kind: InputKind, progress: Double, phase: ScrollPhase) -> Self {
        Self(kind: kind, phase: phase, progress: progress)
    }
    static let stopMomentum = Self(kind: .stopMomentum)
    static func app(_ request: AppControlRequest) -> Self { Self(kind: .appControl, appControl: request) }
    static func action(_ action: StandardAction) -> Self { Self(kind: .action, action: action) }
    static func magnify(_ amount: Double, phase: ScrollPhase) -> Self {
        Self(kind: .magnify, phase: phase, magnification: amount)
    }
}
