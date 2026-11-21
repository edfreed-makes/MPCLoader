import Foundation

/// Quoting for the POSIX shell on the MPC.
public enum Shell {
    /// Wraps a string in single quotes so the remote shell treats it as one literal word.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Helpers for absolute paths on the MPC. Paths are plain strings with `/` separators.
public enum RemotePath {
    /// True when `name` is usable as a single file or folder name.
    public static func isValidName(_ name: String) -> Bool {
        if name.isEmpty || name == "." || name == ".." { return false }
        if name.utf8.count > 255 { return false }
        for scalar in name.unicodeScalars {
            if scalar == "/" || scalar.value < 0x20 || scalar.value == 0x7F { return false }
        }
        return true
    }

    /// Returns the path with duplicate and trailing slashes removed.
    /// Returns nil for anything that is not a clean absolute path: relative paths,
    /// paths with `.` or `..` components, and paths with control characters.
    public static func normalise(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            let name = String(part)
            guard isValidName(name) else { return nil }
            parts.append(name)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// True when `path` is `root` itself or lies below it. Both must already be normalised.
    public static func isInside(_ path: String, root: String) -> Bool {
        if root == "/" { return true }
        return path == root || path.hasPrefix(root + "/")
    }

    public static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    public static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "/" }
        let head = String(path[path.startIndex..<slash])
        return head.isEmpty ? "/" : head
    }

    public static func lastComponent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// The components of `path` below `root`, for building a breadcrumb.
    public static func components(of path: String, below root: String) -> [String] {
        guard isInside(path, root: root), path != root else { return [] }
        let tail = path.dropFirst(root == "/" ? 1 : root.count + 1)
        return tail.split(separator: "/").map(String.init)
    }
}
