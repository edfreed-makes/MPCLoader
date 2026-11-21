import SwiftUI
import UniformTypeIdentifiers
import MPCKit

extension UTType {
    /// Items on the MPC being dragged inside the window. Declared in the app's Info.plist.
    static let mpcLoaderItems = UTType(exportedAs: "io.github.edfreed-makes.mpcloader.items")
}

/// What a drag inside the window carries, besides the files Finder can take: where the items
/// are on the MPC. Dropped on a folder, it moves them there.
struct DraggedItems: Codable, Sendable, Transferable {
    /// Which run of the app the drag started in, so a drag from another copy of MPC Loader,
    /// connected to another MPC, is never mistaken for one of ours.
    var session: String
    var paths: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mpcLoaderItems)
    }
}

/// Makes a folder somewhere items from the MPC can be dropped, to move them into it.
/// Used by the icon, column and gallery views, the path bar and the sidebar. The list view's rows
/// take drops through the table instead, which draws its own highlight.
private struct MoveDropTarget: ViewModifier {
    @EnvironmentObject private var model: AppModel
    /// The folder items dropped here go into. Nil when this item is not a folder.
    let folder: String?
    let cornerRadius: CGFloat
    @State private var isTargeted = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if let folder {
            content
                .onDrop(of: [UTType.mpcLoaderItems],
                        delegate: MoveDropDelegate(model: model, folder: folder, isTargeted: $isTargeted))
                .overlay {
                    if isTargeted {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(Color.accentColor.opacity(0.18))
                            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.accentColor, lineWidth: 2))
                            .allowsHitTesting(false)
                    }
                }
        } else {
            content
        }
    }
}

/// Accepts only items dragged from this window, so files from Finder still go to the window
/// itself and are copied to the open folder as before.
private struct MoveDropDelegate: DropDelegate {
    let model: AppModel
    let folder: String
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.mpcLoaderItems])
    }

    func dropEntered(info: DropInfo) {
        AppModel.demoLog("drop target \(RemotePath.lastComponent(of: folder)): entered")
        // A folder being dragged does not light up under the pointer as the drag starts.
        isTargeted = !model.isBeingDragged(folder)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        return model.acceptMoveDrop(info.itemProviders(for: [UTType.mpcLoaderItems]), into: folder)
    }
}

extension View {
    /// Lets items from the MPC be dropped here to move them into `folder`. Nil turns it off.
    func moveDropTarget(_ folder: String?, cornerRadius: CGFloat = 6) -> some View {
        modifier(MoveDropTarget(folder: folder, cornerRadius: cornerRadius))
    }
}
