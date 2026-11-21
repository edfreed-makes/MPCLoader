import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// File operations on the MPC's storage drives.
///
/// Every operation is checked twice. On the Mac, the path must sit inside one of the allowed
/// drives (see `StorageRules`). On the MPC, the script re-checks where the folder really is
/// after links are resolved, and for anything that changes files, that the drive is still
/// mounted. A path that fails either check is refused before anything is touched.
///
/// All methods block, so call them off the main thread.
public final class RemoteFileSystem: @unchecked Sendable {
    public let session: SSHSession
    private let lock = NSLock()
    private var snapshot = StorageRules.Snapshot()
    private var info = DeviceInfo()

    public init(session: SSHSession) {
        self.session = session
    }

    public var drives: [Drive] {
        lock.lock(); defer { lock.unlock() }
        return snapshot.drives
    }

    public var deviceInfo: DeviceInfo {
        lock.lock(); defer { lock.unlock() }
        return info
    }

    /// For tests: pretend the device lacks some commands, to exercise the fallbacks.
    func overrideCapabilities(hasStat: Bool, hasFindPlus: Bool) {
        lock.lock()
        info.hasStat = hasStat
        info.hasFindPlus = hasFindPlus
        lock.unlock()
    }

    // MARK: Scripts

    /// Shell functions shared by every script.
    /// `g ROOT DIR` stops the script unless DIR exists and really lives inside the drive ROOT.
    /// `m FIELD` stops the script unless the drive is still listed in /proc/mounts.
    static let prelude = """
    g() { gr=$(cd -- "$1" 2>/dev/null && pwd -P) || exit 41
    gd=$(cd -- "$2" 2>/dev/null && pwd -P) || exit 42
    case "$gd/" in "$gr"/*) return 0 ;; esac
    exit 43; }
    m() { grep -F -q -- " $1 " /proc/mounts 2>/dev/null || exit 44; }

    """

    /// A listing built from the shell alone, for a device with no usable `stat` command.
    /// It prints the same line format as `stat`, with the date left as 0 (unknown).
    static let plainListing = """
    for f in * .[!.]* ..?*; do
      if [ -L "$f" ]; then t=a1ff; elif [ -d "$f" ]; then t=41ed; elif [ -f "$f" ]; then t=81a4; elif [ -e "$f" ]; then t=1180; else continue; fi
      s=0
      if [ "$t" = 81a4 ]; then s=$(ls -ldn -- "$f" 2>/dev/null | { read -r p l u g z r; printf '%s' "$z"; }); fi
      case "$s" in ''|*[!0-9]*) s=0 ;; esac
      printf '%s|%s|0|./%s\\n' "$t" "$s" "$f"
    done

    """

    /// Shell that sets `n` to the size in bytes of the file named by the given variable.
    private func sizeCommand(of variable: String) -> String {
        deviceInfo.hasStat
            ? "n=$(stat -c %s -- \"$\(variable)\" 2>/dev/null)"
            : "n=$(wc -c < \"$\(variable)\")"
    }

    private func assign(_ variables: [(String, String)]) -> String {
        variables.map { "\($0.0)=\(Shell.quote($0.1))" }.joined(separator: "\n") + "\n"
    }

    // MARK: Connecting

    /// Logs in, asks the device what it is and reads its drives.
    @discardableResult
    public func connect() throws -> DeviceInfo {
        let result = try session.run(DeviceInfo.script, timeout: 30)
        let parsed = DeviceInfo.parse(result.text)
        guard parsed.complete else {
            throw SSHError(.other, result.stderr.isEmpty ? "The device gave an unexpected reply." : result.stderr)
        }
        lock.lock()
        info = parsed
        lock.unlock()
        try refreshDrives()
        return parsed
    }

