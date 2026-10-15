import SwiftUI

struct EditingActionStrip: View {
    let enabled: Bool
    var desktopEnabled = false
    var context: AppControlContext?
    var showDesktop: () -> Void = {}
    var performApp: (AppControlRequest) -> Void = { _ in }
    let perform: (StandardAction) -> Void
    private var hasAdditionalButtons: Bool {
        context?.app == .safari
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(context?.name ?? "Editing").font(.headline)
            GeometryReader { geometry in
                let rowUnits = context?.app == .safari || context?.app == .vscode ? 3.8 : 2.8
                let reservedHeight: CGFloat = hasAdditionalButtons ? (context?.app == .safari ? 36 : 24) : 104
                let rowHeight = max(90, (geometry.size.height - reservedHeight) / rowUnits)
                ScrollViewReader { scroll in
                    ScrollView(.vertical) {
                        VStack(spacing: 12) {
                            editingControls(rowHeight: rowHeight)
                                .id("controls-top")
                            if hasAdditionalButtons, let context {
                                Divider()
                                ForEach(context.app == .safari ? [.save] : context.actions, id: \.self) { action in
                                    controlButton(action.label, symbol: symbol(action)) {
                                        performApp(context.request(action))
                                    }
                                    .frame(height: rowHeight)
                                }
                            }
                            Button(action: showDesktop) {
                                Label("Show Desktop", systemImage: "desktopcomputer")
                                    .font(.headline).frame(maxWidth: .infinity, minHeight: 56)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!desktopEnabled)
                            .accessibilityLabel("Show Desktop or restore windows")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 4)
                    }
                    .onChange(of: context?.app) { _, _ in
                        scroll.scrollTo("controls-top", anchor: .top)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(enabled || desktopEnabled ? 1 : 0.5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mac controls")
    }

    @ViewBuilder private func editingControls(rowHeight: CGFloat) -> some View {
        if let context, context.app == .spotify {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    controlButton("Previous", symbol: "backward.end.fill") { performApp(context.request(.previousTrack)) }
                    controlButton("Next", symbol: "forward.end.fill") { performApp(context.request(.nextTrack)) }
                }.frame(height: rowHeight)
                controlButton("Play / Pause", symbol: "playpause.fill") { performApp(context.request(.playPause)) }
                    .frame(height: rowHeight * 0.8)
                HStack(spacing: 8) {
                    controlButton("Volume Down", symbol: "speaker.wave.1") { performApp(context.request(.volumeDown)) }
                    controlButton("Volume Up", symbol: "speaker.wave.3") { performApp(context.request(.volumeUp)) }
                }.frame(height: rowHeight)
            }
        } else {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    actionButton("Copy", symbol: "doc.on.doc", action: .copy)
                    actionButton("Cut", symbol: "scissors", action: .cut)
                }.frame(height: rowHeight)
                actionButton("Paste", symbol: "doc.on.clipboard", action: .paste)
                    .frame(height: rowHeight * 0.8)
                if let context, context.app == .safari {
                    HStack(spacing: 8) {
                        controlButton("New Tab", symbol: "plus.square") { performApp(context.request(.newTab)) }
                        controlButton("Close Tab", symbol: "xmark.square") { performApp(context.request(.closeTab)) }
                    }.frame(height: rowHeight)
                }
                if let context, context.app == .vscode {
                    HStack(spacing: 8) {
                        controlButton("Save", symbol: "square.and.arrow.down") { performApp(context.request(.save)) }
                        controlButton("Delete", symbol: "delete.left") { performApp(context.request(.delete)) }
                    }.frame(height: rowHeight)
                }
                HStack(spacing: 8) {
                    if let context, context.app == .terminal {
                        controlButton("Delete Word", symbol: "delete.left") { performApp(context.request(.deleteWord)) }
                        controlButton("Enter", symbol: "return") { performApp(context.request(.enter)) }
                    } else if let context, context.app == .finder {
                        controlButton("New Folder", symbol: "folder.badge.plus") { performApp(context.request(.newFolder)) }
                        controlButton("Move to Trash", symbol: "trash") { performApp(context.request(.trash)) }
                    } else {
                        actionButton("Undo", symbol: "arrow.uturn.backward", action: .undo)
                        actionButton("Redo", symbol: "arrow.uturn.forward", action: .redo)
                    }
                }.frame(height: rowHeight)
            }
        }
    }

    private func symbol(_ action: AppControlAction) -> String {
        switch action {
        case .save: "square.and.arrow.down"
        case .compile: "hammer"
        case .delete, .deleteWord: "delete.left"
        case .enter: "return"
        case .newTab: "plus.square"
        case .closeTab: "xmark.square"
        case .playPause: "playpause.fill"
        case .previousTrack: "backward.end.fill"
        case .nextTrack: "forward.end.fill"
        case .volumeDown: "speaker.wave.1"
        case .volumeUp: "speaker.wave.3"
        case .newFolder: "folder.badge.plus"
        case .trash: "trash"
        }
    }
    private func actionButton(_ title: String, symbol: String, action: StandardAction) -> some View {
        controlButton(title, symbol: symbol) { perform(action) }
    }
    private func controlButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.headline).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 72)
            .foregroundStyle(.blue)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("\(title) in the focused Mac app")
    }
}
