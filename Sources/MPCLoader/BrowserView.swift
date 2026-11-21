import SwiftUI
import MPCKit

/// The file list for the open folder, with the path above it and status below.
struct BrowserView: View {
    @EnvironmentObject private var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            PathBar()
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StatusBar()
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty, model.isConnected, model.currentPath != nil else { return false }
            model.upload(files)
            return true
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
        .overlay {
            if dropTargeted && model.currentPath != nil {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.currentPath == nil {
            ContentUnavailableView("No Drives", systemImage: "externaldrive.badge.questionmark",
                                   description: Text("The MPC has no storage mounted. Insert an SD card or USB drive and it will appear in the sidebar."))
        } else if let error = model.folderError {
            ContentUnavailableView {
                Label("This Folder Can't Be Shown", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { model.reload() }
            }
        } else {
            table
                .overlay {
                    if model.isLoading && model.entries.isEmpty {
                        ProgressView()
                    } else if !model.isLoading && model.visibleEntries.isEmpty {
                        emptyState
                    }
                }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else if model.currentDrive?.isWritable == true {
            ContentUnavailableView("This Folder Is Empty", systemImage: "folder",
                                   description: Text("Drag samples here from Finder, or choose Copy to MPC."))
        } else {
            ContentUnavailableView("This Folder Is Empty", systemImage: "folder")
        }
    }

    private var table: some View {
        Table(model.visibleEntries, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { entry in
                HStack(spacing: 6) {
                    Image(systemName: entry.symbolName)
                        .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                        .frame(width: 18)
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 180, ideal: 360)

            TableColumn("Date Modified", value: \.sortDate) { entry in
                Text(entry.modified.map { Format.date.string(from: $0) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170)

            TableColumn("Size", value: \.size) { entry in
                Text(entry.kind == .file ? Format.bytes(entry.size) : "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Kind", value: \.kindDescription) { entry in
                Text(entry.kindDescription)
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 150)
        }
        .contextMenu(forSelectionType: RemoteEntry.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            // Double-click: open a folder.
            if ids.count == 1, let entry = model.entries.first(where: { ids.contains($0.id) }), entry.isDirectory {
                model.open(entry)
            }
        }
        .onDeleteCommand { model.requestDelete() }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<RemoteEntry.ID>) -> some View {
        if ids.isEmpty {
            Button("New Folder") { model.requestNewFolder() }
                .disabled(!model.canWriteHere)
            Button("Copy Files to MPC…") { model.chooseFilesToUpload() }
                .disabled(!model.canWriteHere)
            Divider()
            Button("Refresh") { model.reload() }
        } else {
            let targets = model.entries.filter { ids.contains($0.id) }
            if targets.count == 1, targets[0].isDirectory {
                Button("Open") { model.open(targets[0]) }
                Divider()
            }
            Button("Copy to Mac…") {
                model.selection = ids
                model.chooseWhereToDownload()
            }
            .disabled(!model.canCopy)
            Divider()
            Button("Rename…") {
                model.selection = ids
                model.requestRename()
            }
            .disabled(!model.canWriteHere || ids.count != 1)
            Button("Delete…") {
                model.selection = ids
                model.requestDelete()
            }
            .disabled(!model.canWriteHere)
        }
    }
}

/// Where you are: the drive, then each folder down to the open one. Click any part to go there.
private struct PathBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    let crumbs = model.breadcrumb
                    ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            model.open(path: crumb.path)
                        } label: {
                            Label(crumb.name, systemImage: index == 0 ? (model.currentDrive?.symbolName ?? "externaldrive") : "folder")
                                .labelStyle(.titleAndIcon)
                                .font(.callout)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(index == crumbs.count - 1 ? Color.primary : Color.secondary)
                        .disabled(index == crumbs.count - 1)
                        .help(index == crumbs.count - 1 ? crumb.name : "Go to “\(crumb.name)”")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            if let drive = model.currentDrive, !drive.isWritable {
                Label("Read-only", systemImage: "lock.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 12)
                    .help(drive.kind == .factoryContent
                          ? "Factory content can be copied to your Mac but not changed, so the MPC's built-in sounds stay intact."
                          : "The MPC has this drive mounted read-only.")
            }
        }
        .background(.bar)
    }
}

/// The strip along the bottom: copy progress while copying, otherwise what the folder holds.
private struct StatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if let transfer = model.transfer {
                progress(transfer)
            } else if let summary = model.lastSummary {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(summary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !model.lastRevealURLs.isEmpty {
                    Button("Show in Finder") { model.revealLastDownload() }
                        .buttonStyle(.link)
                }
                Spacer()
                Button { model.dismissSummary() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
            } else {
                Spacer()
                Text(idleText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.bar)
    }

    @ViewBuilder
    private func progress(_ transfer: AppModel.TransferStatus) -> some View {
        if transfer.preparing {
            ProgressView()
                .controlSize(.small)
            Text("Getting ready to copy…")
            Spacer()
        } else {
            ProgressView(value: transfer.fraction)
                .frame(width: 160)
            Text(progressText(transfer))
                .lineLimit(1)
                .truncationMode(.middle)
                .monospacedDigit()
            Spacer()
        }
        Button("Cancel") { model.cancelTransfer() }
            .controlSize(.small)
    }

    private func progressText(_ transfer: AppModel.TransferStatus) -> String {
        let direction = transfer.toMPC ? "to the MPC" : "to this Mac"
        let position = "\(min(transfer.completedFiles + 1, max(transfer.totalFiles, 1))) of \(transfer.totalFiles)"
        let amount = "\(Format.bytes(transfer.completedBytes)) of \(Format.bytes(transfer.totalBytes))"
        if transfer.currentName.isEmpty { return "Copying \(direction) · \(position) · \(amount)" }
        return "Copying “\(transfer.currentName)” \(direction) · \(position) · \(amount)"
    }

    private var idleText: String {
        var parts: [String] = []
        let shown = model.visibleEntries.count
        if model.selection.isEmpty {
            parts.append(Format.count(shown, "item", "items"))
        } else {
            parts.append("\(model.selection.count) of \(shown) selected")
        }
        if let free = model.currentDrive?.freeBytes {
            parts.append("\(Format.bytes(free)) available")
        }
        return parts.joined(separator: ", ")
    }
}
