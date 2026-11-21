import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MPCKit

/// The icons macOS itself uses for each kind of file, so the window looks like Finder.
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func image(for entry: RemoteEntry) -> NSImage {
        let key: String
        let type: UTType
        switch entry.kind {
        case .directory:
            key = "/folder"
            type = .folder
        case .link:
            key = "/link"
            type = .symbolicLink
        case .other:
            key = "/other"
            type = .data
        case .file:
            let ext = entry.fileExtension
            key = ext
            type = ext.isEmpty ? .data : (UTType(filenameExtension: ext) ?? .data)
        }
        if let known = cache[key] { return known }
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }

    static let folder = NSWorkspace.shared.icon(for: .folder)
}

struct EntryIcon: View {
    let entry: RemoteEntry
    let size: CGFloat

    var body: some View {
        Image(nsImage: FileIcons.image(for: entry))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The right-click menu, shared by every view. An empty set means the click was on empty space.
struct EntryMenu: View {
    @EnvironmentObject private var model: AppModel
    let ids: Set<RemoteEntry.ID>

    var body: some View {
        if ids.isEmpty {
            Button("New Folder") { model.requestNewFolder() }
                .disabled(!model.canWriteHere)
            Button("Copy Files to MPC…") { model.chooseFilesToUpload() }
                .disabled(!model.canWriteHere)
            Divider()
            Button("Refresh") { model.refresh() }
        } else {
            let targets = model.entries.filter { ids.contains($0.id) }
            if targets.count == 1, targets[0].isDirectory {
                Button("Open") { model.open(targets[0]) }
                Divider()
            }
            if targets.count == 1, model.canPreview(targets[0]) {
                Button("Preview") {
                    model.selection = ids
                    model.preview(targets[0])
                }
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

/// Mouse behaviour for an item in the icon and gallery views: click to select, double-click to
/// open or play, drag out to Finder, right-click for the menu.
private struct EntryInteractions: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let entry: RemoteEntry

    func body(content: Content) -> some View {
        content
            .gesture(TapGesture(count: 2).onEnded { model.activate(entry) })
            .simultaneousGesture(TapGesture().onEnded {
                let flags = NSEvent.modifierFlags
                model.click(entry, command: flags.contains(.command), shift: flags.contains(.shift))
            })
            .onDrag { model.dragProvider(for: entry) ?? NSItemProvider() }
            .contextMenu {
                EntryMenu(ids: model.selection.contains(entry.id) ? model.selection : [entry.id])
            }
    }
}

// MARK: Icons

/// Finder's icon view: a grid of large icons with names underneath.
struct IconGridView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool
    @State private var width: CGFloat = 600

    private let cellWidth: CGFloat = 108
    private let spacing: CGFloat = 10
    private let margin: CGFloat = 16

    private var perRow: Int {
        max(1, Int((width - margin * 2 + spacing) / (cellWidth + spacing)))
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cellWidth, maximum: cellWidth), spacing: spacing, alignment: .top)],
                          alignment: .leading, spacing: 14) {
                    ForEach(model.visibleEntries) { entry in
                        IconCell(entry: entry, isSelected: model.selection.contains(entry.id), width: cellWidth)
                            .modifier(EntryInteractions(entry: entry))
                    }
                }
                .padding(margin)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture { model.selection = [] }
                .contextMenu { EntryMenu(ids: []) }
            }
            .onChange(of: geometry.size.width, initial: true) { _, newWidth in
                width = newWidth
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { model.moveSelection(by: -1); return .handled }
        .onKeyPress(.rightArrow) { model.moveSelection(by: 1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(by: -perRow); return .handled }
        .onKeyPress(.downArrow) { model.moveSelection(by: perRow); return .handled }
        .onKeyPress(.space) { model.togglePreview() ? .handled : .ignored }
        .onDeleteCommand { model.requestDelete() }
        .onAppear { focused = true }
    }
}

private struct IconCell: View {
    let entry: RemoteEntry
    let isSelected: Bool
    let width: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            EntryIcon(entry: entry, size: 64)
                .padding(6)
                .background(isSelected ? Color.primary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            Text(entry.name)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .frame(width: width, alignment: .top)
        .contentShape(Rectangle())
        .help(entry.name)
    }
}

// MARK: Columns

/// Finder's column view: each folder on the way down gets its own column, and a selected file
/// gets a details column at the end.
struct ColumnsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(model.columnPaths, id: \.self) { path in
                        BrowserColumn(path: path)
                            .frame(width: 232)
                            .id(path)
                        Divider()
                    }
                    if model.selection.count == 1, let entry = model.focusedEntry, !entry.isDirectory {
                        ItemDetails(entry: entry, iconSize: 96)
                            .frame(width: 250)
                            .frame(maxHeight: .infinity)
                            .id("details")
                        Divider()
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .onChange(of: model.currentPath, initial: true) { _, path in
                if let path { proxy.scrollTo(path, anchor: .trailing) }
            }
        }
    }
}

