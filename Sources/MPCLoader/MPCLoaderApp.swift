import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        // Lets the app behave as a normal windowed app even when run straight from `swift run`.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // For screenshots: `--dark` or `--light` pins the appearance. Otherwise the app follows the system.
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        // Demo scenes put the window in a known place so a script can photograph it.
        if AppModel.demoScene != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let window = NSApp.windows.first(where: { $0.isVisible }),
                      let screen = window.screen ?? NSScreen.main else { return }
                let size = NSSize(width: 940, height: 600)
                let origin = NSPoint(x: screen.frame.minX + 40, y: screen.frame.maxY - 60 - size.height)
                window.setFrame(NSRect(origin: origin, size: size), display: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }
}

@main
struct MPCLoaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("MPC Loader", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 500)
                .onAppear {
                    appDelegate.onTerminate = { model.shutdown() }
                }
        }
        .defaultSize(width: 1000, height: 640)
        .commands {
            MPCCommands(model: model)
        }
    }
}

/// Menu bar commands. Every toolbar action is also here, with a keyboard shortcut.
struct MPCCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Folder") { model.requestNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!model.canWriteHere)
            Divider()
            Button("Copy Files to MPC…") { model.chooseFilesToUpload() }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(!model.canWriteHere)
            Button("Copy Selection to Mac…") { model.chooseWhereToDownload() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!model.canCopy || model.selection.isEmpty)
            Button("Preview") { model.togglePreview() }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(model.previewTarget == nil)
            Divider()
            Button("Rename…") { model.requestRename() }
                .disabled(!model.canWriteHere || model.selection.count != 1)
            Button("Delete…") { model.requestDelete() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.canWriteHere || model.selection.isEmpty)
        }
        CommandGroup(after: .toolbar) {
            // The same four views as Finder, with the same shortcuts.
            ForEach(Array(AppModel.ViewMode.allCases.enumerated()), id: \.element) { index, mode in
                Toggle("as \(mode.title)", isOn: Binding(get: { model.viewMode == mode },
                                                         set: { if $0 { model.viewMode = mode } }))
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
            Menu("Sort By") {
                ForEach(AppModel.SortKey.allCases) { key in
                    Toggle(key.title, isOn: Binding(get: { model.sortKey == key },
                                                    set: { if $0 { model.sortKey = key } }))
                }
                Divider()
                Toggle("Ascending", isOn: Binding(get: { model.sortAscending }, set: { if $0 { model.sortAscending = true } }))
                Toggle("Descending", isOn: Binding(get: { !model.sortAscending }, set: { if $0 { model.sortAscending = false } }))
            }
            Divider()
            Toggle("Show Hidden Files", isOn: $model.showHidden)
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Refresh") { model.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.isConnected)
            Divider()
        }
        CommandMenu("Go") {
            Button("Back") { model.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.canGoBack)
            Button("Forward") { model.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.canGoForward)
            Button("Enclosing Folder") { model.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!model.canGoUp)
        }
        CommandMenu("MPC") {
            Button(model.isConnected ? "Disconnect" : "Connect") { model.toggleConnection() }
                .keyboardShortcut("k", modifiers: .command)
            Button("Find MPC on This Network") { model.findMPC() }
                .disabled(model.state != .disconnected || model.search == .searching)
        }
    }
}
