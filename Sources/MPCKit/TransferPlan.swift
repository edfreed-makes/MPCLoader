import Foundation

/// Something that was deliberately left out of a copy, and why.
public struct SkippedItem: Equatable, Hashable, Sendable {
    public enum Reason: Equatable, Hashable, Sendable {
        /// Not a kind of file the MPC can use.
        case unsupportedType
        /// The destination drive's format does not allow this name.
        case nameNotAllowed
        /// Bigger than the destination drive's format can hold.
        case tooLarge
        /// A link, which is never followed.
        case link
        /// Not an ordinary file or folder, or it could not be read.
        case unreadable
    }

    /// The item, as a path relative to what was dragged in (for example "Kit/notes.pdf").
    public let name: String
    public let isFolder: Bool
    public let reason: Reason

    public init(name: String, isFolder: Bool = false, reason: Reason) {
        self.name = name
        self.isFolder = isFolder
        self.reason = reason
    }
}

public extension SkippedItem.Reason {
    /// A short heading for a group of skipped items.
    func heading(driveFormat: String = "") -> String {
        switch self {
        case .unsupportedType:
            return "Not a file type the MPC can use"
        case .nameNotAllowed:
            return driveFormat.isEmpty ? "Names the drive doesn't allow" : "Names the drive's format (\(driveFormat)) doesn't allow"
        case .tooLarge:
            return "Too large for the drive"
        case .link:
            return "Links, which are not copied"
        case .unreadable:
            return "Could not be read"
        }
    }

    /// What the user can do about it, when there is something. Shown under the list.
    var advice: String? {
        switch self {
        case .unsupportedType:
            return "MPC Loader copies \(MPCFileTypes.summary)."
        case .nameNotAllowed:
            return "exFAT, FAT32 and NTFS drives don't allow \" * : < > ? \\ | in names, or names that end with a space or a full stop. Rename those items on your Mac and copy them again."
        case .tooLarge:
            return "FAT32 drives hold files of up to 4 GB. Formatting the drive on the MPC makes it exFAT, which has no such limit, but erases it."
        case .link, .unreadable:
            return nil
        }
    }
}

/// Works out, file by file, what a copy involves before it starts.
public enum TransferPlan {
    /// Clutter that Finder and Windows leave behind. Never copied, never reported.
    public static let junkNames: Set<String> = [".DS_Store", "Thumbs.db", "desktop.ini", ".Spotlight-V100",
                                                ".fseventsd", ".Trashes", ".TemporaryItems"]

    public static func isJunk(_ name: String) -> Bool {
        junkNames.contains(name) || name.hasPrefix("._")
    }

    /// The name a Mac file gets on the MPC. Accented letters are stored as single characters,
    /// which is the form Linux and the MPC's screen expect.
    public static func remoteName(for url: URL) -> String {
        url.lastPathComponent.precomposedStringWithCanonicalMapping
    }

    // MARK: Mac to MPC

    public struct UploadFile: Equatable, Sendable {
        public let local: URL
        public let remote: String
        public let size: Int64
    }

    public struct Upload: Equatable, Sendable {
        /// Folders to create on the MPC, outermost first.
        public var directories: [String] = []
        public var files: [UploadFile] = []
        /// Items left on the Mac, with the reason, for telling the user once the copy is done.
        public var skipped: [SkippedItem] = []
        /// The names the copy creates directly inside the destination folder.
        public var topLevelNames: [String] = []

        public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
        public var isEmpty: Bool { directories.isEmpty && files.isEmpty }