private struct BrowserColumn: View {
    @EnvironmentObject private var model: AppModel
    let path: String

    var body: some View {
        let items = model.entries(inColumn: path)
        Group {
            if path == model.currentPath {
                // The open folder: full selection, menus and dragging.
                List(items, selection: $model.selection) { entry in
                    row(entry)
                        .itemProvider { model.dragProvider(for: entry) }
                }
                .contextMenu(forSelectionType: RemoteEntry.ID.self) { ids in
                    EntryMenu(ids: ids)
                } primaryAction: { ids in
                    if ids.count == 1, let entry = items.first(where: { ids.contains($0.id) }) { model.activate(entry) }
                }
                .onKeyPress(.space) { model.togglePreview() ? .handled : .ignored }
                .onDeleteCommand { model.requestDelete() }
                .onChange(of: model.selection) { _, selected in
                    // Selecting a folder shows what is inside it in the next column, as Finder does.
                    guard model.viewMode == .columns, selected.count == 1,
                          let entry = items.first(where: { selected.contains($0.id) }), entry.isDirectory else { return }
                    model.open(entry)
                }
            } else {
                // A folder further up: it highlights the folder you came through. Picking anything else goes there.
                List(items, selection: throughSelection(items)) { entry in
                    row(entry)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if items.isEmpty, path != model.currentPath || !model.isLoading {
                Text(path == model.currentPath ? "Empty" : "")
                    .foregroundStyle(.tertiary)
            } else if items.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func row(_ entry: RemoteEntry) -> some View {
        HStack(spacing: 6) {
            EntryIcon(entry: entry, size: 16)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func throughSelection(_ items: [RemoteEntry]) -> Binding<String?> {
        Binding(get: {
            let paths = model.columnPaths
            guard let index = paths.firstIndex(of: path), index + 1 < paths.count else { return nil }
            return paths[index + 1]
        }, set: { chosen in
            guard let chosen, let entry = items.first(where: { $0.id == chosen }) else { return }
            if entry.isDirectory {
                model.open(path: entry.path)
            } else {
                model.open(path: path, selecting: entry.id)
            }
        })
    }
}

// MARK: Gallery

/// Finder's gallery view: the selected item shown large, with a strip of everything else below.
struct GalleryView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let entry = model.focusedEntry {
                    ItemDetails(entry: entry, iconSize: 160)
                } else {
                    Text("Select an item")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .contextMenu { EntryMenu(ids: model.selection) }

            Divider()
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 6) {
                        ForEach(model.visibleEntries) { entry in
                            GalleryThumbnail(entry: entry, isSelected: model.selection.contains(entry.id))
                                .modifier(EntryInteractions(entry: entry))
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(height: 98)
                .onChange(of: model.selection) { _, _ in
                    if let entry = model.focusedEntry { proxy.scrollTo(entry.id, anchor: .center) }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { model.moveSelection(by: -1); return .handled }
        .onKeyPress(.rightArrow) { model.moveSelection(by: 1); return .handled }
        .onKeyPress(.space) { model.togglePreview() ? .handled : .ignored }
        .onDeleteCommand { model.requestDelete() }
        .onAppear {
            focused = true
            model.selectFirstIfNothingSelected()
        }
    }
}

private struct GalleryThumbnail: View {
    let entry: RemoteEntry
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 2) {
            EntryIcon(entry: entry, size: 48)
            Text(entry.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 76)
        }
        .padding(5)
        .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
        .contentShape(Rectangle())
        .help(entry.name)
    }
}

/// A large icon with the item's details and the things you can do with it.
/// Used by the gallery and as the last column in column view.
struct ItemDetails: View {
    @EnvironmentObject private var model: AppModel
    let entry: RemoteEntry
    let iconSize: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            EntryIcon(entry: entry, size: iconSize)
            Text(entry.name)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .textSelection(.enabled)
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let modified = entry.modified {
                Text("Modified \(Format.date.string(from: modified))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if entry.isDirectory {
                    Button("Open") { model.open(entry) }
                }
                if model.canPreview(entry) {
                    Button("Preview") { model.preview(entry) }
                }
                Button("Copy to Mac…") {
                    model.selection = [entry.id]
                    model.chooseWhereToDownload()
                }
                .disabled(!model.canCopy)
            }
            .padding(.top, 4)
        }
        .padding(16)
    }

    private var summary: String {
        entry.kind == .file ? "\(entry.kindDescription) · \(Format.bytes(entry.size))" : entry.kindDescription
    }
}