    /// Re-reads which drives are mounted and how full they are.
    @discardableResult
    public func refreshDrives() throws -> [Drive] {
        let result = try session.run("cat /proc/mounts; echo '@@DF'; df -Pk 2>/dev/null", timeout: 30)
        let text = result.text
        guard let marker = text.range(of: "@@DF") else {
            throw SSHError(.other, "The MPC did not list its drives.")
        }
        let parsed = StorageRules.parse(mounts: String(text[text.startIndex..<marker.lowerBound]),
                                        df: String(text[marker.upperBound...]))
        lock.lock()
        snapshot = parsed
        lock.unlock()
        return parsed.drives
    }

    // MARK: Path rules

    /// Checks a path against the allowed drives and returns the drive it belongs to.
    /// - Parameter strictlyInside: the path must be below the drive's top folder, not the top folder itself.
    public func resolve(_ path: String, forWriting: Bool, strictlyInside: Bool) throws -> (drive: Drive, path: String) {
        guard let clean = RemotePath.normalise(path) else { throw RemoteFileError(.invalidName, path: path) }
        lock.lock()
        let current = snapshot
        lock.unlock()

        let candidates = current.drives.filter { RemotePath.isInside(clean, root: $0.mountPoint) }
        guard let drive = candidates.max(by: { $0.mountPoint.count < $1.mountPoint.count }) else {
            throw RemoteFileError(.notAllowed, path: clean)
        }
        for blocked in current.blockedMountPoints where RemotePath.isInside(clean, root: blocked) {
            throw RemoteFileError(.notAllowed, path: clean)
        }
        if strictlyInside, clean == drive.mountPoint { throw RemoteFileError(.notAllowed, path: clean) }
        if forWriting, !drive.isWritable { throw RemoteFileError(.readOnly, path: clean) }
        return (drive, clean)
    }

    private func check(_ result: CommandResult, path: String) throws {
        if result.status != 0 {
            throw RemoteFileError.from(status: result.status, path: path, stderr: result.stderr)
        }
    }

    // MARK: Reading

    /// Lists a folder. Links are listed but never followed.
    public func list(_ directory: String) throws -> [RemoteEntry] {
        let (drive, path) = try resolve(directory, forWriting: false, strictlyInside: false)
        let caps = deviceInfo
        var script = RemoteFileSystem.prelude + assign([("R", drive.mountPoint), ("D", path)])
        script += "g \"$R\" \"$D\"\ncd -- \"$D\" || exit 42\n"
        if caps.hasStat {
            let terminator = caps.hasFindPlus ? "+" : "\\;"
            script += "find . -mindepth 1 -maxdepth 1 -exec stat -c '\(ListingParser.statFormat)' -- {} \(terminator) 2>/dev/null\n"
        } else {
            script += RemoteFileSystem.plainListing
        }
        script += "exit 0\n"
        let result = try session.run(script, timeout: 300)
        try check(result, path: path)
        let entries = ListingParser.parseStat(result.text, directory: path)
        // Hide anything that is really another, blocked, mount point.
        lock.lock()
        let blocked = snapshot.blockedMountPoints
        lock.unlock()
        return entries.filter { entry in !blocked.contains(where: { RemotePath.isInside(entry.path, root: $0) }) }
    }

    // MARK: Changing

    /// Creates a folder. With `existingIsFine`, an existing folder of that name is not an error.
    public func makeDirectory(_ directory: String, existingIsFine: Bool = false) throws {
        let (drive, path) = try resolve(directory, forWriting: true, strictlyInside: true)
        var script = RemoteFileSystem.prelude
        script += assign([("R", drive.mountPoint), ("M", drive.rawMountField), ("D", RemotePath.parent(of: path)),
                          ("T", path), ("K", existingIsFine ? "1" : "0")])
        script += """
        g "$R" "$D"; m "$M"
        if [ "$K" = 1 ] && [ -d "$T" ] && [ ! -L "$T" ]; then exit 0; fi
        if [ -e "$T" ] || [ -L "$T" ]; then exit 45; fi
        mkdir -- "$T" || exit 46
        """
        try check(try session.run(script, timeout: 60), path: path)
    }

