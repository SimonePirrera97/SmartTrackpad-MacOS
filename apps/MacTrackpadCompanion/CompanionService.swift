import AppKit
import Combine

/// Own cleanup for the app's lifetime, independently of menu visibility.
@MainActor
final class CompanionService: ObservableObject {
    let connection = ConnectionModel(role: .server)
    let pointer = QuartzPointerBackend()
    let actions = MacActionBackend()
    let appControls = MacAppControls()
    let nativePinch = NativePinchBackend()
    let navigation = NativeNavigationBackend()
    private var observers: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()

    init() {
        connection.localCapabilities = InputKind.supportedCapabilities.filter {
            switch $0 {
            case "gesture.magnify.experimental": return nativePinch.available
            case "gesture.pages.experimental": return navigation.pagesAvailable
            case "gesture.missionControl.experimental": return navigation.missionControlAvailable
            case "action.showDesktop.experimental": return navigation.desktopAvailable
            default: return true
            }
        }
        appControls.refresh()
        appControls.onChange = { [weak connection] in connection?.refreshAppContext() }
        connection.appContextSnapshot = { [weak appControls] in
            appControls?.context ?? AppControlContext(app: .other, token: UUID().uuidString)
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak appControls] _ in
                MainActor.assumeIsolated { _ = appControls?.refresh() }
            })
        connection.preferenceSnapshot = { MacTrackpadPreferences.snapshot() }
        connection.onInput = { [weak pointer, weak actions, weak appControls, weak nativePinch, weak navigation] command in
            guard let pointer else { return }
            if command.kind == .releaseAll {
                nativePinch?.cancel()
                navigation?.cancel()
                pointer.releaseAll()
            } else if command.kind == .pageSwipe || command.kind == .missionControl || command.kind == .showDesktop {
                pointer.refreshPermission()
                guard pointer.enabled, pointer.permissionGranted else { navigation?.cancel(); return }
                if command.phase == .began || command.kind == .showDesktop {
                    pointer.releaseAll()
                    nativePinch?.cancel()
                }
                navigation?.perform(command)
            } else if command.kind == .magnify {
                pointer.refreshPermission()
                guard pointer.enabled, pointer.permissionGranted else { nativePinch?.cancel(); return }
                if command.phase == .began { pointer.releaseAll(); navigation?.cancel() }
                nativePinch?.perform(command)
            } else if command.kind == .appControl, let request = command.appControl, let appControls {
                pointer.refreshPermission()
                guard pointer.enabled, pointer.permissionGranted else { return }
                pointer.releaseAll()
                nativePinch?.cancel()
                navigation?.cancel()
                actions?.perform(request, controls: appControls)
            } else if command.kind == .action, let action = command.action {
                pointer.refreshPermission()
                guard pointer.enabled, pointer.permissionGranted else { return }
                pointer.releaseAll()
                nativePinch?.cancel()
                navigation?.cancel()
                actions?.perform(action)
            } else {
                if command.kind == .move || command.kind == .click || command.kind == .button || (command.kind == .scroll && command.phase == .began) {
                    nativePinch?.cancel(); navigation?.cancel()
                }
                pointer.perform(command)
            }
        }
        connection.onResetInput = { [weak pointer, weak nativePinch, weak navigation] in pointer?.releaseAll(); nativePinch?.cancel(); navigation?.cancel() }
        pointer.$enabled.sink { [weak nativePinch, weak navigation] enabled in
            if !enabled { MainActor.assumeIsolated { nativePinch?.cancel(); navigation?.cancel() } }
        }.store(in: &subscriptions)
        // Delivery on the main queue makes termination cleanup synchronous in the AppKit session.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseInput() }
            })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name,
                object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.releaseInput() }
                })
        }
    }

    private func releaseInput() {
        connection.disconnect(reason: "Mac session inactive · reconnect to continue")
        pointer.releaseAll()
    }
}
