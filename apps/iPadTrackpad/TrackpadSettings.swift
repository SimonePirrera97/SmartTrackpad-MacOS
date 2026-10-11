import Foundation
import Combine

final class TrackpadSettings: ObservableObject {
    @Published var sensitivity: Double { didSet { save() } }
    @Published var scrollSpeed: Double { didSet { save() } }
    @Published var naturalScroll: Bool { didSet { save() } }
    @Published var pageSwipes: Bool { didSet { if pageSwipes { threeFingerDrag = false }; save() } }
    @Published var pinchEnabled: Bool { didSet { save() } }
    @Published var tapToClick: Bool { didSet { save() } }
    @Published var twoFingerTap: Bool { didSet { save() } }
    @Published var holdToDrag: Bool { didSet { save() } }
    @Published var threeFingerDrag: Bool {
        didSet { if threeFingerDrag { threeFingerMissionControl = false; pageSwipes = false }; save() }
    }
    @Published var threeFingerMissionControl: Bool {
        didSet { if threeFingerMissionControl && threeFingerDrag { threeFingerDrag = false }; save() }
    }
    @Published var holdDuration: Double { didSet { save() } }
    @Published var tapDuration: Double { didSet { save() } }
    @Published var tapTolerance: Double { didSet { save() } }
    @Published var showSettings = false
    @Published var dragging = false
    @Published var holdStatus = "Slide to move · tap to click"
    @Published var releaseGeneration: UInt64 = 0

    init() {
        let saved = UserDefaults.standard.dictionary(forKey: "trackpadSettings") ?? [:]
        sensitivity = Self.number(saved["sensitivity"], default: 1, range: 0.25...3)
        scrollSpeed = Self.number(saved["scrollSpeed"], default: 1, range: 0.25...3)
        holdDuration = Self.number(saved["holdDuration"], default: 0.45, range: 0.3...0.9)
        tapDuration = Self.number(saved["tapDuration"], default: 0.28, range: 0.15...0.4)
        tapTolerance = Self.number(saved["tapTolerance"], default: 12, range: 4...25)
        naturalScroll = saved["naturalScroll"] as? Bool ?? true
        pinchEnabled = saved["pinchEnabled"] as? Bool ?? true
        tapToClick = saved["tapToClick"] as? Bool ?? true
        twoFingerTap = saved["twoFingerTap"] as? Bool ?? true
        holdToDrag = saved["holdToDrag"] as? Bool ?? true
        let savedThreeFingerDrag = saved["threeFingerDrag"] as? Bool ?? false
        threeFingerDrag = savedThreeFingerDrag
        pageSwipes = !savedThreeFingerDrag && (saved["pageSwipes"] as? Bool ?? true)
        threeFingerMissionControl = !savedThreeFingerDrag && (saved["threeFingerMissionControl"] as? Bool ?? true)
    }

    var options: GestureOptions {
        var options = GestureOptions()
        options.tapToClick = tapToClick
        options.twoFingerTap = twoFingerTap
        options.holdToDrag = holdToDrag
        options.threeFingerDrag = threeFingerDrag
        options.holdDuration = holdDuration
        options.tapDuration = tapDuration
        options.movementThreshold = tapTolerance
        return options
    }

    func applyMacPreferences(_ preferences: TrackpadPreferences) {
        guard preferences.valid else { return }
        if let value = preferences.tapToClick { tapToClick = value }
        if let value = preferences.twoFingerSecondaryClick { twoFingerTap = value }
        if let value = preferences.naturalScroll { naturalScroll = value }
        if let value = preferences.threeFingerDrag { threeFingerDrag = value }
        releaseGeneration &+= 1
        dragging = false
    }

    func emitScaled(_ command: InputCommand, output: (InputCommand) -> Void) {
        let factor = command.kind == .scroll ? scrollSpeed * (naturalScroll ? 1 : -1) : sensitivity
        MotionScaling.emit(command, factor: factor, output: output)
    }

    private func save() {
        UserDefaults.standard.set(["version": 1, "sensitivity": sensitivity, "scrollSpeed": scrollSpeed,
            "naturalScroll": naturalScroll, "tapToClick": tapToClick, "twoFingerTap": twoFingerTap,
            "pinchEnabled": pinchEnabled, "pageSwipes": pageSwipes,
            "holdToDrag": holdToDrag, "threeFingerDrag": threeFingerDrag, "holdDuration": holdDuration,
            "threeFingerMissionControl": threeFingerMissionControl,
            "tapDuration": tapDuration, "tapTolerance": tapTolerance], forKey: "trackpadSettings")
    }

    private static func number(_ value: Any?, default fallback: Double, range: ClosedRange<Double>) -> Double {
        guard let value = value as? Double, value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}
