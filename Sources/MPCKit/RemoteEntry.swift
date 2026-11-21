import Foundation

/// One file or folder on the MPC.
public struct RemoteEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case directory
        case file
        /// A symbolic link. Shown, but never followed.
        case link
        case other
    }

    public let path: String
    public let name: String
    public let kind: Kind
    public let size: Int64
    public let modified: Date?

    public var id: String { path }
    public var isDirectory: Bool { kind == .directory }
    public var isHidden: Bool { name.hasPrefix(".") }

    public init(path: String, name: String, kind: Kind, size: Int64, modified: Date?) {
        self.path = path
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
    }

    /// The part of the name after the last dot, lower-cased. Empty for folders.
    public var fileExtension: String {
        kind == .file ? MPCFileTypes.fileExtension(of: name) : ""
    }

    /// A short description for the Kind column.
    public var kindDescription: String {
        switch kind {
        case .directory: return "Folder"
        case .link: return "Link"
        case .other: return "Special file"
        case .file: return RemoteEntry.describe(extension: fileExtension)
        }
    }

    static func describe(extension ext: String) -> String {
        if let known = MPCFileTypes.description(forExtension: ext) { return known }
        switch ext {
        case "m4a": return "M4A audio"
        case "json": return "JSON file"
        case "xml": return "XML file"
        case "txt": return "Text file"
        case "pdf": return "PDF document"
        case "png", "jpg", "jpeg": return "Image"
        case "zip": return "ZIP archive"
        case "so": return "Plugin program"
        case "": return "Document"
        default: return ext.uppercased() + " file"
        }
    }
}

/// Reads the directory listings the MPC sends back.
public enum ListingParser {
    /// The `stat` format the app asks for: mode in hex, size, modified time, name.
    public static let statFormat = "%f|%s|%Y|%n"

    static func kind(fromMode mode: UInt32) -> RemoteEntry.Kind {
        switch mode & 0xF000 {
        case 0x4000: return .directory
        case 0x8000: return .file
        case 0xA000: return .link
        default: return .other
        }
    }

    private static func parseStatLine(_ line: Substring) -> (kind: RemoteEntry.Kind, size: Int64, time: Int64, name: String)? {
        let fields = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count == 4, let mode = UInt32(fields[0], radix: 16), let size = Int64(fields[1]),
              let time = Int64(fields[2]) else { return nil }
        var name = String(fields[3])
        guard name.hasPrefix("./") else { return nil }
        name.removeFirst(2)
        guard !name.isEmpty else { return nil }
        return (kind(fromMode: mode), size, time, name)
    }

    /// Parses lines produced by `stat -c '%f|%s|%Y|%n' ./name ...` run inside `directory`.
    /// A modified time of 0 means "not known" (the fallback listing cannot read dates).
    /// With `recursive` the names may contain slashes (output of a whole-tree listing).
    public static func parseStat(_ output: String, directory: String, recursive: Bool = false) -> [RemoteEntry] {
        var entries: [RemoteEntry] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let parsed = parseStatLine(line) else { continue }
            let valid = recursive
                ? parsed.name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { RemotePath.isValidName(String($0)) }
                : RemotePath.isValidName(parsed.name)
            // A name the app could not safely pass back to the MPC is left out.
            guard valid else { continue }
            let shown = recursive ? RemotePath.lastComponent(of: parsed.name) : parsed.name
            entries.append(RemoteEntry(path: RemotePath.join(directory, parsed.name), name: shown, kind: parsed.kind,
                                       size: parsed.kind == .file ? parsed.size : 0,
                                       modified: parsed.time > 0 ? Date(timeIntervalSince1970: TimeInterval(parsed.time)) : nil))
        }
        return entries
    }
}
