import SwiftUI
import AppKit
import MPCKit

/// Everything the window shows: the connection, the drives, the open folder and any copy in progress.
@MainActor
final class AppModel: ObservableObject {
    enum ConnectionState {
        case disconnected
        case connecting
        case connected
    }

    /// Why connecting failed, in plain words, with what to do about it.
    struct Problem: Equatable {
        var title: String
        var message: String
        var showsDeveloperModeHelp = false
        var offersConnectAnyway = false
    }

    enum SearchState: Equatable {
        case idle
        case searching
        case found([DiscoveredDevice])
        case nothing
    }

    struct TransferStatus: Equatable {
        var toMPC: Bool
        var preparing = true
        var currentName = ""
        var completedFiles = 0
        var totalFiles = 0
        var completedBytes: Int64 = 0
        var totalBytes: Int64 = 0

        var fraction: Double {
            totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : (totalFiles > 0 ? Double(completedFiles) / Double(totalFiles) : 0)
        }
    }

    struct Failure: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let message: String
    }

    /// What to tell the user once a copy has finished.
    struct TransferReport: Identifiable {
        let id = UUID()
        var toMPC: Bool
        var destination: String
        var copiedFiles: Int
        var plannedFiles: Int
        var cancelled = false
        var stoppedBecause: String?
        var skipped: [SkippedItem] = []
        var failures: [Failure] = []
        var driveFormat = ""
        var revealURLs: [URL] = []

        var needsAttention: Bool {
            cancelled || stoppedBecause != nil || !skipped.isEmpty || !failures.isEmpty
        }
    }

    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    struct ConflictQuestion: Identifiable {
        let id = UUID()
        let names: [String]
    }

    enum ConflictAnswer {
        case replace
        case skip
        case cancel
    }

    // MARK: Connection settings

    @Published var host: String { didSet { defaults.set(host, forKey: "host") } }
    @Published var user: String { didSet { defaults.set(user, forKey: "user") } }
    @Published var portText: String { didSet { defaults.set(portText, forKey: "port") } }
    @Published var password: String = ""

    // MARK: State

    @Published private(set) var state: ConnectionState = .disconnected
    @Published var problem: Problem?
    @Published private(set) var search: SearchState = .idle
    @Published private(set) var deviceInfo: DeviceInfo?
    @Published private(set) var drives: [Drive] = []
    @Published private(set) var currentDrive: Drive?
    @Published private(set) var currentPath: String?
    @Published private(set) var entries: [RemoteEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var folderError: String?
    @Published var selection = Set<RemoteEntry.ID>()
    @Published var sortOrder: [KeyPathComparator<RemoteEntry>] = [KeyPathComparator(\RemoteEntry.name, comparator: .localizedStandard)]
    @Published var searchText = ""
    @Published var showHidden: Bool { didSet { defaults.set(showHidden, forKey: "showHidden") } }
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    @Published private(set) var transfer: TransferStatus?
    @Published private(set) var lastSummary: String?
    @Published private(set) var lastRevealURLs: [URL] = []
    @Published var report: TransferReport?
    @Published var notice: Notice?
    @Published var conflict: ConflictQuestion?
    @Published private(set) var isBusy = false

    // Dialogs the window shows. They live here so menu commands can open them too.
    @Published var isNamingNewFolder = false
    @Published var renaming: RemoteEntry?
    @Published var deleting: [RemoteEntry]?

    private let defaults = UserDefaults.standard
    private let browseWorker = Worker("mpcloader.browse")
    private let transferWorker = Worker("mpcloader.transfer")
    private var session: SSHSession?
    private var fileSystem: RemoteFileSystem?
    private var generation = 0
    private var loadToken = UUID()
    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private var transferControl: CommandControl?
    private var conflictContinuation: CheckedContinuation<ConflictAnswer, Never>?
    private var monitor: Timer?
    private var monitorRunning = false
    private var searchGeneration = 0

    init() {
        host = defaults.string(forKey: "host") ?? ""
        user = defaults.string(forKey: "user") ?? SSHSession.Settings.defaultUser
        portText = defaults.string(forKey: "port") ?? String(SSHSession.Settings.defaultPort)
        showHidden = defaults.bool(forKey: "showHidden")
        if !host.isEmpty {
            password = Keychain.password(account: keychainAccount) ?? ""
        }
    }

    // MARK: Derived values

    var isConnected: Bool { state == .connected }
    var port: Int { Int(portText.trimmingCharacters(in: .whitespaces)) ?? SSHSession.Settings.defaultPort }
    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUser: String {
        let value = user.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? SSHSession.Settings.defaultUser : value
    }
    private var keychainAccount: String { "\(trimmedUser)@\(trimmedHost)" }

    var usesDefaultLogin: Bool {
        trimmedUser == SSHSession.Settings.defaultUser && password.isEmpty && port == SSHSession.Settings.defaultPort
    }

    var canWriteHere: Bool {
        isConnected && currentPath != nil && currentDrive?.isWritable == true && transfer == nil && !isBusy
    }

    var canCopy: Bool { isConnected && transfer == nil && !isBusy }

    /// The open folder's contents as shown: filtered and sorted.
    var visibleEntries: [RemoteEntry] {
        var items = entries.filter { entry in
            if entry.name.hasPrefix(".mpcl-") { return false }
            if !showHidden && entry.isHidden { return false }
            return true
        }
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            items = items.filter { $0.name.localizedCaseInsensitiveContains(needle) }
        }
        return items.sorted(using: sortOrder)
    }

    var selectedEntries: [RemoteEntry] {
        entries.filter { selection.contains($0.id) }
    }

    var deviceName: String { deviceInfo?.displayName ?? "MPC" }

    var windowSubtitle: String {
        switch state {
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting to \(trimmedHost)…"
        case .connected:
            var parts = ["Connected to \(deviceName)"]
            if let firmware = deviceInfo?.firmware, !firmware.isEmpty { parts.append("MPC OS \(firmware)") }
            parts.append(trimmedHost)
            return parts.joined(separator: " · ")
        }
    }

    struct Crumb: Identifiable, Equatable {
        let name: String
        let path: String
        var id: String { path }
    }

    /// The folder names from the drive down to the open folder, with the path each one leads to.
    var breadcrumb: [Crumb] {
        guard let drive = currentDrive, let path = currentPath else { return [] }
        var crumbs = [Crumb(name: drive.displayName, path: drive.mountPoint)]
        var walking = drive.mountPoint
        for component in RemotePath.components(of: path, below: drive.mountPoint) {
            walking = RemotePath.join(walking, component)
            crumbs.append(Crumb(name: component, path: walking))
        }
        return crumbs
    }

    // MARK: Finding the MPC

    /// Looks for MPCs on the local network and fills in the address when exactly one turns up.
    func findMPC(fillOnlyIfEmpty: Bool = false) {
        guard search != .searching else { return }
        search = .searching
        searchGeneration += 1
        let token = searchGeneration
        let searchPort = port
        let searchUser = trimmedUser
        Task {
            let devices = await withCheckedContinuation { (continuation: CheckedContinuation<[DiscoveredDevice], Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Discovery.search(port: searchPort, user: searchUser))
                }
            }
            guard token == searchGeneration else { return }
            search = devices.isEmpty ? .nothing : .found(devices)
            let mpcs = devices.filter(\.isMPC)
            if mpcs.count == 1, state == .disconnected, !fillOnlyIfEmpty || trimmedHost.isEmpty {
                host = mpcs[0].address
            }
        }
    }

    func use(_ device: DiscoveredDevice) {
        host = device.address
        problem = nil
    }

    func resetLoginToDefaults() {
        user = SSHSession.Settings.defaultUser
        portText = String(SSHSession.Settings.defaultPort)
        password = ""
    }

    // MARK: Connecting

    func connect(skipIdentityCheck: Bool = false) {
        guard state == .disconnected else { return }
        let address = trimmedHost
        guard !address.isEmpty else {
            problem = Problem(title: "Enter the MPC's address", message: DeveloperModeHelp.findAddress)
            return
        }
        guard SSHSession.isValidHost(address) else {
            problem = Problem(title: "That address doesn't look right",
                              message: "Use the MPC's IP address, for example 192.168.1.50. " + DeveloperModeHelp.findAddress)
            return
        }
        guard SSHSession.isValidUser(trimmedUser) else {
            problem = Problem(title: "That user name doesn't look right", message: "The MPC's standard user name is root.")
            return
        }
        problem = nil
        state = .connecting
        generation += 1
        let token = generation
        let settings = SSHSession.Settings(host: address, port: port, user: trimmedUser,
                                           password: password.isEmpty ? nil : password)
        let account = keychainAccount
        let typedPassword = password

        Task {
            do {
                let (newSession, newFileSystem) = try await browseWorker.run { () -> (SSHSession, RemoteFileSystem) in
                    // A quick knock on the door first: it tells "developer mode is off" apart from "nothing there".
                    switch NetworkProbe.check(host: settings.host, port: settings.port, timeout: 5) {
                    case .open: break
                    case .refused: throw SSHError(.refused)
                    case .unreachable: throw SSHError(.unreachable)
                    case .unresolved: throw SSHError(.dns)
                    }
                    let session = SSHSession(settings: settings)
                    let fileSystem = RemoteFileSystem(session: session)
                    do {
                        let info = try fileSystem.connect()
                        if !info.looksLikeMPC && !skipIdentityCheck {
                            throw NotAnMPC(name: info.hostname)
                        }
                    } catch {
                        session.close()
                        throw error
                    }
                    return (session, fileSystem)
                }
                guard token == generation, state == .connecting else {
                    newSession.close()
                    return
                }
                session = newSession
                fileSystem = newFileSystem
                deviceInfo = newFileSystem.deviceInfo
                drives = newFileSystem.drives
                state = .connected
                search = .idle
                if typedPassword.isEmpty {
                    Keychain.remove(account: account)
                } else {
                    Keychain.save(password: typedPassword, account: account)
                }
                startMonitor()
                if let first = drives.first {
                    showDrive(first)
                } else {
                    clearFolder()
                }
            } catch {
                guard token == generation else { return }
                state = .disconnected
                problem = describeConnectionFailure(error, settings: settings)
            }
        }
    }

    private struct NotAnMPC: Error {
        let name: String
    }

    private func describeConnectionFailure(_ error: Error, settings: SSHSession.Settings) -> Problem {
        if let notMPC = error as? NotAnMPC {
            let who = notMPC.name.isEmpty ? "The device at \(settings.host)" : "“\(notMPC.name)” at \(settings.host)"
            return Problem(title: "That doesn't look like an MPC",
                           message: "\(who) accepted the login but doesn't identify itself as an MPC, so MPC Loader stopped there. Check the address.",
                           offersConnectAnyway: true)
        }
        guard let ssh = error as? SSHError else {
            return Problem(title: "Couldn't connect", message: error.localizedDescription)
        }
        switch ssh.kind {
        case .refused:
            return Problem(title: "The MPC is there, but developer mode looks to be off",
                           message: "\(settings.host) turned the connection down on port \(settings.port). That almost always means developer mode is not switched on, because developer mode is what starts the MPC's SSH server.",
                           showsDeveloperModeHelp: true)
        case .unreachable:
            return Problem(title: "Nothing answered at \(settings.host)",
                           message: "Check that the MPC is switched on and on the same network as this Mac, and that the address is right. \(DeveloperModeHelp.findAddress) If macOS asked whether MPC Loader may find devices on your local network, allow it in System Settings → Privacy & Security → Local Network.")
        case .dns:
            return Problem(title: "Can't find “\(settings.host)”",
                           message: "That name doesn't lead to a device. Use the MPC's IP address instead, for example 192.168.1.50. " + DeveloperModeHelp.findAddress)
        case .auth:
            if settings.password == nil || settings.password?.isEmpty == true {
                return Problem(title: "The MPC wants a password",
                               message: "The standard login (\(SSHSession.Settings.defaultUser), no password) was refused. If you have set an SSH password on the MPC, open Login Details and enter it.")
            }
            return Problem(title: "The user name or password was refused",
                           message: "Check them in Login Details. If you never set a password on the MPC, choose Use MPC Defaults.")
        case .closed:
            return Problem(title: "The connection was closed straight away",
                           message: "The MPC's SSH server may still be starting. Wait ten seconds and try again. If it keeps happening, switch developer mode off and on again on the MPC.")
        case .timeout:
            return Problem(title: "The MPC stopped responding", message: "The connection timed out. Check the network and try again.")
        case .noClient:
            return Problem(title: "This Mac has no ssh command", message: "MPC Loader uses the ssh program that comes with macOS at /usr/bin/ssh, and it is missing.")
        case .cancelled, .other:
            return Problem(title: "Couldn't connect", message: ssh.detail.isEmpty ? "The SSH connection failed." : ssh.detail)
        }
    }

    func disconnect() {
        guard state != .disconnected else { return }
        teardown()
        problem = nil
    }

    func cancelConnecting() {
        guard state == .connecting else { return }
        generation += 1
        state = .disconnected
    }

    private func teardown() {
        generation += 1
        monitor?.invalidate()
        monitor = nil
        transferControl?.cancel()
        let closing = session
        session = nil
        fileSystem = nil
        state = .disconnected
        deviceInfo = nil
        drives = []
        transfer = nil
        lastSummary = nil
        lastRevealURLs = []
        clearFolder()
        if let closing {
            DispatchQueue.global(qos: .utility).async { closing.close() }
        }
    }

    /// Called when the app quits, so no connection is left open.
    func shutdown() {
        transferControl?.cancel()
        session?.close()
        session = nil
    }

    private func connectionLost(_ error: SSHError) {
        guard state == .connected else { return }
        teardown()
        problem = Problem(title: "The connection to the MPC was lost",
                          message: "\(error.localizedDescription) Check that the MPC is still on, on the network and in developer mode, then connect again.")
    }

    // MARK: Keeping the drive list fresh

    private func startMonitor() {
        monitor?.invalidate()
        monitor = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDrivesQuietly() }
        }
    }

    /// Notices drives being plugged in or pulled out, and a dropped connection.
    private func refreshDrivesQuietly() {
        guard state == .connected, transfer == nil, !isBusy, !monitorRunning, let fileSystem else { return }
        monitorRunning = true
        let token = generation
        Task {
            defer { monitorRunning = false }
            do {
                let latest = try await browseWorker.run { try fileSystem.refreshDrives() }
                guard token == generation else { return }
                applyDrives(latest)
            } catch let error as SSHError {
                guard token == generation, error.kind != .cancelled else { return }
                connectionLost(error)
            } catch {}
        }
    }

    private func applyDrives(_ latest: [Drive]) {
        if latest != drives { drives = latest }
        guard let current = currentDrive else {
            if currentPath == nil, let first = latest.first { showDrive(first) }
            return
        }
        if let updated = latest.first(where: { $0.mountPoint == current.mountPoint }) {
            if updated != current { currentDrive = updated }
        } else {
            notice = Notice(title: "“\(current.displayName)” is no longer connected",
                            message: "The drive was removed from the MPC.")
            if let first = latest.first { showDrive(first) } else { clearFolder() }
        }
    }

    // MARK: Browsing

    private func clearFolder() {
        loadToken = UUID()
        currentDrive = nil
        currentPath = nil
        entries = []
        selection = []
        folderError = nil
        isLoading = false
        backStack = []
        forwardStack = []
        updateHistoryFlags()
    }

    private func updateHistoryFlags() {
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
    }

    func showDrive(_ drive: Drive) {
        backStack = []
        forwardStack = []
        currentDrive = drive
        load(drive.mountPoint)
    }

    func showDrive(id: String?) {
        guard let id, let drive = drives.first(where: { $0.id == id }) else { return }
        if drive.mountPoint == currentDrive?.mountPoint, currentPath == drive.mountPoint { return }
        showDrive(drive)
    }

    func open(path: String) {
        guard let current = currentPath, path != current else { return }
        backStack.append(current)
        forwardStack = []
        load(path)
    }

    func open(_ entry: RemoteEntry) {
        if entry.isDirectory { open(path: entry.path) }
    }

    func goBack() {
        guard let previous = backStack.popLast(), let current = currentPath else { return }
        forwardStack.append(current)
        load(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast(), let current = currentPath else { return }
        backStack.append(current)
        load(next)
    }

    var canGoUp: Bool {
        guard let drive = currentDrive, let path = currentPath else { return false }
        return path != drive.mountPoint
    }

    func goUp() {
        guard canGoUp, let path = currentPath else { return }
        open(path: RemotePath.parent(of: path))
    }

    func reload() {
        guard let path = currentPath else { return }
        load(path, keepSelection: true)
    }

    private func load(_ path: String, keepSelection: Bool = false) {
        guard let fileSystem else { return }
        if let drive = drives.filter({ RemotePath.isInside(path, root: $0.mountPoint) })
            .max(by: { $0.mountPoint.count < $1.mountPoint.count }) {
            currentDrive = drive
        }
        currentPath = path
        if !keepSelection {
            selection = []
            entries = []
            searchText = ""
        }
        folderError = nil
        isLoading = true
        updateHistoryFlags()
        let token = UUID()
        loadToken = token
        Task {
            do {
                let listed = try await browseWorker.run { try fileSystem.list(path) }
                guard token == loadToken else { return }
                entries = listed
                let present = Set(listed.map(\.id))
                selection = selection.intersection(present)
                isLoading = false
            } catch {
                guard token == loadToken else { return }
                isLoading = false
                entries = []
                if let ssh = error as? SSHError {
                    connectionLost(ssh)
                } else {
                    folderError = error.localizedDescription
                    if (error as? RemoteFileError)?.kind == .driveGone { refreshDrivesQuietly() }
                }
            }
        }
    }

    // MARK: Requests from buttons and menus

    func requestNewFolder() {
        guard canWriteHere else { return }
        isNamingNewFolder = true
    }

    func requestRename() {
        let targets = selectedEntries
        guard canWriteHere, targets.count == 1 else { return }
        renaming = targets[0]
    }

    func requestDelete() {
        let targets = selectedEntries
        guard canWriteHere, !targets.isEmpty else { return }
        deleting = targets
    }

    func toggleConnection() {
        switch state {
        case .disconnected: connect()
        case .connecting: cancelConnecting()
        case .connected: disconnect()
        }
    }

    // MARK: Changing things on the MPC

    /// Returns nil when the name is fine, or the reason it can't be used.
    func problem(withName name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let drive = currentDrive { return drive.problem(withName: trimmed) }
        return RemotePath.isValidName(trimmed) ? nil : "That name can't be used."
    }

    private func perform(_ title: String, _ work: @escaping (RemoteFileSystem) throws -> Void, then: @escaping () -> Void = {}) {
        guard let fileSystem, !isBusy else { return }
        isBusy = true
        let token = generation
        Task {
            defer { isBusy = false }
            do {
                try await browseWorker.run {
                    try work(fileSystem)
                    fileSystem.flush()
                }
                guard token == generation else { return }
                then()
            } catch let error as SSHError {
                guard token == generation else { return }
                connectionLost(error)
                return
            } catch {
                guard token == generation else { return }
                notice = Notice(title: title, message: error.localizedDescription)
            }
            reload()
            refreshDrivesQuietly()
        }
    }

    func createFolder(named name: String) {
        guard let path = currentPath, canWriteHere else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let issue = problem(withName: trimmed) {
            notice = Notice(title: "The folder couldn't be created", message: issue)
            return
        }
        let target = RemotePath.join(path, trimmed)
        perform("The folder couldn't be created", { try $0.makeDirectory(target) }, then: { [weak self] in
            self?.selection = [target]
        })
    }

    func rename(_ entry: RemoteEntry, to name: String) {
        guard canWriteHere else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed == entry.name { return }
        if let issue = problem(withName: trimmed) {
            notice = Notice(title: "“\(entry.name)” couldn't be renamed", message: issue)
            return
        }
        let target = RemotePath.join(RemotePath.parent(of: entry.path), trimmed)
        perform("“\(entry.name)” couldn't be renamed", { try $0.move(entry.path, to: target) }, then: { [weak self] in
            self?.selection = [target]
        })
    }

    func delete(_ targets: [RemoteEntry]) {
        guard canWriteHere, !targets.isEmpty else { return }
        perform("Not everything could be deleted", { fileSystem in
            var firstError: Error?
            for target in targets {
                do {
                    try fileSystem.delete(target.path)
                } catch let error as SSHError {
                    throw error
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            if let firstError { throw firstError }
        })
    }

    // MARK: Copying to the MPC

    func chooseFilesToUpload() {
        guard canWriteHere else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Copy to MPC"
        panel.message = "Choose the files and folders to copy to “\(breadcrumb.last?.name ?? "the MPC")”."
        if panel.runModal() == .OK {
            upload(panel.urls)
        }
    }

    /// Copies Mac files and folders into the open folder on the MPC.
    func upload(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard isConnected, let fileSystem, let directory = currentPath, let drive = currentDrive else { return }
        guard transfer == nil, !isBusy else {
            notice = Notice(title: "A copy is already running", message: "Wait for it to finish, or cancel it, then try again.")
            return
        }
        guard drive.isWritable else {
            notice = Notice(title: "“\(drive.displayName)” is read-only",
                            message: "Files can be copied from this drive to your Mac, but nothing on it can be changed.")
            return
        }
        let control = CommandControl()
        transferControl = control
        transfer = TransferStatus(toMPC: true)
        lastSummary = nil
        lastRevealURLs = []
        let token = generation
        let destinationName = breadcrumb.last?.name ?? drive.displayName

        Task {
            var report = TransferReport(toMPC: true, destination: destinationName, copiedFiles: 0, plannedFiles: 0,
                                        driveFormat: drive.formatDescription)
            defer { finishTransfer(report, token: token) }
            do {
                // 1. Work out what will be copied, and what is already there.
                let prepared = try await transferWorker.run { () -> (TransferPlan.Upload, [RemoteEntry], Int64?) in
                    let plan = TransferPlan.upload(items: urls, into: directory, drive: drive)
                    let existing = try fileSystem.list(directory)
                    let free = try fileSystem.refreshDrives().first { $0.mountPoint == drive.mountPoint }?.freeBytes
                    return (plan, existing, free)
                }
                var plan = prepared.0
                let existing = prepared.1
                let freeBytes = prepared.2
                report.skipped = plan.skipped
                report.plannedFiles = plan.files.count
                guard !plan.isEmpty else { return }

                if let freeBytes, plan.totalBytes > freeBytes {
                    report.stoppedBecause = "There isn't enough room on “\(drive.displayName)”. The copy needs \(Format.bytes(plan.totalBytes)) and \(Format.bytes(freeBytes)) is free. Nothing was copied."
                    return
                }

                // 2. Ask before replacing anything.
                var replace = false
                let existingNames = Set(existing.map { $0.name.lowercased() })
                let clashes = plan.topLevelNames.filter { existingNames.contains($0.lowercased()) }
                if !clashes.isEmpty {
                    switch await ask(ConflictQuestion(names: clashes)) {
                    case .cancel:
                        report.cancelled = true
                        return
                    case .replace:
                        replace = true
                    case .skip:
                        let blocked = clashes.map { RemotePath.join(directory, $0) }
                        plan.files.removeAll { file in blocked.contains { RemotePath.isInside(file.remote, root: $0) } }
                        plan.directories.removeAll { folder in blocked.contains { RemotePath.isInside(folder, root: $0) } }
                        report.plannedFiles = plan.files.count
                        guard !plan.isEmpty else { return }
                    }
                }
                guard token == generation else { return }

                // 3. Copy.
                transfer = TransferStatus(toMPC: true, preparing: false, totalFiles: plan.files.count, totalBytes: plan.totalBytes)
                let replaceExisting = replace
                let finalPlan = plan
                let outcome = try await transferWorker.run { () -> CopyOutcome in
                    var outcome = CopyOutcome()
                    var failedFolders: [String] = []
                    for folder in finalPlan.directories {
                        if control.isCancelled { outcome.cancelled = true; return outcome }
                        do {
                            try fileSystem.makeDirectory(folder, existingIsFine: true)
                        } catch let error as SSHError {
                            throw error
                        } catch {
                            failedFolders.append(folder)
                            outcome.failures.append(Failure(name: RemotePath.lastComponent(of: folder), message: error.localizedDescription))
                        }
                    }
                    var doneBytes: Int64 = 0
                    for (index, file) in finalPlan.files.enumerated() {
                        if control.isCancelled { outcome.cancelled = true; break }
                        if failedFolders.contains(where: { RemotePath.isInside(file.remote, root: $0) }) { continue }
                        let name = RemotePath.lastComponent(of: file.remote)
                        let base = doneBytes
                        self.publishProgress(name: name, files: index, bytes: base, token: token)
                        do {
                            try fileSystem.upload(localFile: file.local, to: file.remote, replaceExisting: replaceExisting,
                                                  control: control) { bytes in
                                self.publishProgress(name: name, files: index, bytes: base + bytes, token: token)
                            }
                            outcome.copied += 1
                        } catch let error as SSHError {
                            if error.kind == .cancelled { outcome.cancelled = true; break }
                            throw error
                        } catch let error as RemoteFileError {
                            outcome.failures.append(Failure(name: name, message: error.localizedDescription))
                            if error.kind == .driveGone || error.kind == .noSpace {
                                outcome.stoppedBecause = error.localizedDescription
                                break
                            }
                        }
                        doneBytes += file.size
                    }
                    fileSystem.flush()
                    return outcome
                }
                report.copiedFiles = outcome.copied
                report.failures = outcome.failures
                report.cancelled = outcome.cancelled
                report.stoppedBecause = outcome.stoppedBecause
            } catch let error as SSHError {
                if error.kind == .cancelled {
                    report.cancelled = true
                } else {
                    report.stoppedBecause = "The connection to the MPC was lost. " + (error.localizedDescription)
                    lostDuringTransfer = error
                }
            } catch {
                report.stoppedBecause = error.localizedDescription
            }
        }
    }

    private struct CopyOutcome {
        var copied = 0
        var failures: [Failure] = []
        var cancelled = false
        var stoppedBecause: String?
    }

    private var lostDuringTransfer: SSHError?

    /// Called from the copy thread. Hops to the main thread to update the progress bar.
    nonisolated private func publishProgress(name: String, files: Int, bytes: Int64, token: Int) {
        Task { @MainActor in
            guard token == self.generation, var status = self.transfer, !status.preparing else { return }
            status.currentName = name
            status.completedFiles = files
            status.completedBytes = max(status.completedBytes, bytes)
            self.transfer = status
        }
    }

    private func finishTransfer(_ report: TransferReport, token: Int) {
        transferControl = nil
        guard token == generation else { return }
        transfer = nil
        if let lost = lostDuringTransfer {
            lostDuringTransfer = nil
            self.report = report
            connectionLost(lost)
            return
        }
        let where_ = report.toMPC ? "to “\(report.destination)” on the MPC" : "to “\(report.destination)” on this Mac"
        if report.copiedFiles > 0 {
            lastSummary = "Copied \(Format.count(report.copiedFiles, "file", "files")) \(where_)"
            lastRevealURLs = report.revealURLs
        } else {
            lastSummary = nil
            lastRevealURLs = []
        }
        // The alert the user asked for: once the valid files are across, say what was left out.
        if report.needsAttention { self.report = report }
        reload()
        refreshDrivesQuietly()
    }

    private func ask(_ question: ConflictQuestion) async -> ConflictAnswer {
        await withCheckedContinuation { continuation in
            conflictContinuation = continuation
            conflict = question
        }
    }

    func answerConflict(_ answer: ConflictAnswer) {
        conflict = nil
        conflictContinuation?.resume(returning: answer)
        conflictContinuation = nil
    }

    func cancelTransfer() {
        transferControl?.cancel()
        if conflict != nil { answerConflict(.cancel) }
    }

    func dismissSummary() {
        lastSummary = nil
        lastRevealURLs = []
    }

    func revealLastDownload() {
        guard !lastRevealURLs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(lastRevealURLs)
    }

    // MARK: Copying to the Mac

    func chooseWhereToDownload() {
        let targets = selectedEntries
        guard canCopy, !targets.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Copy Here"
        panel.message = targets.count == 1
            ? "Choose where on this Mac to copy “\(targets[0].name)”."
            : "Choose where on this Mac to copy the \(targets.count) selected items."
        if let saved = defaults.string(forKey: "downloadFolder"), FileManager.default.fileExists(atPath: saved) {
            panel.directoryURL = URL(fileURLWithPath: saved)
        } else {
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        }
        if panel.runModal() == .OK, let folder = panel.url {
            defaults.set(folder.path, forKey: "downloadFolder")
            download(targets, to: folder)
        }
    }

    /// Copies files and folders from the MPC into a folder on this Mac. Nothing on the Mac is replaced.
    func download(_ targets: [RemoteEntry], to folder: URL) {
        guard isConnected, let fileSystem, !targets.isEmpty else { return }
        guard transfer == nil, !isBusy else {
            notice = Notice(title: "A copy is already running", message: "Wait for it to finish, or cancel it, then try again.")
            return
        }
        let control = CommandControl()
        transferControl = control
        transfer = TransferStatus(toMPC: false)
        lastSummary = nil
        lastRevealURLs = []
        let token = generation

        Task {
            var report = TransferReport(toMPC: false, destination: folder.lastPathComponent, copiedFiles: 0, plannedFiles: 0)
            defer { finishTransfer(report, token: token) }
            do {
                let plan = try await transferWorker.run {
                    try TransferPlan.download(entries: targets, into: folder, fileSystem: fileSystem,
                                              isCancelled: { control.isCancelled })
                }
                report.skipped = plan.skipped
                report.plannedFiles = plan.files.count
                guard !plan.isEmpty else { return }

                if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage, plan.totalBytes > free {
                    report.stoppedBecause = "There isn't enough room on this Mac. The copy needs \(Format.bytes(plan.totalBytes)) and \(Format.bytes(free)) is free. Nothing was copied."
                    return
                }
                guard token == generation else { return }
                transfer = TransferStatus(toMPC: false, preparing: false, totalFiles: plan.files.count, totalBytes: plan.totalBytes)

                let topLevel = Set(plan.directories.filter { $0.deletingLastPathComponent().path == folder.path }
                    + plan.files.map(\.local).filter { $0.deletingLastPathComponent().path == folder.path })
                let outcome = try await transferWorker.run { () -> CopyOutcome in
                    var outcome = CopyOutcome()
                    let fileManager = FileManager.default
                    for directory in plan.directories {
                        do {
                            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                        } catch {
                            outcome.stoppedBecause = "The folder “\(directory.lastPathComponent)” couldn't be created on this Mac. \(error.localizedDescription)"
                            return outcome
                        }
                    }
                    var doneBytes: Int64 = 0
                    for (index, file) in plan.files.enumerated() {
                        if control.isCancelled { outcome.cancelled = true; break }
                        let name = file.local.lastPathComponent
                        let base = doneBytes
                        self.publishProgress(name: name, files: index, bytes: base, token: token)
                        do {
                            try fileSystem.download(remoteFile: file.remote, to: file.local, control: control) { bytes in
                                self.publishProgress(name: name, files: index, bytes: base + bytes, token: token)
                            }
                            outcome.copied += 1
                        } catch let error as SSHError {
                            if error.kind == .cancelled { outcome.cancelled = true; break }
                            throw error
                        } catch let error as RemoteFileError {
                            outcome.failures.append(Failure(name: name, message: error.localizedDescription))
                            if error.kind == .driveGone {
                                outcome.stoppedBecause = error.localizedDescription
                                break
                            }
                        }
                        doneBytes += file.size
                    }
                    return outcome
                }
                report.copiedFiles = outcome.copied
                report.failures = outcome.failures
                report.cancelled = outcome.cancelled
                report.stoppedBecause = outcome.stoppedBecause
                report.revealURLs = Array(topLevel.filter { FileManager.default.fileExists(atPath: $0.path) })
            } catch let error as SSHError {
                if error.kind == .cancelled {
                    report.cancelled = true
                } else {
                    report.stoppedBecause = "The connection to the MPC was lost. " + (error.localizedDescription)
                    lostDuringTransfer = error
                }
            } catch {
                report.stoppedBecause = error.localizedDescription
            }
        }
    }
}
