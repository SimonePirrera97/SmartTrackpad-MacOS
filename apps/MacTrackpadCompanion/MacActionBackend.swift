import AppKit
import Combine

@MainActor
final class MacActionBackend: ObservableObject {
    @Published private(set) var status = "Editing buttons act on the focused Mac app."

    func perform(_ action: StandardAction) {
        if action == .missionControl {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.exposelauncher") else {
                status = "Mission Control app is unavailable on this Mac."
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
                let message = error.map { "Cannot open Mission Control: \($0.localizedDescription)" }
                    ?? "Mission Control opened (action, not an interactive trackpad gesture)."
                Task { @MainActor in self?.status = message }
            }
        } else if let events = StandardActionEvents.make(action) {
            // A synchronous down/up pair leaves no asynchronous held key to replay.
            for event in events { event.post(tap: .cghidEventTap) }
            status = "\(action.rawValue.capitalized) shortcut sent to the focused Mac app."
        } else {
            status = "Could not create the editing shortcut."
        }
    }
    func perform(_ request: AppControlRequest, controls: MacAppControls) {
        guard controls.accepts(request) else {
            status = "App changed; outdated button ignored."
            return
        }
        guard let events = StandardActionEvents.make(request.action) else {
            status = "Could not create the app shortcut."
            return
        }
        for event in events { event.post(tap: .cghidEventTap) }
        status = "\(request.action.label) sent to \(controls.context.name)."
    }

}
