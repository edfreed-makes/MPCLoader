import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Lets another thread stop the commands that are running under it.
/// One control can cover several commands at once, which is how a copy of many files is cancelled.
public final class CommandControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var processes: [ObjectIdentifier: Process] = [:]

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let running = Array(processes.values)
        lock.unlock()
        for process in running where process.isRunning { process.terminate() }
    }

    func attach(_ process: Process) {
        lock.lock()
        processes[ObjectIdentifier(process)] = process
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled, process.isRunning { process.terminate() }
    }

    func detach(_ process: Process) {
        lock.lock()
        processes[ObjectIdentifier(process)] = nil
        lock.unlock()
    }
}

public struct CommandResult: Sendable {
    /// Exit status of the script on the MPC.
    public let status: Int32
    public let stdout: Data
    public let stderr: String

    public var text: String { String(decoding: stdout, as: UTF8.self) }
}

/// Runs shell commands on the MPC through this Mac's own `ssh` program.
///
/// This is the same method Akai's SDK tool uses: `root` with no password by default, one shared
/// connection reused for every command, and the password (when there is one) handed to ssh
/// through a helper script so it never appears in a command line.
public final class SSHSession: @unchecked Sendable {
    public struct Settings: Equatable, Sendable {
        public var host: String
        public var port: Int
        public var user: String
        /// nil or empty means "no password", which is how an MPC in developer mode ships.
        public var password: String?

        public static let defaultUser = "root"
        public static let defaultPort = 22

        public init(host: String, port: Int = Settings.defaultPort, user: String = Settings.defaultUser,
                    password: String? = nil) {
            self.host = host
            self.port = port
            self.user = user
            self.password = password
        }

        var effectivePassword: String? {
            guard let password, !password.isEmpty else { return nil }
            return password
        }
    }

    public let settings: Settings
    private let sshPath: String
    private let multiplex: Bool
    private let connectTimeout: Int
    private let lock = NSLock()
    private var workDirectory: String?
    private var counter = 0

    public static let defaultSSHPath = "/usr/bin/ssh"

    public init(settings: Settings, sshPath: String = SSHSession.defaultSSHPath, multiplex: Bool = true,
                connectTimeout: Int = 8) {
        self.settings = settings
        self.sshPath = sshPath
        self.multiplex = multiplex
        self.connectTimeout = connectTimeout
    }

    deinit {
        close()
    }