    /// Renames or moves an item within one drive.
    public func move(_ source: String, to destination: String) throws {
        let (drive, from) = try resolve(source, forWriting: true, strictlyInside: true)
        let (otherDrive, to) = try resolve(destination, forWriting: true, strictlyInside: true)
        guard drive.mountPoint == otherDrive.mountPoint else {
            throw RemoteFileError(.other, path: from, detail: "Items can only be moved within one drive.")
        }
        if from == to { return }
        if RemotePath.isInside(to, root: from) {
            throw RemoteFileError(.other, path: from, detail: "A folder can't be moved inside itself.")
        }
        var script = RemoteFileSystem.prelude
        script += assign([("R", drive.mountPoint), ("M", drive.rawMountField), ("D", RemotePath.parent(of: from)),
                          ("E", RemotePath.parent(of: to)), ("S", from), ("T", to)])
        script += """
        g "$R" "$D"; g "$R" "$E"; m "$M"
        [ -e "$S" ] || [ -L "$S" ] || exit 49
        if [ -e "$T" ] || [ -L "$T" ]; then
          if [ "$S" -ef "$T" ] && [ ! -L "$T" ] && [ ! -L "$S" ]; then
            mv -- "$S" "$S.mpcl-rename" || exit 46
            mv -- "$S.mpcl-rename" "$T" || exit 46
            exit 0
          fi
          exit 45
        fi
        mv -- "$S" "$T" || exit 46
        """
        try check(try session.run(script, timeout: 120), path: from)
    }

    /// Deletes a file, or a folder and everything in it. A link is removed without touching what it points to.
    public func delete(_ target: String) throws {
        let (drive, path) = try resolve(target, forWriting: true, strictlyInside: true)
        var script = RemoteFileSystem.prelude
        script += assign([("R", drive.mountPoint), ("M", drive.rawMountField), ("D", RemotePath.parent(of: path)),
                          ("T", path)])
        script += """
        g "$R" "$D"; m "$M"
        [ -e "$T" ] || [ -L "$T" ] || exit 49
        rm -rf -- "$T" || exit 46
        if [ -e "$T" ] || [ -L "$T" ]; then exit 46; fi
        """
        try check(try session.run(script, timeout: 1800), path: path)
    }

    /// Asks the MPC to finish writing everything to its drives.
    public func flush() {
        _ = try? session.run("sync", timeout: 300)
    }

    // MARK: Copying