        /// "Keep Both": gives each named top-level item a new, unused name, so it lands beside
        /// what is already there instead of replacing it. "Kick.wav" becomes "Kick 2.wav" and the
        /// folder "Kit" becomes "Kit 2", with everything inside it going into the new folder.
        public func keepingBoth(_ names: [String], existingNames: [String], in directory: String) -> Upload {
            var plan = self
            var taken = Set((existingNames + topLevelNames).map { $0.lowercased() })
            for name in names {
                let oldPath = RemotePath.join(directory, name)
                let isFolder = plan.directories.contains(oldPath)
                let fresh = TransferPlan.numberedName(for: name, isFolder: isFolder) { !taken.contains($0.lowercased()) }
                taken.insert(fresh.lowercased())
                let newPath = RemotePath.join(directory, fresh)
                func moved(_ path: String) -> String {
                    if path == oldPath { return newPath }
                    if path.hasPrefix(oldPath + "/") { return newPath + path.dropFirst(oldPath.count) }
                    return path
                }
                plan.directories = plan.directories.map(moved)
                plan.files = plan.files.map { UploadFile(local: $0.local, remote: moved($0.remote), size: $0.size) }
                plan.topLevelNames = plan.topLevelNames.map { $0 == name ? fresh : $0 }
            }
            return plan
        }

        /// The plan without the named top-level items and everything inside them.
        public func removing(_ names: [String], in directory: String) -> Upload {
            guard !names.isEmpty else { return self }
            let roots = names.map { RemotePath.join(directory, $0) }
            var plan = self
            plan.files = files.filter { file in !roots.contains { RemotePath.isInside(file.remote, root: $0) } }
            plan.directories = directories.filter { folder in !roots.contains { RemotePath.isInside(folder, root: $0) } }
            plan.topLevelNames = topLevelNames.filter { !names.contains($0) }
            return plan
        }

        /// The plan without files that are already on the MPC and identical. A folder that already
        /// exists and has nothing left to receive is dropped too, as there is nothing to do there.
        public func leavingOut(identical: [String], existingFolders: [String]) -> Upload {
            guard !identical.isEmpty else { return self }
            let same = Set(identical)
            let present = Set(existingFolders)
            var plan = self
            plan.files = files.filter { !same.contains($0.remote) }
            plan.directories = directories.filter { folder in
                !present.contains(folder) || plan.files.contains { RemotePath.isInside($0.remote, root: folder) }
            }
            return plan
        }
    }

    /// Lists everything inside the given Mac files and folders, for copying into `remoteDirectory`.
    ///
    /// Only files the MPC can use are included (see `MPCFileTypes`), and only names the
    /// destination drive's format allows. Everything else is recorded in `skipped`. Nothing is
    /// renamed. A folder is only created when something inside it is being copied.
    public static func upload(items: [URL], into remoteDirectory: String, drive: Drive? = nil) -> Upload {
        var plan = Upload()
        let fileManager = FileManager.default

        enum Context { case ordinary, expansion, plugin }

        /// Returns true when the item, or something inside it, was added to the plan.
        func add(_ url: URL, remoteParent: String, shownAs: String, context: Context, topLevel: Bool) -> Bool {
            let name = remoteName(for: url)
            if isJunk(name) { return false }

            // A link dragged in directly is followed. Links inside a folder are left out, so a
            // loop can never be copied.
            let target = topLevel ? url.resolvingSymlinksInPath() : url
            guard let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey,
                                                                    .isSymbolicLinkKey, .fileSizeKey]) else {
                plan.skipped.append(SkippedItem(name: shownAs, reason: .unreadable))
                return false
            }
            let isDirectory = values.isDirectory == true
            if values.isSymbolicLink == true {
                plan.skipped.append(SkippedItem(name: shownAs, reason: .link))
                return false
            }
            guard isDirectory || values.isRegularFile == true else {
                plan.skipped.append(SkippedItem(name: shownAs, reason: .unreadable))
                return false
            }
            let nameProblem = drive?.problem(withName: name) ?? (RemotePath.isValidName(name) ? nil : "invalid")
            if nameProblem != nil {
                plan.skipped.append(SkippedItem(name: shownAs, isFolder: isDirectory, reason: .nameNotAllowed))
                return false
            }
            let remote = RemotePath.join(remoteParent, name)

