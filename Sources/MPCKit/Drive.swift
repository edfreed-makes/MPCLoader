import Foundation

/// One storage volume on the MPC that the app is allowed to show.
public struct Drive: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        /// The MPC's built-in user storage (Browser > Places > Internal).
        case internalStorage
        /// SD cards, USB drives and a fitted SATA drive.
        case removable
        /// Factory sounds and synth content. Shown read-only.
        case factoryContent
    }

    public enum Access: String, Sendable {
        case readWrite
        case readOnly
    }

    /// Where the drive is mounted, for example `/media/MY USB`.
    public let mountPoint: String
    /// The mount point exactly as `/proc/mounts` spells it (spaces appear as `\040`).
    public let rawMountField: String
    public let device: String
    public let fileSystem: String
    public let options: [String]
    public let kind: Kind
    public let access: Access
    public var totalBytes: Int64?
    public var freeBytes: Int64?

    public var id: String { mountPoint }

    /// The volume name: the last part of the mount point.
    public var name: String { RemotePath.lastComponent(of: mountPoint) }

    /// The name shown in the sidebar.
    public var displayName: String {
        switch kind {
        case .internalStorage:
            return "Internal Storage"
        case .factoryContent:
            if name.hasPrefix("acvs-synths") { return "Factory Synths" }
            return "Factory Content"
        case .removable:
            return name
        }
    }

    public var isWritable: Bool { access == .readWrite }
}

/// The rules for which parts of the MPC the app may touch.
///
/// These follow Akai's own SDK tool (`tools/mpc_remote.py` in mpc-plugin-builder-sdk):
/// user storage is whatever is mounted at `/nvme` or under `/media/`. On top of that the
/// app refuses the partitions the MPC needs in order to run.
public enum StorageRules {
    /// The internal NVMe drive on MPC Live III, MPC XL and later.
    public static let nvmeMount = "/nvme"
    public static let mediaPrefix = "/media/"

    /// Pseudo filesystems are never storage. Same list as Akai's SDK tool.
    static let ignoredFileSystems: Set<String> = ["tmpfs", "proc", "sysfs", "devtmpfs", "devpts"]

    public enum Verdict: Equatable, Sendable {
        case allowed(Drive.Kind)
        /// The MPC's own system data. Never shown, never touched.
        case system
        /// Not a storage location at all.
        case notStorage
    }

    /// Decides what a mount point is.
    public static func classify(mountPoint: String) -> Verdict {
        if mountPoint == nvmeMount { return .allowed(.internalStorage) }
        guard mountPoint.hasPrefix(mediaPrefix) else { return .notStorage }
        let name = RemotePath.lastComponent(of: mountPoint)
        if name.isEmpty { return .notStorage }

        // The internal user storage. Akai's SDK calls this "the internal user-content storage".
        if name.hasPrefix("az01-internal-sd") { return .allowed(.internalStorage) }
        // `az01-internal` is the MPC's system data partition. It holds the live /etc and /var
        // (passwords, Wi-Fi, SSH keys, services). Deleting there can stop the MPC working.
        // Anything else carrying the az01-internal name is treated the same way to be safe.
        if name.hasPrefix("az01-internal") { return .system }
        // Factory sounds and plugin content. Useful to copy from, harmful to delete.
        if name.hasPrefix("acvs-synths") || name.hasPrefix("acvs-content") { return .allowed(.factoryContent) }
        if name.hasPrefix("nvme") { return .allowed(.internalStorage) }
        return .allowed(.removable)
    }

