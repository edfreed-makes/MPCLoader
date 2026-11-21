import Foundation

/// Why a file operation on the MPC did not happen.
public struct RemoteFileError: Error, Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// The path is outside the drives the app is allowed to touch.
        case notAllowed
        case invalidName
        case readOnly
        /// The drive was removed or is no longer mounted.
        case driveGone
        case folderMissing
        case notFound
        case alreadyExists
        /// The item is a link or a special file, which the app does not copy.
        case unsupportedItem
        case noSpace
        /// The copy arrived incomplete.
        case incomplete
        case writeFailed
        case localFile
        case other
    }

    public let kind: Kind
    public let path: String
    public let detail: String

    public init(_ kind: Kind, path: String = "", detail: String = "") {
        self.kind = kind
        self.path = path
        self.detail = detail
    }

    /// Maps the exit codes used by the app's own scripts to error kinds.
    static func from(status: Int32, path: String, stderr: String) -> RemoteFileError {
        let lower = stderr.lowercased()
        if lower.contains("no space left") { return RemoteFileError(.noSpace, path: path, detail: stderr) }
        if lower.contains("read-only file system") { return RemoteFileError(.readOnly, path: path, detail: stderr) }
        switch status {
        case 41, 44: return RemoteFileError(.driveGone, path: path, detail: stderr)
        case 42: return RemoteFileError(.folderMissing, path: path, detail: stderr)
        case 43: return RemoteFileError(.notAllowed, path: path, detail: stderr)
        case 45: return RemoteFileError(.alreadyExists, path: path, detail: stderr)
        case 46: return RemoteFileError(.writeFailed, path: path, detail: stderr)
        case 47: return RemoteFileError(.incomplete, path: path, detail: stderr)
        case 48: return RemoteFileError(.unsupportedItem, path: path, detail: stderr)
        case 49: return RemoteFileError(.notFound, path: path, detail: stderr)
        default: return RemoteFileError(.other, path: path, detail: stderr.isEmpty ? "The MPC reported error \(status)." : stderr)
        }
    }
}

extension RemoteFileError: LocalizedError {
    public var errorDescription: String? {
        let name = path.isEmpty ? "that item" : "“\(RemotePath.lastComponent(of: path))”"
        switch kind {
        case .notAllowed:
            return "\(name.capitalisedFirst) is outside the MPC's storage drives, so MPC Loader will not touch it."
        case .invalidName:
            return "That name can't be used. Names can't be empty or contain a slash."
        case .readOnly:
            return "This drive is read-only, so nothing on it can be changed."
        case .driveGone:
            return "The drive is no longer connected to the MPC."
        case .folderMissing:
            return "The folder no longer exists on the MPC."
        case .notFound:
            return "\(name.capitalisedFirst) no longer exists on the MPC."
        case .alreadyExists:
            return "Something called \(name) already exists there."
        case .unsupportedItem:
            return "\(name.capitalisedFirst) is a link or special file, which can't be copied."
        case .noSpace:
            return "The drive is full."
        case .incomplete:
            return "\(name.capitalisedFirst) did not copy completely, so the partial copy was removed."
        case .writeFailed:
            let reason = detail.isEmpty ? "" : " (\(detail))"
            return "The MPC could not save \(name)\(reason). The drive may not allow that name."
        case .localFile:
            return detail.isEmpty ? "The file on this Mac could not be read or written." : detail
        case .other:
            return detail.isEmpty ? "The MPC reported a problem with \(name)." : detail
        }
    }
}

private extension String {
    var capitalisedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
