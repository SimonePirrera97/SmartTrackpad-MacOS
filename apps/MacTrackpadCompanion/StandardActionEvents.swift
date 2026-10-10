import ApplicationServices
import Carbon.HIToolbox

/// Fixed editing shortcuts only. Building events does not post them or read the clipboard.
enum StandardActionEvents {
    static func shortcut(_ action: StandardAction) -> (key: CGKeyCode, flags: CGEventFlags)? {
        let key: CGKeyCode
        var flags: CGEventFlags = .maskCommand
        switch action {
        case .copy: key = CGKeyCode(kVK_ANSI_C)
        case .cut: key = CGKeyCode(kVK_ANSI_X)
        case .paste: key = CGKeyCode(kVK_ANSI_V)
        case .undo: key = CGKeyCode(kVK_ANSI_Z)
        case .redo: key = CGKeyCode(kVK_ANSI_Z); flags.insert(.maskShift)
        case .missionControl: return nil
        }
        return (key, flags)
    }

    static func make(_ action: StandardAction) -> [CGEvent]? {
        guard let shortcut = shortcut(action) else { return nil }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: shortcut.key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: shortcut.key, keyDown: false) else { return nil }
        down.flags = shortcut.flags
        up.flags = []
        return [down, up]
    }
}

/// Fixed user-selected app actions; no scripts or peer-defined key sequences.
extension StandardActionEvents {
    static func shortcut(_ action: AppControlAction) -> (key: CGKeyCode, flags: CGEventFlags) {
        switch action {
        case .save: (CGKeyCode(kVK_ANSI_S), .maskCommand)
        case .compile: (CGKeyCode(kVK_ANSI_B), [.maskCommand, .maskShift])
        case .delete: (CGKeyCode(kVK_Delete), [])
        case .deleteWord: (CGKeyCode(kVK_ANSI_W), .maskControl)
        case .enter: (CGKeyCode(kVK_Return), [])
        case .newTab: (CGKeyCode(kVK_ANSI_T), .maskCommand)
        case .closeTab: (CGKeyCode(kVK_ANSI_W), .maskCommand)
        case .playPause: (CGKeyCode(kVK_Space), [])
        case .previousTrack: (CGKeyCode(kVK_LeftArrow), .maskCommand)
        case .nextTrack: (CGKeyCode(kVK_RightArrow), .maskCommand)
        case .volumeDown: (CGKeyCode(kVK_DownArrow), .maskCommand)
        case .volumeUp: (CGKeyCode(kVK_UpArrow), .maskCommand)
        case .newFolder: (CGKeyCode(kVK_ANSI_N), [.maskCommand, .maskShift])
        case .trash: (CGKeyCode(kVK_Delete), .maskCommand)
        }
    }

    static func make(_ action: AppControlAction) -> [CGEvent]? {
        let shortcut = shortcut(action)
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: shortcut.key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: shortcut.key, keyDown: false) else { return nil }
        down.flags = shortcut.flags
        up.flags = []
        return [down, up]
    }
}