    /// Turns the octal escapes used in `/proc/mounts` (`\040` for a space) back into characters.
    public static func unescapeMountField(_ field: String) -> String {
        var bytes: [UInt8] = []
        let source = Array(field.utf8)
        var index = 0
        while index < source.count {
            if source[index] == UInt8(ascii: "\\"), index + 3 < source.count,
               let value = UInt8(String(decoding: source[(index + 1)...(index + 3)], as: UTF8.self), radix: 8) {
                bytes.append(value)
                index += 4
            } else {
                bytes.append(source[index])
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public struct Snapshot: Equatable, Sendable {
        /// Drives the app may show, internal storage first.
        public var drives: [Drive]
        /// Mount points the app must refuse even if they sit inside an allowed drive.
        public var blockedMountPoints: [String]

        public init(drives: [Drive] = [], blockedMountPoints: [String] = []) {
            self.drives = drives
            self.blockedMountPoints = blockedMountPoints
        }
    }

    /// Builds the list of drives from the output of `cat /proc/mounts` and `df -Pk`.
    public static func parse(mounts: String, df: String) -> Snapshot {
        var drives: [Drive] = []
        var blocked: [String] = []
        var seen = Set<String>()

        for line in mounts.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 4 else { continue }
            let rawMount = parts[1]
            let mount = unescapeMountField(rawMount)
            guard let clean = RemotePath.normalise(mount), clean == mount else { continue }

            switch classify(mountPoint: mount) {
            case .notStorage:
                continue
            case .system:
                blocked.append(mount)
            case .allowed(let kind):
                if ignoredFileSystems.contains(parts[2]) {
                    // A RAM disk under /media is not a drive. Refuse it so nothing fills the MPC's memory.
                    blocked.append(mount)
                    continue
                }
                guard !seen.contains(mount) else { continue }
                seen.insert(mount)
                let options = parts[3].split(separator: ",").map(String.init)
                let mountedWritable = options.contains("rw")
                let access: Drive.Access = (kind == .factoryContent || !mountedWritable) ? .readOnly : .readWrite
                drives.append(Drive(mountPoint: mount, rawMountField: rawMount, device: parts[0],
                                    fileSystem: parts[2], options: options, kind: kind, access: access,
                                    totalBytes: nil, freeBytes: nil))
            }
        }

        // A mount nested inside another drive is only reachable as its own drive.
        // If it is not an allowed drive it is blocked outright.
        let allowed = Set(drives.map(\.mountPoint))
        blocked = blocked.filter { !allowed.contains($0) }

        for line in df.split(whereSeparator: \.isNewline).dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 6, let total = Int64(parts[1]), let free = Int64(parts[3]) else { continue }
            let mount = parts[5...].joined(separator: " ")
            if let index = drives.firstIndex(where: { $0.mountPoint == mount }) {
                drives[index].totalBytes = total * 1024
                drives[index].freeBytes = free * 1024
            }
        }

        drives.sort { lhs, rhs in
            if lhs.kind != rhs.kind { return order(lhs.kind) < order(rhs.kind) }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        return Snapshot(drives: drives, blockedMountPoints: blocked.sorted())
    }

    private static func order(_ kind: Drive.Kind) -> Int {
        switch kind {
        case .internalStorage: return 0
        case .removable: return 1
        case .factoryContent: return 2
        }
    }
}

// MARK: Naming rules

/// An MPC formats its drives as exFAT, and also reads and writes FAT32, NTFS and ext4.
/// exFAT, FAT32 and NTFS share the Windows rules for what a file may be called.
public extension Drive {
    /// Characters that exFAT, FAT32 and NTFS refuse in a name.
    static let windowsForbiddenCharacters: Set<Character> = ["\"", "*", ":", "<", ">", "?", "\\", "|"]

    var usesWindowsNaming: Bool {
        ["exfat", "vfat", "msdos", "ntfs", "ntfs3", "fuseblk"].contains(fileSystem.lowercased())
    }

    /// The largest single file the drive can hold, when it has a limit. FAT32 stops at 4 GB.
    var maximumFileSize: Int64? {
        ["vfat", "msdos"].contains(fileSystem.lowercased()) ? 4_294_967_295 : nil
    }

    /// The drive's format in everyday terms.
    var formatDescription: String {
        switch fileSystem.lowercased() {
        case "exfat": return "exFAT"
        case "vfat", "msdos": return "FAT32"
        case "ntfs", "ntfs3": return "NTFS"
        case "hfsplus", "hfs": return "Mac OS Extended"
        case "ext2", "ext3", "ext4": return fileSystem.lowercased()
        case "fuseblk": return "NTFS or exFAT"
        default: return fileSystem
        }
    }

    /// Why a name can't be used on this drive, or nil when it is fine.
    func problem(withName name: String) -> String? {
        if name.isEmpty { return "Type a name." }
        if !RemotePath.isValidName(name) { return "Names can't contain a slash." }
        guard usesWindowsNaming else { return nil }
        if name.contains(where: { Drive.windowsForbiddenCharacters.contains($0) }) {
            return "This drive is formatted as \(formatDescription), which doesn't allow \" * : < > ? \\ | in names."
        }
        if name.hasSuffix(" ") || name.hasSuffix(".") {
            return "On this drive a name can't end with a space or a full stop."
        }
        return nil
    }
}
