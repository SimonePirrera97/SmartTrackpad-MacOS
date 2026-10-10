import Foundation

/// Pure state ledger; only our own pressed buttons are released by cleanup.
struct InputState {
    private(set) var held: Set<MouseButton> = []
    private(set) var scrolling = false

    mutating func apply(_ command: InputCommand) -> Bool {
        guard command.valid else { return false }
        switch command.kind {
        case .button:
            let button = command.button!
            if command.pressed! { return held.insert(button).inserted }
            return held.remove(button) != nil
        case .click, .action, .magnify, .pageSwipe, .missionControl, .showDesktop, .appControl: return held.isEmpty
        case .scroll:
            guard held.isEmpty else { return false }
            scrolling = command.phase == .began || command.phase == .changed
            return true
        case .releaseAll: return true
        case .move, .stopMomentum: return true
        }
    }

    mutating func release() -> [MouseButton] {
        let buttons = held.sorted { $0.rawValue < $1.rawValue }
        held.removeAll(); scrolling = false
        return buttons
    }
}