            if isDirectory {
                let children = ((try? fileManager.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)) ?? [])
                    .filter { !isJunk($0.lastPathComponent) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                let childNames = Set(children.map { $0.lastPathComponent.lowercased() })
                var inner = context
                if inner != .plugin {
                    if childNames.contains(MPCFileTypes.pluginManifest) {
                        inner = .plugin
                    } else {
                        inner = childNames.contains(MPCFileTypes.expansionManifest) ? .expansion : .ordinary
                    }
                }
                // Reserve the folder's place so it comes before its contents, then drop it again
                // if nothing inside turned out to be worth copying.
                let slot = plan.directories.count
                plan.directories.append(remote)
                var copiedSomething = false
                for child in children {
                    if add(child, remoteParent: remote, shownAs: shownAs + "/" + child.lastPathComponent,
                           context: inner, topLevel: false) {
                        copiedSomething = true
                    }
                }
                if !copiedSomething && !children.isEmpty {
                    plan.directories.remove(at: slot)
                    return false
                }
                if topLevel { plan.topLevelNames.append(name) }
                return true
            }

            let compatible: Bool
            switch context {
            case .plugin: compatible = true
            case .expansion: compatible = MPCFileTypes.isCompatible(fileName: name) || MPCFileTypes.isExpansionFile(fileName: name)
            case .ordinary: compatible = MPCFileTypes.isCompatible(fileName: name)
            }
            guard compatible else {
                plan.skipped.append(SkippedItem(name: shownAs, reason: .unsupportedType))
                return false
            }
            let size = Int64(values.fileSize ?? 0)
            if let limit = drive?.maximumFileSize, size > limit {
                plan.skipped.append(SkippedItem(name: shownAs, reason: .tooLarge))
                return false
            }
            plan.files.append(UploadFile(local: target, remote: remote, size: size))
            if topLevel { plan.topLevelNames.append(name) }
            return true
        }

        for item in items {
            _ = add(item, remoteParent: remoteDirectory, shownAs: item.lastPathComponent, context: .ordinary, topLevel: true)
        }
        return plan
    }

    // MARK: What is already on the MPC

    /// What a copy to the MPC would collide with.
    public struct UploadConflicts: Equatable, Sendable {
        /// Items being copied whose names are already taken in the destination folder.
        public var names: [String] = []
        /// Files on the MPC that choosing Replace would overwrite, as full paths.
        /// For a folder that already exists this looks inside it, however deep the copy goes.
        public var filesToReplace: [String] = []
        /// Files in the plan that are already on the MPC holding exactly the same bytes, by the
        /// path they would be copied to. There is never any need to copy these again.
        public var identical: [String] = []
        /// True when a folder being copied meets a folder of the same name, which Replace merges.
        public var mergesFolders = false
        /// Every name already in the destination folder.
        public var existingNames: [String] = []
        /// Folders in the plan that already exist on the MPC.
        public var existingFolders: [String] = []

        public var isEmpty: Bool { names.isEmpty }

        /// Clashing items with nothing left to decide: every file in them is already on the MPC
        /// and identical, and every folder in them already exists.
        public func settledNames(in plan: Upload, directory: String) -> [String] {
            let same = Set(identical)
            let present = Set(existingFolders)
            return names.filter { name in
                let root = RemotePath.join(directory, name)
                let files = plan.files.filter { RemotePath.isInside($0.remote, root: root) }
                let folders = plan.directories.filter { RemotePath.isInside($0, root: root) }
                if files.isEmpty && folders.isEmpty { return false }
                return files.allSatisfy { same.contains($0.remote) } && folders.allSatisfy { present.contains($0) }
            }
        }
    }

    /// Looks at the destination to see what the copy would collide with, before anything is copied.
    ///
    /// Names are compared the way the drive compares them: exFAT, FAT32 and NTFS treat "Kick.wav"
    /// and "kick.wav" as the same file, ext4 does not.
    ///
    /// Where a file of the same name and size is already there, the two are compared by checksum,
    /// worked out on the MPC, so a file that is already across is recognised without sending it.
    public static func conflicts(for plan: Upload, in directory: String, drive: Drive?, fileSystem: RemoteFileSystem,
                                 control: CommandControl? = nil) throws -> UploadConflicts {
        let ignoresCase = drive?.usesWindowsNaming ?? true
        func key(_ name: String) -> String { ignoresCase ? name.lowercased() : name }

        var filesByFolder: [String: [UploadFile]] = [:]
        for file in plan.files { filesByFolder[RemotePath.parent(of: file.remote), default: []].append(file) }
        var foldersByFolder: [String: [String]] = [:]
        for folder in plan.directories { foldersByFolder[RemotePath.parent(of: folder), default: []].append(folder) }

        var result = UploadConflicts()
        var clashing = Set<String>()

        func visit(_ folder: String, topLevel: Bool) throws {
            if control?.isCancelled == true { throw SSHError(.cancelled) }
            let existing: [RemoteEntry]
            do {
                existing = try fileSystem.list(folder)
            } catch let error as RemoteFileError where error.kind == .folderMissing && !topLevel {
                return
            }
            if topLevel { result.existingNames = existing.map(\.name) }
            var byName: [String: RemoteEntry] = [:]
            for entry in existing { byName[key(entry.name)] = entry }

            // Same name and same size: worth asking the MPC for a checksum.
            var sameSize: [(planned: UploadFile, existing: RemoteEntry)] = []
            for file in filesByFolder[folder] ?? [] {
                let name = RemotePath.lastComponent(of: file.remote)
                guard let hit = byName[key(name)] else { continue }
                if topLevel { clashing.insert(name) }
                if hit.kind == .file, hit.size == file.size {
                    sameSize.append((file, hit))
                } else if hit.kind != .directory {
                    result.filesToReplace.append(hit.path)
                }
            }
            if !sameSize.isEmpty {
                let sums = try fileSystem.checksums(inFolder: folder, names: sameSize.map(\.existing.name), control: control)
                for pair in sameSize {
                    if let theirs = sums[pair.existing.name],
                       let ours = try? FileDigest.md5(of: pair.planned.local, isCancelled: { control?.isCancelled ?? false }),
                       theirs == ours {
                        result.identical.append(pair.planned.remote)
                    } else {
                        result.filesToReplace.append(pair.existing.path)
                    }
                }
                if control?.isCancelled == true { throw SSHError(.cancelled) }
            }

            for planned in foldersByFolder[folder] ?? [] {
                let name = RemotePath.lastComponent(of: planned)
                guard let hit = byName[key(name)] else { continue }
                if topLevel { clashing.insert(name) }
                if hit.kind == .directory {
                    result.mergesFolders = true
                    result.existingFolders.append(planned)
                    try visit(planned, topLevel: false)
                }
            }
        }

        try visit(directory, topLevel: true)
        result.names = plan.topLevelNames.filter { clashing.contains($0) }
        return result
    }

    // MARK: MPC to Mac

    public struct DownloadFile: Equatable, Sendable {
        public let remote: String
        public let local: URL
        public let size: Int64
    }

    public struct Download: Equatable, Sendable {
        /// Folders to create on the Mac, outermost first.
        public var directories: [URL] = []
        public var files: [DownloadFile] = []
        public var skipped: [SkippedItem] = []

        public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
        public var isEmpty: Bool { directories.isEmpty && files.isEmpty }
    }

    /// The first name of the form "Kick.wav", "Kick 2.wav", "Kick 3.wav"... that `isFree` accepts.
    /// The number goes before a file's extension. A folder's name is never split, so
    /// "Kit v1.2" becomes "Kit v1.2 2".
    public static func numberedName(for name: String, isFolder: Bool = false, isFree: (String) -> Bool) -> String {
        if isFree(name) { return name }
        var base = name
        var ext = ""
        if !isFolder, let dot = name.lastIndex(of: "."), dot != name.startIndex {
            base = String(name[name.startIndex..<dot])
            ext = String(name[dot...])
        }
        var number = 2
        while true {
            let candidate = "\(base) \(number)\(ext)"
            if isFree(candidate) { return candidate }
            number += 1
        }
    }

    /// A name that does not clash with anything in `directory`: "Kick.wav", then "Kick 2.wav", and so on.
    public static func availableURL(for name: String, isFolder: Bool = false, in directory: URL, taken: inout Set<String>) -> URL {
        let fileManager = FileManager.default
        let candidate = numberedName(for: name, isFolder: isFolder) { candidate in
            !taken.contains(candidate.lowercased())
                && !fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path)
        }
        taken.insert(candidate.lowercased())
        return directory.appendingPathComponent(candidate)
    }

    /// Lists everything inside the given MPC files and folders, for copying into a Mac folder.
    /// Nothing already on the Mac is replaced: a clashing name gets a number added.
    public static func download(entries: [RemoteEntry], into localDirectory: URL, fileSystem: RemoteFileSystem,
                                isCancelled: () -> Bool = { false }) throws -> Download {
        var plan = Download()
        var taken = Set<String>()

        func add(_ entry: RemoteEntry, local: URL, shownAs: String) throws {
            if isCancelled() { throw SSHError(.cancelled) }
            switch entry.kind {
            case .file:
                plan.files.append(DownloadFile(remote: entry.path, local: local, size: entry.size))
            case .directory:
                plan.directories.append(local)
                let children = try fileSystem.list(entry.path)
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                for child in children {
                    try add(child, local: local.appendingPathComponent(child.name), shownAs: shownAs + "/" + child.name)
                }
            case .link:
                plan.skipped.append(SkippedItem(name: shownAs, reason: .link))
            case .other:
                plan.skipped.append(SkippedItem(name: shownAs, reason: .unreadable))
            }
        }

        for entry in entries {
            try add(entry, local: availableURL(for: entry.name, isFolder: entry.isDirectory, in: localDirectory, taken: &taken),
                    shownAs: entry.name)
        }
        return plan
    }
}

