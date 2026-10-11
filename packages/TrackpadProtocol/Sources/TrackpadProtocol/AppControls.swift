import Foundation

/// Portable fixed controls for this increment. Apple app detection and key posting
/// belong to the Mac adapters; future clients can use these same identifiers.
enum ControlApp: String, Codable, Sendable { case other, vscode, terminal, safari, spotify, finder }
enum AppControlAction: String, Codable, Sendable, CaseIterable {
    case save, compile, delete, deleteWord, enter, newTab, closeTab, playPause, previousTrack, nextTrack, volumeDown, volumeUp, newFolder, trash
    var label: String {
        switch self {
        case .save: "Save"
        case .compile: "Compile"
        case .delete: "Delete"
        case .deleteWord: "Delete Word"
        case .enter: "Enter"
        case .newTab: "New Tab"
        case .closeTab: "Close Tab"
        case .playPause: "Play / Pause"
        case .previousTrack: "Previous"
        case .nextTrack: "Next"
        case .volumeDown: "Volume Down"
        case .volumeUp: "Volume Up"
        case .newFolder: "New Folder"
        case .trash: "Move to Trash"
        }
    }
}
struct AppControlContext: Codable, Sendable, Equatable {
    let app: ControlApp
    let token: String
    var valid: Bool { UUID(uuidString: token) != nil }
    var name: String {
        switch app { case .other: "Editing"; case .vscode: "VS Code"; case .terminal: "Terminal"; case .safari: "Safari"; case .spotify: "Spotify"; case .finder: "Finder" }
    }
    var actions: [AppControlAction] {
        switch app {
        case .other: []
        case .vscode: [.save, .compile, .delete]
        case .terminal: [.deleteWord, .enter]
        case .safari: [.save, .newTab, .closeTab]
        case .spotify: [.playPause, .previousTrack, .nextTrack, .volumeDown, .volumeUp]
        case .finder: [.newFolder, .trash]
        }
    }
    func request(_ action: AppControlAction) -> AppControlRequest {
        AppControlRequest(app: app, token: token, action: action)
    }
    func accepts(_ request: AppControlRequest, activeApp: ControlApp) -> Bool {
        valid && request.valid && app == activeApp && request.app == app
            && UUID(uuidString: request.token) == UUID(uuidString: token) && actions.contains(request.action)
    }
}
struct AppControlRequest: Codable, Sendable, Equatable {
    let app: ControlApp
    let token: String
    let action: AppControlAction
    var valid: Bool { UUID(uuidString: token) != nil && AppControlContext(app: app, token: token).actions.contains(action) }
}
