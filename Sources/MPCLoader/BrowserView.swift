import SwiftUI
import UniformTypeIdentifiers
import MPCKit

/// The open folder, shown in the chosen view, with the preview player, path bar and status bar below.
struct BrowserView: View {
    @EnvironmentObject private var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            PreviewStrip(player: model.preview)
            // As in Finder: the path bar sits at the bottom, above the status bar, in every view.
            PathBar()
            Divider()
            StatusBar()
        }
        // Files dragged in from Finder. Only real files on the Mac count, so a row dragged out of
        // this window and dropped back on it does nothing.
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            model.acceptDrop(providers)
        }
        .onChange(of: model.selection) { _, _ in
            model.previewFollowsSelection()
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
                Button("Try Again") { model.refresh() }
            }
        } else {
            layout
                .overlay {
                    if model.isLoading && model.entries.isEmpty && model.viewMode != .columns {
                        ProgressView()
                    } else if !model.isLoading && model.visibleEntries.isEmpty && model.viewMode != .columns {
                        emptyState
                    }
                }
        }
    }

    @ViewBuilder
    private var layout: some View {
        switch model.viewMode {
        case .icons: IconGridView()
        case .list: table
        case .columns: ColumnsView()
        case .gallery: GalleryView()
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
        Table(of: RemoteEntry.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { entry in
                HStack(spacing: 6) {
                    EntryIcon(entry: entry, size: 16)
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 160, ideal: 270)

            TableColumn("Date Modified", value: \.sortDate) { entry in
                Text(entry.modified.map { Format.date.string(from: $0) } ?? "--")
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Size", value: \.size) { entry in
                Text(entry.kind == .file ? Format.bytes(entry.size) : "--")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 70)

            TableColumn("Kind", value: \.kindDescription) { entry in
                Text(entry.kindDescription)
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 120)
        } rows: {
            ForEach(model.visibleEntries) { entry in
                // Each row can be dragged out to Finder. The copy starts when it is dropped.
                TableRow(entry)
                    .itemProvider { model.dragProvider(for: entry) }
            }
        }
        .contextMenu(forSelectionType: RemoteEntry.ID.self) { ids in
            EntryMenu(ids: ids)
        } primaryAction: { ids in
            // Double-click: open a folder, or play an audio file.
            if ids.count == 1, let entry = model.entries.first(where: { ids.contains($0.id) }) { model.activate(entry) }
        }
        .onDeleteCommand { model.requestDelete() }
        .onKeyPress(.space) {
            model.togglePreview() ? .handled : .ignored
        }
    }
}

/// The path bar, as in Finder: the drive, then each folder down to the open one. Click any part to go there.
private struct PathBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    let crumbs = model.breadcrumb
                    ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            model.open(path: crumb.path)
                        } label: {
                            HStack(spacing: 4) {
                                if index == 0 {
                                    Image(systemName: model.currentDrive?.symbolName ?? "externaldrive")
                                        .foregroundStyle(.secondary)
                                } else {
                                    Image(nsImage: FileIcons.folder)
                                        .resizable()
                                        .frame(width: 14, height: 14)
                                }
                                Text(crumb.name)
                                    .lineLimit(1)
                            }
                            .font(.callout)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(index == crumbs.count - 1)
                        .help(index == crumbs.count - 1 ? crumb.name : "Go to “\(crumb.name)”")
                    }
                }
                .padding(.horizontal, 12)
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
        .frame(height: 26)
        .background(.bar)
        .accessibilityLabel("Path")
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
            } else if model.draggingOut > 0 {
                ProgressView()
                    .controlSize(.small)
                Text("Copying \(Format.count(model.draggingOut, "dragged item", "dragged items")) to this Mac…")
                Spacer()
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

/// The player that appears above the status bar while an audio file is being previewed.
struct PreviewStrip: View {
    @ObservedObject var player: PreviewPlayer

    var body: some View {
        if player.isOpen {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button { player.togglePlayback() } label: {
                        Image(systemName: player.isPlaying || player.isLoading ? "stop.fill" : "play.fill")
                            .frame(width: 16)
                    }
                    .buttonStyle(.borderless)
                    .help(player.isPlaying || player.isLoading ? "Stop" : "Play again")

                    Image(systemName: "waveform")
                        .foregroundStyle(.secondary)
                    Text(player.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)

                    detail
                    Spacer(minLength: 8)
                    Button { player.close() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Close the preview")
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(.bar)
                Divider()
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch player.phase {
        case .loading(let fraction):
            ProgressView(value: fraction)
                .frame(width: 140)
            Text("Fetching from the MPC…")
                .foregroundStyle(.secondary)
        case .playing, .stopped:
            ProgressView(value: min(player.position, max(player.duration, 0.01)), total: max(player.duration, 0.01))
                .frame(width: 180)
            Text(player.timeText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(message)
        case .closed:
            EmptyView()
        }
    }
}
