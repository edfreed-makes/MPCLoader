import SwiftUI
import MPCKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var newFolderName = ""
    @State private var renameText = ""

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 340)
        } detail: {
            if model.isConnected {
                BrowserView()
                    .searchable(text: $model.searchText, placement: .toolbar, prompt: "Filter this folder")
            } else {
                ConnectView()
            }
        }
        .navigationTitle(model.isConnected ? (model.breadcrumb.last?.name ?? model.deviceName) : "MPC Loader")
        .navigationSubtitle(model.windowSubtitle)
        .toolbar { toolbar }
        .sheet(item: $model.report) { report in
            ReportSheet(report: report)
        }
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
            Text(targets.contains(where: \.isDirectory)
                 ? "Folders are deleted with everything inside them. This can't be undone."
                 : "This can't be undone.")
        }
        .alert(conflictTitle, isPresented: conflictBinding, presenting: model.conflict) { _ in
            Button("Replace") { model.answerConflict(.replace) }
            Button("Skip") { model.answerConflict(.skip) }
            Button("Cancel", role: .cancel) { model.answerConflict(.cancel) }
        } message: { question in
            Text(conflictMessage(question))
        }
        .alert(model.notice?.title ?? "", isPresented: isPresenting($model.notice), presenting: model.notice) { _ in
            Button("OK") {}
        } message: { notice in
            Text(notice.message)
        }
        .onChange(of: model.isNamingNewFolder) { _, showing in
            if showing { newFolderName = "untitled folder" }
        }
        .onChange(of: model.renaming) { _, entry in
            if let entry { renameText = entry.name }
        }
        .onAppear {
            if !model.isDemo, model.host.trimmingCharacters(in: .whitespaces).isEmpty {
                model.findMPC(fillOnlyIfEmpty: true)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!model.canGoBack)
                .help("Go back")
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!model.canGoForward)
                .help("Go forward")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isConnected {
                Button { model.requestNewFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    .disabled(!model.canWriteHere)
                    .help("Create a folder here on the MPC")
                Button { model.chooseFilesToUpload() } label: { Label("Copy to MPC", systemImage: "arrow.up.doc") }
                    .disabled(!model.canWriteHere)
                    .help("Copy files from this Mac into this folder on the MPC")
                Button { model.chooseWhereToDownload() } label: { Label("Copy to Mac", systemImage: "arrow.down.doc") }
                    .disabled(!model.canCopy || model.selection.isEmpty)
                    .help("Copy the selected items from the MPC to this Mac")
                Button { model.requestDelete() } label: { Label("Delete", systemImage: "trash") }
                    .disabled(!model.canWriteHere || model.selection.isEmpty)
                    .help("Delete the selected items from the MPC")
                Button { model.reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Reload this folder")
            }
            connectionButton
        }
    }

    @ViewBuilder
    private var connectionButton: some View {
        switch model.state {
        case .connected:
            Button { model.disconnect() } label: {
                Label("Disconnect", systemImage: "eject.fill").labelStyle(.titleAndIcon)
            }
            .help("Disconnect from the MPC")
        case .connecting:
            Button { model.cancelConnecting() } label: {
                Label("Cancel", systemImage: "xmark").labelStyle(.titleAndIcon)
            }
            .help("Stop connecting")
        case .disconnected:
            Button { model.connect() } label: {
                Label("Connect", systemImage: "bolt.horizontal.fill").labelStyle(.titleAndIcon)
            }
            .help("Connect to the MPC")
        }
    }

    // MARK: Dialog helpers

    private func isPresenting<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    private var conflictBinding: Binding<Bool> {
        Binding(get: { model.conflict != nil }, set: { showing in
            if !showing, model.conflict != nil { model.answerConflict(.cancel) }
        })
    }

    private var deleteTitle: String {
        guard let targets = model.deleting, !targets.isEmpty else { return "Delete" }
        if targets.count == 1 { return "Delete “\(targets[0].name)” from the MPC?" }
        return "Delete \(targets.count) items from the MPC?"
    }

    private var conflictTitle: String {
        guard let question = model.conflict, !question.names.isEmpty else { return "Replace existing items?" }
        if question.names.count == 1 { return "“\(question.names[0])” already exists in this folder" }
        return "\(question.names.count) items already exist in this folder"
    }

    private func conflictMessage(_ question: AppModel.ConflictQuestion) -> String {
        var text = "Replace swaps the copies on the MPC for the ones from your Mac. For a folder, files with the same name inside it are replaced and everything else in it is kept. Skip leaves them as they are and copies the rest."
        if question.names.count > 1 {
            let shown = question.names.prefix(5).joined(separator: ", ")
            text = shown + (question.names.count > 5 ? " and \(question.names.count - 5) more. " : ". ") + text
        }
        return text
    }
}