    /// A user or host starting with `-` would be read by ssh as an option. Refuse those.
    public static func isValidHost(_ host: String) -> Bool {
        if host.isEmpty || host.hasPrefix("-") || host.utf8.count > 253 { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:%")
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public static func isValidUser(_ user: String) -> Bool {
        if user.isEmpty || user.hasPrefix("-") || user.utf8.count > 64 { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return user.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    // MARK: Working directory

    /// A private folder in /tmp for the shared-connection socket and the password helper.
    /// /tmp keeps the socket path short, which Unix sockets need.
    private func ensureWorkDirectory() throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let workDirectory { return workDirectory }
        var template = Array("/tmp/mpcl-XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else {
            throw SSHError(.other, "Could not create a working folder in /tmp.")
        }
        let path = String(cString: template)
        chmod(path, 0o700)
        workDirectory = path
        return path
    }

    private func nextScratchName(_ suffix: String) -> String {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        return "c\(counter).\(suffix)"
    }

    private func askpassScript(in directory: String) throws -> String {
        let path = directory + "/askpass.sh"
        if !FileManager.default.fileExists(atPath: path) {
            let body = "#!/bin/sh\nprintf '%s\\n' \"$MPCL_ASKPASS_PW\"\n"
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            chmod(path, 0o700)
        }
        return path
    }

    // MARK: Command line

    /// The full argument list for ssh. Exposed so tests can check it.
    public func arguments(remoteCommand: String, controlPath: String?) -> [String] {
        var args = [
            "-F", "/dev/null",
            "-p", String(settings.port),
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=4",
            "-o", "NumberOfPasswordPrompts=1",
            // ssh marks file copies as background traffic, which some Wi-Fi routers hold back when
            // the network is busy. "none" leaves the traffic at normal priority.
            "-o", "IPQoS=none",
        ]
        if settings.effectivePassword == nil {
            args += ["-o", "BatchMode=yes"]
        } else {
            // Go straight to the password: offering keys first can use up the MPC's login attempts.
            args += ["-o", "PreferredAuthentications=password,keyboard-interactive",
                     "-o", "PubkeyAuthentication=no"]
        }
        if let controlPath {
            args += ["-o", "ControlMaster=auto", "-o", "ControlPath=\(controlPath)", "-o", "ControlPersist=120"]
        }
        args += ["-l", settings.user, "--", settings.host, remoteCommand]
        return args
    }

    private func environment(workDirectory: String) throws -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let password = settings.effectivePassword {
            env["MPCL_ASKPASS_PW"] = password
            env["SSH_ASKPASS"] = try askpassScript(in: workDirectory)
            env["SSH_ASKPASS_REQUIRE"] = "force"
            if env["DISPLAY"] == nil { env["DISPLAY"] = ":0" }
        }
        return env
    }

    // MARK: Running

    /// Runs a shell script on the MPC and waits for it.
    ///
    /// - Parameters:
    ///   - stdin: a file to feed to the script. Used for uploads.
    ///   - stdout: a file to receive the script's output. Used for downloads. When nil the output
    ///     is returned in the result.
    ///   - timeout: seconds before the command is abandoned. nil waits for as long as it takes.
    /// - Throws: `SSHError` when the connection fails. A script that runs and exits non-zero is
    ///   not an error here: check `status`.
    public func run(_ script: String, stdin: FileHandle? = nil, stdout: FileHandle? = nil,
                    timeout: TimeInterval? = 60, control: CommandControl? = nil) throws -> CommandResult {
        guard SSHSession.isValidHost(settings.host) else { throw SSHError(.dns, "That address is not valid.") }
        guard SSHSession.isValidUser(settings.user) else { throw SSHError(.auth, "That user name is not valid.") }
        if let control, control.isCancelled { throw SSHError(.cancelled) }

        let directory = try ensureWorkDirectory()
        let fileManager = FileManager.default

        // Output goes to scratch files rather than pipes: nothing to drain, nothing to deadlock on.
        let errPath = directory + "/" + nextScratchName("err")
        let outPath = directory + "/" + nextScratchName("out")
        _ = fileManager.createFile(atPath: errPath, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? fileManager.removeItem(atPath: errPath) }
        guard let errHandle = FileHandle(forWritingAtPath: errPath) else {
            throw SSHError(.other, "Could not create a scratch file in /tmp.")
        }
        defer { try? errHandle.close() }

        var outHandle: FileHandle?
        if stdout == nil {
            _ = fileManager.createFile(atPath: outPath, contents: nil, attributes: [.posixPermissions: 0o600])
            outHandle = FileHandle(forWritingAtPath: outPath)
            if outHandle == nil { throw SSHError(.other, "Could not create a scratch file in /tmp.") }
        }
        defer {
            try? outHandle?.close()
            try? fileManager.removeItem(atPath: outPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = arguments(remoteCommand: "sh -c " + Shell.quote(script),
                                      controlPath: multiplex ? directory + "/cm" : nil)
        process.environment = try environment(workDirectory: directory)
        process.standardInput = stdin ?? FileHandle.nullDevice
        process.standardOutput = stdout ?? outHandle!
        process.standardError = errHandle

        do {
            try process.run()
        } catch {
            throw SSHError(.noClient, error.localizedDescription)
        }
        control?.attach(process)
        defer { control?.detach(process) }

        let timedOut = TimeoutFlag()
        var timer: DispatchWorkItem?
        if let timeout {
            let item = DispatchWorkItem { [weak process] in
                guard let process, process.isRunning else { return }
                timedOut.set()
                process.terminate()
            }
            timer = item
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
        }
        process.waitUntilExit()
        timer?.cancel()

        let errText = (try? String(contentsOfFile: errPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let control, control.isCancelled { throw SSHError(.cancelled) }
        if timedOut.isSet { throw SSHError(.timeout, errText) }
        if process.terminationReason == .uncaughtSignal {
            throw SSHError(.closed, errText)
        }
        let status = process.terminationStatus
        // ssh itself exits with 255 when the connection fails.
        if status == 255 {
            throw SSHError(SSHError.classify(stderr: errText), errText)
        }
        let output = stdout == nil ? (fileManager.contents(atPath: outPath) ?? Data()) : Data()
        return CommandResult(status: status, stdout: output, stderr: errText)
    }

    /// Closes the shared connection and removes the working folder.
    public func close() {
        lock.lock()
        let directory = workDirectory
        workDirectory = nil
        lock.unlock()
        guard let directory else { return }

        let socket = directory + "/cm"
        if multiplex, FileManager.default.fileExists(atPath: socket) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: sshPath)
            process.arguments = ["-F", "/dev/null", "-S", socket, "-O", "exit", "mpc"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil {
                let deadline = Date().addingTimeInterval(5)
                while process.isRunning, Date() < deadline { usleep(20_000) }
                if process.isRunning { process.terminate() }
            }
        }
        try? FileManager.default.removeItem(atPath: directory)
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
