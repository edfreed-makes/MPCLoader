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

    /// How the open folder is laid out. The same four choices as Finder.
    enum ViewMode: String, CaseIterable, Identifiable {
        case icons
        case list
        case columns
        case gallery

        var id: String { rawValue }

        var title: String {
            switch self {
            case .icons: return "Icons"
            case .list: return "List"
            case .columns: return "Columns"
            case .gallery: return "Gallery"
            }
        }

        var symbolName: String {
            switch self {
            case .icons: return "square.grid.2x2"
            case .list: return "list.bullet"
            case .columns: return "rectangle.split.3x1"
            case .gallery: return "squares.below.rectangle"
            }
        }
    }

    /// What the items are ordered by. These are the details an MPC keeps about each file.
    enum SortKey: String, CaseIterable, Identifiable {
        case name
        case kind
        case modified
        case size

        var id: String { rawValue }

        var title: String {
            switch self {
            case .name: return "Name"
            case .kind: return "Kind"
            case .modified: return "Date Modified"
            case .size: return "Size"
            }
        }
    }

    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// Asked before a copy to the MPC when something of the same name is already there.
    struct ConflictQuestion: Identifiable {
        let id = UUID()
        /// The items being copied whose names are taken.
        let names: [String]
        /// How many files on the MPC choosing Replace would overwrite, counting inside folders.
        var overwriteCount = 0
        /// A folder being copied meets a folder of the same name, which Replace merges.
        var mergesFolders = false
        /// What Keep Both would call the first of them, for example "Kit 2".
        var keepBothExample = ""
    }

    enum ConflictAnswer {
        case replace
        case keepBoth
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
    @Published var sortOrder: [KeyPathComparator<RemoteEntry>] = AppModel.sorting(by: .name, ascending: true) {
        didSet {
            defaults.set(sortKey.rawValue, forKey: "sortKey")
            defaults.set(sortAscending, forKey: "sortAscending")
        }
    }
    @Published var viewMode: ViewMode {
        didSet {
            defaults.set(viewMode.rawValue, forKey: "viewMode")
            if viewMode == .columns { loadMissingColumns() }
            if viewMode == .gallery { selectFirstIfNothingSelected() }
        }
    }
    /// The contents of the folders above the open one, for column view.
    @Published private(set) var columnListings: [String: [RemoteEntry]] = [:]
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

    /// Plays audio files from the MPC. It has its own state so the file list is not redrawn as a file plays.
    let preview = PreviewPlayer()
    /// How many items dragged out of the window are still being copied to this Mac.
    @Published private(set) var draggingOut = 0

    // Dialogs the window shows. They live here so menu commands can open them too.
    @Published var isNamingNewFolder = false
    @Published var renaming: RemoteEntry?
    @Published var deleting: [RemoteEntry]?

    /// Demo scenes keep their own settings so they never disturb the real ones.
    private let defaults: UserDefaults = AppModel.demoScene == nil
        ? .standard
        : (UserDefaults(suiteName: "io.github.edfreed-makes.mpcloader.demo") ?? .standard)
    private let browseWorker = Worker("mpcloader.browse")
    private let transferWorker = Worker("mpcloader.transfer")
    private var session: SSHSession?
    private var fileSystem: RemoteFileSystem?
    /// Where previews and dragged items are fetched from: the MPC, or made-up content in a demo.
    private var fileSource: FileSource?
    private let dragExporter = DragExporter()
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
        viewMode = ViewMode(rawValue: defaults.string(forKey: "viewMode") ?? "") ?? .list
        if let saved = SortKey(rawValue: defaults.string(forKey: "sortKey") ?? "") {
            let ascending = defaults.object(forKey: "sortAscending") == nil ? true : defaults.bool(forKey: "sortAscending")
            sortOrder = AppModel.sorting(by: saved, ascending: ascending)
        }
        Scratch.removeStale()
        if let scene = AppModel.demoScene {
            loadDemo(scene)
        } else if !host.isEmpty {
            password = Keychain.password(account: keychainAccount) ?? ""
        }
    }

    // MARK: Demo scenes

    /// Launching with one of these arguments fills the window with sample content.
    /// A demo never touches the network, the Keychain or your saved settings.
    /// Used for screenshots and for checking the interface without an MPC.
    enum DemoScene: String {
        case browser = "--demo"
        case connect = "--demo-connect"
        case refused = "--demo-refused"
        case report = "--demo-report"
        case preview = "--demo-preview"
        case conflict = "--demo-conflict"
    }

    static let demoScene: DemoScene? = CommandLine.arguments.compactMap(DemoScene.init(rawValue:)).first
    var isDemo: Bool { AppModel.demoScene != nil }

    private func loadDemo(_ scene: DemoScene) {
        user = SSHSession.Settings.defaultUser
        portText = String(SSHSession.Settings.defaultPort)
        showHidden = false
        switch scene {
        case .connect:
            host = ""
            return
        case .refused:
            host = "192.168.1.50"
            problem = describeConnectionFailure(SSHError(.refused), settings: .init(host: "192.168.1.50"))
            return
        case .browser, .report, .preview, .conflict:
            host = "192.168.1.50"
        }
        let source = DemoSource()
        fileSource = source

        let mounts = """
        /dev/mmcblk0p1 /media/az01-internal-sd ext4 rw,relatime 0 0
        /dev/sda1 /media/SANDISK\\04064 exfat rw,relatime 0 0
        /dev/sdb1 /media/SAMPLES\\040SSD exfat rw,relatime 0 0
        /dev/mmcblk2p6 /media/acvs-content ext4 rw,relatime 0 0
        """
        let df = """
        Filesystem 1024-blocks Used Available Capacity Mounted on
        /dev/mmcblk0p1 14800000 9100000 5700000 62% /media/az01-internal-sd
        /dev/sda1 62500000 20100000 42400000 33% /media/SANDISK 64
        /dev/sdb1 488000000 131000000 357000000 27% /media/SAMPLES SSD
        /dev/mmcblk2p6 9800000 9100000 700000 93% /media/acvs-content
        """
        drives = StorageRules.parse(mounts: mounts, df: df).drives
        var info = DeviceInfo()
        info.model = "Akai MPC Live II"
        info.firmware = "3.10.1"
        deviceInfo = info
        state = .connected
        currentDrive = drives.first { $0.name == "SANDISK 64" } ?? drives.first
        let folder = (currentDrive?.mountPoint ?? "/media/SANDISK 64") + "/Samples/Drum Kits"
        currentPath = folder
        backStack = [RemotePath.parent(of: folder)]
        updateHistoryFlags()

        let day: TimeInterval = 86_400
        let now = Date()
        func entry(_ name: String, _ kind: RemoteEntry.Kind, _ size: Int64, daysAgo: Double) -> RemoteEntry {
            RemoteEntry(path: RemotePath.join(folder, name), name: name, kind: kind, size: size,
                        modified: now.addingTimeInterval(-daysAgo * day))
        }
        entries = [
            entry("808 Essentials", .directory, 0, daysAgo: 3),
            entry("Boom Bap Kit", .directory, 0, daysAgo: 12),
            entry("Vinyl Breaks", .directory, 0, daysAgo: 40),
            entry("Beat Tape 3.xpj", .file, 48_200, daysAgo: 0.2),
            entry("Boom Bap Kit.xpm", .file, 21_700, daysAgo: 12),
            entry("Dusty Loop 92bpm.wav", .file, 5_644_800, daysAgo: 1),
            entry("Hat Closed 03.aif", .file, 88_400, daysAgo: 25),
            entry("Kick Deep 01.wav", .file, 412_300, daysAgo: 0.1),
            entry("Rhodes Chords.flac", .file, 9_210_000, daysAgo: 7),
            entry("Snare Crack.wav", .file, 276_900, daysAgo: 0.1),
            entry("Verse Fill.mid", .file, 1_180, daysAgo: 60),
            entry("Vocal Chop.mp3", .file, 1_920_000, daysAgo: 15),
        ]
        selection = [RemotePath.join(folder, "Kick Deep 01.wav"), RemotePath.join(folder, "Snare Crack.wav")]

        // `--view-icons` (or -list, -columns, -gallery) picks the layout for a screenshot.
        // One word on purpose: macOS takes a bare word such as "icons" for a file to open,
        // and then never shows the main window.
        sortOrder = AppModel.sorting(by: .name, ascending: true)
        viewMode = .list
        if let wanted = ViewMode.allCases.first(where: { CommandLine.arguments.contains("--view-\($0.rawValue)") }) {
            viewMode = wanted
            selection = [RemotePath.join(folder, "Kick Deep 01.wav")]
        }
        if CommandLine.arguments.contains("--view-list") { selection = [] }
        let drive = currentDrive?.mountPoint ?? "/media/SANDISK 64"
        func folderEntries(_ parent: String, _ names: [String]) -> [RemoteEntry] {
            names.map { RemoteEntry(path: RemotePath.join(parent, $0), name: $0, kind: .directory, size: 0, modified: now.addingTimeInterval(-9 * day)) }
        }
        columnListings[drive] = folderEntries(drive, ["Expansions", "Projects", "Samples"])
        columnListings[RemotePath.join(drive, "Samples")] = folderEntries(RemotePath.join(drive, "Samples"), ["Drum Kits", "Loops", "One Shots", "Vocals"])
        columnListings[folder] = entries
        if scene == .preview {
            selection = [RemotePath.join(folder, "Kick Deep 01.wav")]
            if let kick = entries.first(where: { $0.name == "Kick Deep 01.wav" }) { preview.play(kick, from: source) }
        }

        if scene == .conflict {
            conflict = ConflictQuestion(names: ["Boom Bap Kit", "Kick Deep 01.wav"], overwriteCount: 14,
                                        mergesFolders: true, keepBothExample: "Boom Bap Kit 2")
        }
        if scene == .report {
            report = TransferReport(toMPC: true, destination: "Drum Kits", copiedFiles: 124, plannedFiles: 124,
                                    skipped: [
                                        SkippedItem(name: "Soul Pack/Licence.pdf", reason: .unsupportedType),
                                        SkippedItem(name: "Soul Pack/cover.jpg", reason: .unsupportedType),
                                        SkippedItem(name: "Soul Pack/Loops/break 01.asd", reason: .unsupportedType),
                                        SkippedItem(name: "Soul Pack/Loops/break 02.asd", reason: .unsupportedType),
                                        SkippedItem(name: "Soul Pack/What Now?.wav", reason: .nameNotAllowed),
                                        SkippedItem(name: "Soul Pack/Takes: Final", isFolder: true, reason: .nameNotAllowed),
                                    ],
                                    driveFormat: "exFAT")
            lastSummary = "Copied 124 files to “Drum Kits” on the MPC"
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
        arrange(entries, searching: true)
    }

    private func arrange(_ list: [RemoteEntry], searching: Bool) -> [RemoteEntry] {
        var items = list.filter { entry in
            if entry.name.hasPrefix(".mpcl-") { return false }
            if !showHidden && entry.isHidden { return false }
            return true
        }
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        if searching, !needle.isEmpty {
            items = items.filter { $0.name.localizedCaseInsensitiveContains(needle) }
        }
        return items.sorted(using: sortOrder)
    }

    // MARK: Sorting

    static func sorting(by key: SortKey, ascending: Bool) -> [KeyPathComparator<RemoteEntry>] {
        let order: SortOrder = ascending ? .forward : .reverse
        let byName = KeyPathComparator(\RemoteEntry.name, comparator: .localizedStandard)
        switch key {
        case .name:
            return [KeyPathComparator(\RemoteEntry.name, comparator: .localizedStandard, order: order)]
        case .kind:
            return [KeyPathComparator(\RemoteEntry.kindDescription, order: order), byName]
        case .modified:
            return [KeyPathComparator(\RemoteEntry.sortDate, order: order), byName]
        case .size:
            return [KeyPathComparator(\RemoteEntry.size, order: order), byName]
        }
    }

    /// The detail the items are ordered by, whichever way it was chosen: the Sort menu or a list column heading.
    var sortKey: SortKey {
        get {
            guard let keyPath = sortOrder.first?.keyPath else { return .name }
            if keyPath == \RemoteEntry.kindDescription { return .kind }
            if keyPath == \RemoteEntry.sortDate { return .modified }
            if keyPath == \RemoteEntry.size { return .size }
            return .name
        }
        set { sortOrder = AppModel.sorting(by: newValue, ascending: sortAscending) }
    }

    var sortAscending: Bool {
        get { sortOrder.first?.order != .reverse }
        set { sortOrder = AppModel.sorting(by: sortKey, ascending: newValue) }
    }

    // MARK: Column view

    /// The folders shown side by side in column view: the drive first, the open folder last.
    var columnPaths: [String] { breadcrumb.map(\.path) }

    func entries(inColumn path: String) -> [RemoteEntry] {
        if path == currentPath { return visibleEntries }
        return arrange(columnListings[path] ?? [], searching: false)
    }

    /// Fetches the contents of the folders above the open one, which column view shows alongside it.
    private func loadMissingColumns() {
        guard viewMode == .columns, let fileSystem else { return }
        let token = generation
        for path in columnPaths.dropLast() where columnListings[path] == nil {
            Task {
                guard let listed = try? await browseWorker.run({ try fileSystem.list(path) }) else { return }
                if token == generation { columnListings[path] = listed }
            }
        }
    }

    // MARK: Selecting with the mouse and the arrow keys

    private var selectionAnchor: String?

    /// A click on an item in the icon and gallery views, with Finder's rules for Command and Shift.
    func click(_ entry: RemoteEntry, command: Bool, shift: Bool) {
        let items = visibleEntries
        if command {
            if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
            selectionAnchor = entry.id
        } else if shift, let anchor = selectionAnchor,
                  let from = items.firstIndex(where: { $0.id == anchor }),
                  let to = items.firstIndex(where: { $0.id == entry.id }) {
            selection = Set(items[min(from, to)...max(from, to)].map(\.id))
        } else {
            selection = [entry.id]
            selectionAnchor = entry.id
        }
    }

    /// Arrow keys: move the selection by a number of places in the order shown.
    func moveSelection(by offset: Int) {
        let items = visibleEntries
        guard !items.isEmpty, offset != 0 else { return }
        let selected = items.indices.filter { selection.contains(items[$0].id) }
        let start = offset > 0 ? (selected.last ?? -1) : (selected.first ?? items.count)
        let index = max(0, min(items.count - 1, start + offset))
        selection = [items[index].id]
        selectionAnchor = items[index].id
    }

    /// The selected item the gallery and the column preview show: the first one in the order shown.
    var focusedEntry: RemoteEntry? {
        visibleEntries.first { selection.contains($0.id) }
    }

    func selectFirstIfNothingSelected() {
        guard selection.isEmpty, let first = visibleEntries.first else { return }
        selection = [first.id]
        selectionAnchor = first.id
    }

    /// A double-click: open a folder, or play an audio file.
    func activate(_ entry: RemoteEntry) {
        if entry.isDirectory {
            open(entry)
        } else if canPreview(entry) {
            preview(entry)
        }
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
                fileSource = newFileSystem
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
        fileSource = nil
        preview.reset()
        draggingOut = 0
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
        preview.close()
        session?.close()
        session = nil
        Scratch.removeSession()
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
        columnListings = [:]
        pendingSelection = nil
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

    /// Goes to a folder. `selecting` names an item to select once the folder's contents have arrived.
    func open(path: String, selecting: String? = nil) {
        guard let current = currentPath else { return }
        guard path != current else {
            if let selecting { selection = [selecting] }
            return
        }
        backStack.append(current)
        forwardStack = []
        pendingSelection = selecting
        load(path)
    }

    private var pendingSelection: String?

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

    /// The Refresh command: fetch everything on show again.
    func refresh() {
        columnListings = [:]
        reload()
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
                if let wanted = pendingSelection, present.contains(wanted) {
                    selection = [wanted]
                } else {
                    selection = selection.intersection(present)
                }
                pendingSelection = nil
                isLoading = false
                // Keep what column view needs: this folder and the ones above it.
                let keep = Set(columnPaths)
                columnListings = columnListings.filter { keep.contains($0.key) }
                columnListings[path] = listed
                loadMissingColumns()
                if viewMode == .gallery { selectFirstIfNothingSelected() }
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

    // MARK: Previewing audio

    /// The one selected file, when it is audio that can be tried.
    var previewTarget: RemoteEntry? {
        let targets = selectedEntries
        guard targets.count == 1, PreviewPlayer.canTry(targets[0]) else { return nil }
        return targets[0]
    }

    func canPreview(_ entry: RemoteEntry) -> Bool {
        fileSource != nil && PreviewPlayer.canTry(entry)
    }

    func preview(_ entry: RemoteEntry) {
        guard let fileSource, PreviewPlayer.canTry(entry) else { return }
        preview.play(entry, from: fileSource)
    }

    /// The space bar, the toolbar button and the menu: play the selected file, or stop it if it is playing.
    /// Returns false when there was nothing to do, so the key press can go elsewhere.
    @discardableResult
    func togglePreview() -> Bool {
        guard let fileSource else { return false }
        guard let target = previewTarget else {
            guard preview.isOpen else { return false }
            preview.close()
            return true
        }
        if preview.currentPath == target.path, preview.isPlaying || preview.isLoading {
            preview.close()
        } else {
            preview.play(target, from: fileSource)
        }
        return true
    }

    /// While the preview strip is open it follows the selection, so the arrow keys step through samples.
    func previewFollowsSelection() {
        guard preview.isOpen, let fileSource, let target = previewTarget, target.path != preview.currentPath else { return }
        preview.play(target, from: fileSource)
    }

    // MARK: Dragging out to Finder

    /// What macOS needs to let a row be dragged out of the window. The copy only starts when the item is dropped.
    func dragProvider(for entry: RemoteEntry) -> NSItemProvider? {
        guard isConnected, let fileSource, entry.kind == .file || entry.kind == .directory else { return nil }
        let name = entry.name
        return dragExporter.provider(for: entry, source: fileSource, started: { [weak self] in
            Task { @MainActor in self?.draggingOut += 1 }
        }, finished: { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.draggingOut = max(0, self.draggingOut - 1)
                if AppModel.demoScene != nil {
                    print("drag-out: \(error == nil ? "delivered" : "failed") \(name)")
                    fflush(stdout)
                }
                if let error, (error as? SSHError)?.kind != .cancelled {
                    self.notice = Notice(title: "“\(name)” couldn't be copied to your Mac", message: error.localizedDescription)
                }
            }
        })
    }

    /// Files dropped on the window from Finder.
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard isConnected, currentPath != nil else { return false }
        let group = DispatchGroup()
        let collected = URLCollector()
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { collected.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            let urls = collected.urls
            Task { @MainActor in self?.upload(urls) }
        }
        return true
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
                let prepared = try await transferWorker.run { () -> (TransferPlan.Upload, TransferPlan.UploadConflicts, Int64?) in
                    let plan = TransferPlan.upload(items: urls, into: directory, drive: drive)
                    // Looks inside folders that already exist, so the question can say how many files Replace would overwrite.
                    let conflicts = try TransferPlan.conflicts(for: plan, in: directory, drive: drive, fileSystem: fileSystem)
                    let free = try fileSystem.refreshDrives().first { $0.mountPoint == drive.mountPoint }?.freeBytes
                    return (plan, conflicts, free)
                }
                var plan = prepared.0
                let conflicts = prepared.1
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
                let clashes = conflicts.names
                if !clashes.isEmpty {
                    let keptBoth = plan.keepingBoth(clashes, existingNames: conflicts.existingNames, in: directory)
                    let example = plan.topLevelNames.firstIndex(of: clashes[0]).map { keptBoth.topLevelNames[$0] } ?? ""
                    let question = ConflictQuestion(names: clashes, overwriteCount: conflicts.filesToReplace.count,
                                                    mergesFolders: conflicts.mergesFolders, keepBothExample: example)
                    switch await ask(question) {
                    case .cancel:
                        report.cancelled = true
                        return
                    case .replace:
                        replace = true
                    case .keepBoth:
                        // Everything lands under new names beside what is there. Nothing is overwritten.
                        plan = keptBoth
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

/// Gathers the file URLs of a drop as macOS delivers them, possibly on several threads.
private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [URL] = []

    func add(_ url: URL) {
        lock.lock(); found.append(url); lock.unlock()
    }

    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return found
    }
}