// MARK: Copying one item out

public struct ExportResult: Equatable, Sendable {
    /// Where the file or folder landed on this Mac.
    public let url: URL
    public let files: Int
    public let bytes: Int64
    /// Links and special files inside a folder, which are never copied.
    public let skipped: [SkippedItem]
}

public extension RemoteFileSystem {
    /// Copies one file, or a folder and everything in it, from the MPC into a folder on this Mac.
    ///
    /// This only reads from the MPC. Nothing is created or changed there: every working file
    /// lives in `directory` on the Mac. Used for previews and for dragging items out of the window.
    func export(_ entry: RemoteEntry, into directory: URL, control: CommandControl? = nil,
                progress: ((_ done: Int64, _ total: Int64) -> Void)? = nil) throws -> ExportResult {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw RemoteFileError(.localFile, path: entry.path, detail: "A working folder could not be created on this Mac.")
        }
        let plan = try TransferPlan.download(entries: [entry], into: directory, fileSystem: self,
                                             isCancelled: { control?.isCancelled ?? false })
        let landed: URL
        if entry.kind == .directory, let top = plan.directories.first {
            landed = top
        } else if entry.kind == .file, let file = plan.files.first {
            landed = file.local
        } else {
            throw RemoteFileError(.unsupportedItem, path: entry.path)
        }
        let total = plan.totalBytes
        let outcome = downloadBatch(plan, control: control) { state in
            progress?(state.copiedBytes, state.totalBytes)
        }
        if outcome.cancelled { throw SSHError(.cancelled) }
        if let lost = outcome.connectionError { throw lost }
        if let reason = outcome.stoppedBecause { throw RemoteFileError(.localFile, path: entry.path, detail: reason) }
        if let first = outcome.failures.first {
            throw RemoteFileError(.other, path: entry.path, detail: "“\(first.name)” could not be copied. \(first.message)")
        }
        progress?(total, total)
        return ExportResult(url: landed, files: plan.files.count, bytes: total, skipped: plan.skipped)
    }
}
