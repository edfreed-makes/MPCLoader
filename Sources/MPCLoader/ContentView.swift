import SwiftUI
import MPCKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var help: HelpNavigator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager
    @State private var newFolderName = ""
    @State private var renameText = ""

    // The window is built up in stages. One long chain of modifiers is more than
    // current Swift compilers will type-check in reasonable time.
    var body: some View {
        withDialogs
            .onChange(of: model.isNamingNewFolder) { _, showing in
                if showing { newFolderName = "untitled folder" }
            }
            .onChange(of: model.renaming) { _, entry in
                if let entry { renameText = entry.name }
            }
            .onAppear(perform: appeared)
            // Moves on the MPC go on the window's undo list, so Edit → Undo Move puts them back.
            .onChange(of: undoManager, initial: true) { _, manager in
                model.undoManager = manager
            }
    }

    /// The sidebar, the open folder or the connect screen, the title and the toolbar.
    private var layout: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 340)
        } detail: {
            detail
        }
        .navigationTitle(windowTitle)
        .navigationSubtitle(model.windowSubtitle)
        .toolbar { toolbar }
    }

    @ViewBuilder
    private var detail: some View {
        if model.isConnected {
            BrowserView()
                .searchable(text: $model.searchText, placement: .toolbar, prompt: "Filter this folder")
        } else {
            ConnectView()
        }
    }

    private var windowTitle: String {
        guard model.isConnected else { return "MPC Loader" }
        return model.breadcrumb.last?.name ?? model.deviceName
    }

    /// The copy report and the "already exists" question.
    private var withSheets: some View {
        layout
            .sheet(item: $model.report) { report in
                ReportSheet(report: report)
            }
            // A sheet rather than an alert: macOS alerts show three buttons at most, and this
            // question needs four, Cancel among them.
            .sheet(item: conflictItem) { question in
                ConflictSheet(question: question) { model.answerConflict($0) }
            }
    }

    /// Asked when an item moved into a folder has the same name as something already there.
    private var withMoveQuestion: some View {
        withSheets
            .alert(moveTitle, isPresented: $model.isAskingMove, presenting: model.moveQuestion) { _ in
                // Skip comes first, which makes it the button Return presses, as when copying:
                // nothing is renamed unless you ask.
                Button("Skip") { model.answerMove(.skip) }
                Button("Keep Both") { model.answerMove(.keepBoth) }
                Button("Cancel", role: .cancel) { model.answerMove(.cancel) }
            } message: { question in
                Text(moveMessage(question))
            }
    }

    /// New folder, rename, delete and notices.
    private var withDialogs: some View {
        withMoveQuestion
            .alert("New Folder", isPresented: $model.isNamingNewFolder) {
                TextField("Name", text: $newFolderName)
                Button("Create") { model.createFolder(named: newFolderName) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Type a name for the new folder.")
            }
            .alert("Rename", isPresented: isPresenting($model.renaming), presenting: model.renaming) { entry in
                TextField("Name", text: $renameText)
                Button("Rename") { model.rename(entry, to: renameText) }
                Button("Cancel", role: .cancel) {}
            } message: { entry in
                Text("Type a new name for “\(entry.name)”.")
            }
            .alert(deleteTitle, isPresented: isPresenting($model.deleting), presenting: model.deleting) { targets in
                Button("Delete", role: .destructive) { model.delete(targets) }
                Button("Cancel", role: .cancel) {}
            } message: { targets in
                Text(deleteMessage(targets))
            }
            .alert(model.notice?.title ?? "", isPresented: isPresenting($model.notice), presenting: model.notice) { _ in
                Button("OK") {}
            } message: { notice in
                Text(notice.message)
            }
    }

    private func deleteMessage(_ targets: [RemoteEntry]) -> String {
        targets.contains(where: \.isDirectory)
            ? "Folders are deleted with everything inside them. This can't be undone."
            : "This can't be undone."
    }

    private func appeared() {
        // Demo scenes that show the About or help window open it straight away.
        switch AppModel.demoScene {
        case .about?:
            openWindow(id: "about")
        case .help?:
            help.show("copy-to-mpc")
            openWindow(id: "help")
        default:
            break
        }
        if !model.isDemo, model.host.trimmingCharacters(in: .whitespaces).isEmpty {
            model.findMPC(fillOnlyIfEmpty: true)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if model.isConnected {
                Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(!model.canGoBack)
                    .help("Go back")
                Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(!model.canGoForward)
                    .help("Go forward")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isConnected {
                Picker("View", selection: $model.viewMode) {
                    ForEach(AppModel.ViewMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbolName)
                            .labelStyle(.iconOnly)
                            .help("Show items as \(mode.title.lowercased())")
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("Show items as icons, in a list, in columns or in a gallery")
                Menu {
                    Picker("Sort By", selection: sortKey) {
                        ForEach(AppModel.SortKey.allCases) { key in
                            Text(key.title).tag(key)
                        }
                    }
                    .pickerStyle(.inline)
                    Picker("Order", selection: sortAscending) {
                        Text("Ascending").tag(true)
                        Text("Descending").tag(false)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Choose what the items are sorted by")
                Button { model.requestNewFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    .disabled(!model.canWriteHere)
                    .help("Create a folder here on the MPC")
                Button { model.chooseFilesToUpload() } label: { Label("Copy to MPC", systemImage: "arrow.up.doc") }
                    .disabled(!model.canCopyHere)
                    .help("Copy files from this Mac into this folder on the MPC. While a copy is running, they wait their turn.")
                Button { model.chooseWhereToDownload() } label: { Label("Copy to Mac", systemImage: "arrow.down.doc") }
                    .disabled(!model.canCopy || model.selection.isEmpty)
                    .help("Copy the selected items from the MPC to this Mac. While a copy is running, they wait their turn.")
                PreviewButton(model: model, player: model.preview)
            }
            connectionButton
        }
    }

    @ViewBuilder
    private var connectionButton: some View {
        switch model.state {
        case .connected:
            // While connected, Disconnect lives at the bottom of the sidebar beside the MPC's
            // name, where it stays on show however narrow the window or full the toolbar.
            EmptyView()
        case .connecting:
            Button { model.cancelConnecting() } label: {
                Label("Cancel", systemImage: "xmark").labelStyle(.titleAndIcon)
            }
            .help("Stop connecting")
        case .disconnected:
            Button { model.connect() } label: {
                Label("Connect", systemImage: "cable.connector").labelStyle(.titleAndIcon)
            }
            .help("Connect to the MPC")
        }
    }

    private var sortKey: Binding<AppModel.SortKey> {
        Binding(get: { model.sortKey }, set: { model.sortKey = $0 })
    }

    private var sortAscending: Binding<Bool> {
        Binding(get: { model.sortAscending }, set: { model.sortAscending = $0 })
    }

    // MARK: Dialog helpers

    private func isPresenting<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    /// Closing the sheet any other way than with one of its buttons counts as Cancel.
    private var conflictItem: Binding<AppModel.ConflictQuestion?> {
        Binding(get: { model.conflict }, set: { newValue in
            if newValue == nil, model.conflict != nil { model.answerConflict(.cancel) }
        })
    }

    private var moveTitle: String {
        guard let question = model.moveQuestion else { return "Move" }
        if question.names.count == 1 {
            return "“\(question.names[0])” already exists in “\(question.folderName)”"
        }
        return "\(question.names.count) items already exist in “\(question.folderName)”"
    }

    private func moveMessage(_ question: AppModel.MoveQuestion) -> String {
        let others = question.movingCount > question.names.count ? " and moves the rest" : ""
        if question.names.count == 1 {
            return "Skip leaves it where it is\(others). Keep Both moves it in as “\(question.keepBothExample)”."
        }
        return "Skip leaves those items where they are\(others). Keep Both moves them in with a number added to each name, for example “\(question.keepBothExample)”."
    }

    private var deleteTitle: String {
        guard let targets = model.deleting, !targets.isEmpty else { return "Delete" }
        if targets.count == 1 { return "Delete “\(targets[0].name)” from the MPC?" }
        return "Delete \(targets.count) items from the MPC?"
    }
}

/// The toolbar's play button. It watches the player so it can turn into a stop button.
private struct PreviewButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: PreviewPlayer

    var body: some View {
        let active = player.isPlaying || player.isLoading
        Button { model.togglePreview() } label: {
            Label(active ? "Stop Preview" : "Preview", systemImage: active ? "stop.circle" : "play.circle")
        }
        .disabled(model.previewTarget == nil && !player.isOpen)
        .help(active ? "Stop the preview" : "Play the selected audio file (Space)")
    }
}
