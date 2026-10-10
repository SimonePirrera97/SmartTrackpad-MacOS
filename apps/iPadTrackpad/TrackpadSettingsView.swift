import SwiftUI

struct TrackpadSettingsView: View {
    @ObservedObject var settings: TrackpadSettings
    var nativePinchAvailable = false
    var missionControlAvailable = false
    var pagesAvailable = false
    var macPreferences: TrackpadPreferences?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let macPreferences {
                    Section("Mac preferences") {
                        Button("Use Mac click, drag and scroll settings") { settings.applyMacPreferences(macPreferences) }
                        Text("Imports available settings captured when paired. You can adjust them below. Pointer speed and timing remain independent.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Click and drag") {
                    Toggle("Tap to click", isOn: $settings.tapToClick)
                    Toggle("Two-finger tap for right-click", isOn: $settings.twoFingerTap)
                    Toggle("Hold one finger to drag", isOn: $settings.holdToDrag)
                    Toggle("Three-finger drag", isOn: $settings.threeFingerDrag)
                    HStack {
                        Text("Maximum tap duration")
                        Slider(value: $settings.tapDuration, in: 0.15...0.4)
                        Text(String(format: "%.2f s", settings.tapDuration))
                    }
                    HStack {
                        Text("Tap movement tolerance")
                        Slider(value: $settings.tapTolerance, in: 4...25)
                    }
                    HStack {
                        Text("Hold delay")
                        Slider(value: $settings.holdDuration, in: 0.3...0.9)
                        Text(String(format: "%.2f s", settings.holdDuration))
                    }
                    Text("Hold still until dragging starts, then move. Lift your finger to release.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Movement and scrolling") {
                    HStack {
                        Text("Pointer speed")
                        Slider(value: $settings.sensitivity, in: 0.25...3)
                    }
                    HStack {
                        Text("Scroll speed")
                        Slider(value: $settings.scrollSpeed, in: 0.25...3)
                    }
                    Toggle("Natural scrolling", isOn: $settings.naturalScroll)
                    Text("Scroll momentum can be switched off in the Mac companion.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Navigation gestures") {
                    Toggle("Interactive Mission Control", isOn: $settings.threeFingerMissionControl)
                        .disabled(!missionControlAvailable)
                    Toggle("Three-finger page swipes", isOn: $settings.pageSwipes)
                        .disabled(!pagesAvailable)
                    Text("Three fingers up to open Mission Control, down to close. Move back to reverse the animation. Three fingers right/left navigate back/forward in supported apps. Two fingers still scroll horizontally. Enabling navigation switches off three-finger drag.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Pinch to zoom") {
                    Toggle("Pinch to zoom", isOn: $settings.pinchEnabled)
                        .disabled(!nativePinchAvailable)
                    Text(nativePinchAvailable
                         ? "Use two fingers to zoom in or out in supported apps."
                         : "Pinch to zoom is unavailable on the connected Mac.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Help") {
                    Link(destination: URL(string: "https://github.com/SimonePirrera97/SmartTrackpad-MacOS#readme")!) {
                        Label("Help and documentation", systemImage: "book")
                    }
                }
            }
            .navigationTitle("Trackpad settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