    /// Copies one file from this Mac to the MPC.
    ///
    /// The file is written under a temporary name and only given its real name once the MPC
    /// confirms every byte arrived, so an interrupted copy never leaves a half-written sample.
    public func upload(localFile: URL, to remoteFile: String, replaceExisting: Bool,
                       control: CommandControl? = nil, progress: ((Int64) -> Void)? = nil) throws {
        let (drive, path) = try resolve(remoteFile, forWriting: true, strictlyInside: true)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: localFile)
        } catch {
            throw RemoteFileError(.localFile, path: path, detail: "“\(localFile.lastPathComponent)” could not be opened on this Mac.")
        }
        defer { try? handle.close() }
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            throw RemoteFileError(.localFile, path: path, detail: "“\(localFile.lastPathComponent)” is not an ordinary file.")
        }
        let size = Int64(status.st_size)

        var script = RemoteFileSystem.prelude
        script += assign([("R", drive.mountPoint), ("M", drive.rawMountField), ("D", RemotePath.parent(of: path)),
                          ("T", path), ("Z", String(size)), ("O", replaceExisting ? "1" : "0")])
        script += """
        g "$R" "$D"; m "$M"
        P="$D/.mpcl-$$.part"
        if [ -d "$T" ] && [ ! -L "$T" ]; then exit 48; fi
        if [ "$O" != 1 ]; then if [ -e "$T" ] || [ -L "$T" ]; then exit 45; fi; fi
        cat > "$P" || { rm -f -- "$P"; exit 46; }
        \(sizeCommand(of: "P"))
        n=$((n + 0))
        if [ "$n" != "$Z" ]; then rm -f -- "$P"; exit 47; fi
        mv -f -- "$P" "$T" || { rm -f -- "$P"; exit 46; }
        """
        let poller = OffsetPoller(descriptor: handle.fileDescriptor, progress: progress)
        poller.start()
        defer { poller.stop() }
        let result = try session.run(script, stdin: handle, timeout: nil, control: control)
        try check(result, path: path)
        progress?(size)
    }

    /// Copies one file from the MPC to this Mac. The local file appears only once it is complete.
    public func download(remoteFile: String, to localFile: URL, control: CommandControl? = nil,
                         progress: ((Int64) -> Void)? = nil) throws {
        let (drive, path) = try resolve(remoteFile, forWriting: false, strictlyInside: true)
        let fileManager = FileManager.default
        let partial = localFile.deletingLastPathComponent()
            .appendingPathComponent(".\(localFile.lastPathComponent).mpcl-part")
        try? fileManager.removeItem(at: partial)
        guard fileManager.createFile(atPath: partial.path, contents: nil),
              let handle = FileHandle(forWritingAtPath: partial.path) else {
            throw RemoteFileError(.localFile, path: path, detail: "“\(localFile.lastPathComponent)” could not be created on this Mac.")
        }
        var finished = false
        defer {
            try? handle.close()
            if !finished { try? fileManager.removeItem(at: partial) }
        }

        var script = RemoteFileSystem.prelude
        script += assign([("R", drive.mountPoint), ("D", RemotePath.parent(of: path)), ("T", path)])
        script += """
        g "$R" "$D"
        [ -e "$T" ] || [ -L "$T" ] || exit 49
        if [ -L "$T" ] || [ ! -f "$T" ]; then exit 48; fi
        \(sizeCommand(of: "T"))
        echo "mpcl.size=$((n + 0))" >&2
        cat -- "$T"
        """
        let poller = OffsetPoller(descriptor: handle.fileDescriptor, progress: progress)
        poller.start()
        defer { poller.stop() }
        let result = try session.run(script, stdout: handle, timeout: nil, control: control)
        try check(result, path: path)

        var expected: Int64?
        for line in result.stderr.split(whereSeparator: \.isNewline) where line.hasPrefix("mpcl.size=") {
            expected = Int64(line.dropFirst("mpcl.size=".count))
        }
        try? handle.synchronize()
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0, let expected, Int64(status.st_size) == expected else {
            throw RemoteFileError(.incomplete, path: path)
        }
        do {
            if fileManager.fileExists(atPath: localFile.path) { try fileManager.removeItem(at: localFile) }
            try fileManager.moveItem(at: partial, to: localFile)
        } catch {
            throw RemoteFileError(.localFile, path: path, detail: "“\(localFile.lastPathComponent)” could not be saved on this Mac.")
        }
        finished = true
        progress?(expected)
    }
}

/// Reports how far through a file a running copy has got.
///
/// ssh reads the upload from, or writes the download to, the same open file the app holds,
/// so the file's position is the number of bytes copied so far.
final class OffsetPoller: @unchecked Sendable {
    private let descriptor: Int32
    private let progress: ((Int64) -> Void)?
    private let lock = NSLock()
    private var running = false
    private var timer: DispatchSourceTimer?

    init(descriptor: Int32, progress: ((Int64) -> Void)?) {
        self.descriptor = descriptor
        self.progress = progress
    }

    func start() {
        guard let progress else { return }
        lock.lock()
        running = true
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer = source
        lock.unlock()
        source.schedule(deadline: .now() + 0.15, repeating: 0.15)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let active = self.running
            let position = active ? lseek(self.descriptor, 0, SEEK_CUR) : -1
            self.lock.unlock()
            if active, position >= 0 { progress(Int64(position)) }
        }
        source.resume()
    }

    func stop() {
        lock.lock()
        running = false
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }
}
