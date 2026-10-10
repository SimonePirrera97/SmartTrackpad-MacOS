import AppKit

@MainActor
final class MacAppControls {
    private(set) var context = AppControlContext(app: .other, token: UUID().uuidString)
    private var process: pid_t?
    var onChange: (() -> Void)?

    static func app(for identifier: String?) -> ControlApp {
        switch identifier {
        case "com.microsoft.VSCode": .vscode
        case "com.apple.Terminal": .terminal
        case "com.apple.Safari": .safari
        case "com.spotify.client": .spotify
        case "com.apple.finder": .finder
        default: .other
        }
    }

    /// Recheck at dispatch as well as activation, so stale iPad controls never
    /// send a command to another app or a newly launched instance.
    @discardableResult
    func refresh() -> AppControlContext {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let app = Self.app(for: frontmost?.bundleIdentifier)
        if frontmost?.processIdentifier != process || app != context.app {
            process = frontmost?.processIdentifier
            context = AppControlContext(app: app, token: UUID().uuidString)
            onChange?()
        }
        return context
    }

    func accepts(_ request: AppControlRequest) -> Bool {
        let current = refresh()
        return current.accepts(request, activeApp: current.app)
    }
}
