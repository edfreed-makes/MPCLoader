import XCTest
@testable import MPCKit

/// These tests talk to a stand-in MPC set up by `scripts/integration-test.sh`: a local SSH
/// server with an MPC's drive layout. They are skipped when that is not running.
final class IntegrationTests: XCTestCase {
    struct Target {
        let host: String
        let port: Int
        let user: String
        let password: String?
        let mode: String
        let fatDrives: [String]
        let smallDrive: String?
    }

    static let target: Target? = {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MPCKIT_IT_HOST"], let port = env["MPCKIT_IT_PORT"].flatMap(Int.init) else { return nil }
        let fat = (env["MPCKIT_IT_FAT"] ?? "").split(separator: ":").map(String.init)
        let small = env["MPCKIT_IT_SMALL"].flatMap { $0.isEmpty ? nil : $0 }
        return Target(host: host, port: port, user: env["MPCKIT_IT_USER"] ?? "root", password: env["MPCKIT_IT_PASSWORD"],
                      mode: env["MPCKIT_IT_MODE"] ?? "gnu", fatDrives: fat, smallDrive: small)
    }()

    let usb = "/media/MY USB"
    var target: Target!
    var session: SSHSession!
    var fs: RemoteFileSystem!
    var work: String!
    var scratch: URL!

    override func setUpWithError() throws {
        guard let target = Self.target else { throw XCTSkip("No stand-in MPC. Run scripts/integration-test.sh.") }
        self.target = target
        session = SSHSession(settings: .init(host: target.host, port: target.port, user: target.user, password: target.password))
        fs = RemoteFileSystem(session: session)
        try fs.connect()
        work = usb + "/t-" + String(UUID().uuidString.prefix(8))
        try fs.makeDirectory(work)
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mpcl-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let work { try? fs?.delete(work) }
        session?.close()
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: Helpers

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private func localFile(_ name: String, _ data: Data) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func randomData(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            for index in 0..<buffer.count { buffer[index] = UInt8.random(in: 0...255, using: &generator) }
        }
        return data
    }

    private func assertFileError(_ kind: RemoteFileError.Kind, file: StaticString = #filePath, line: UInt = #line,
                                 _ body: () throws -> Void) {
        do {
            try body()
            XCTFail("expected \(kind) but the operation went through", file: file, line: line)
        } catch let error as RemoteFileError {
            XCTAssertEqual(error.kind, kind, "\(error)", file: file, line: line)
        } catch {
            XCTFail("expected \(kind), got \(error)", file: file, line: line)
        }
    }

    private func shell(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, command)
    }

    // MARK: Connecting

    func testConnectReportsDeviceAndDrives() throws {
        let info = fs.deviceInfo
        XCTAssertTrue(info.complete)
        XCTAssertTrue(info.looksLikeMPC)
        XCTAssertEqual(info.firmware, "3.10.1.99")
        XCTAssertTrue(info.hasStat)
        XCTAssertTrue(info.hasFindPlus)

        let mounts = Set(fs.drives.map(\.mountPoint))
        for expected in ["/media/az01-internal-sd", "/nvme", usb, "/media/LOCKED", "/media/acvs-content", "/media/acvs-synths"] {
            XCTAssertTrue(mounts.contains(expected), "missing \(expected) in \(mounts)")
        }
        XCTAssertFalse(mounts.contains("/media/az01-internal"), "the system partition must never be offered")
        XCTAssertFalse(mounts.contains("/media/ramdisk"), "a RAM disk is not a drive")
        XCTAssertFalse(mounts.contains("/"))

        func drive(_ mount: String) -> Drive { fs.drives.first { $0.mountPoint == mount }! }
        XCTAssertTrue(drive(usb).isWritable)
        XCTAssertTrue(drive("/nvme").isWritable)
        XCTAssertEqual(drive("/nvme").kind, .internalStorage)
        XCTAssertFalse(drive("/media/LOCKED").isWritable)
        XCTAssertFalse(drive("/media/acvs-content").isWritable)
        XCTAssertEqual(fs.drives.first?.kind, .internalStorage)
        if let small = target.smallDrive {
            XCTAssertEqual(drive(small).kind, .removable)
            XCTAssertGreaterThan(drive(small).totalBytes ?? 0, 30_000_000)
            XCTAssertGreaterThan(drive(small).freeBytes ?? 0, 10_000_000)
            XCTAssertLessThan(drive(small).freeBytes ?? .max, 48_000_000)
        }
    }

    func testProbesAndDiscovery() throws {
        XCTAssertEqual(NetworkProbe.check(host: target.host, port: target.port), .open)
        XCTAssertEqual(NetworkProbe.check(host: target.host, port: 1, timeout: 2), .refused)
        XCTAssertEqual(NetworkProbe.scan(addresses: ["127.0.0.1"], port: target.port), ["127.0.0.1"])
        XCTAssertEqual(NetworkProbe.scan(addresses: ["127.0.0.1"], port: 1), [])

        let found = Discovery.identify(address: target.host, port: target.port, user: target.user)
        if target.password == nil {
            XCTAssertEqual(found?.looksLikeMPC, true)
        } else {
            XCTAssertNil(found, "a device that wants a password is never identified by guessing")
        }
    }

    func testConnectionFailuresAreToldApart() throws {
        let closedPort = SSHSession(settings: .init(host: target.host, port: 1), multiplex: false)
        XCTAssertThrowsError(try closedPort.run("true")) { XCTAssertEqual(($0 as? SSHError)?.kind, .refused) }

        let badName = SSHSession(settings: .init(host: "no-such-device.invalid"), multiplex: false)
        XCTAssertThrowsError(try badName.run("true")) { XCTAssertEqual(($0 as? SSHError)?.kind, .dns) }

        let badHost = SSHSession(settings: .init(host: "-oProxyCommand=touch /tmp/mpcl-pwned"), multiplex: false)
        XCTAssertThrowsError(try badHost.run("true"))
        XCTAssertFalse(exists("/tmp/mpcl-pwned"))

        if target.password != nil {
            let wrong = SSHSession(settings: .init(host: target.host, port: target.port, user: target.user, password: "nope"),
                                   multiplex: false)
            XCTAssertThrowsError(try wrong.run("true")) { XCTAssertEqual(($0 as? SSHError)?.kind, .auth) }
            let none = SSHSession(settings: .init(host: target.host, port: target.port, user: target.user), multiplex: false)
            XCTAssertThrowsError(try none.run("true")) { XCTAssertEqual(($0 as? SSHError)?.kind, .auth) }
        }
    }

    func testManyCommandsShareOneConnection() throws {
        for index in 0..<20 {
            XCTAssertEqual(try session.run("echo n\(index)").text, "n\(index)\n")
        }
        let failures = Counter()
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            for round in 0..<4 {
                let reply = try? self.session.run("echo c\(index)-\(round)").text
                if reply != "c\(index)-\(round)\n" { failures.increment() }
            }
        }
        XCTAssertEqual(failures.value, 0)
        XCTAssertEqual(try session.run("exit 7").status, 7)
        XCTAssertThrowsError(try session.run("sleep 5", timeout: 0.5)) { XCTAssertEqual(($0 as? SSHError)?.kind, .timeout) }
        XCTAssertEqual(try session.run("echo still-alive").text, "still-alive\n")
    }

    // MARK: Browsing

    func testListingCopesWithAwkwardNames() throws {
        let names = ["Kick 01.wav", "it's.wav", "$(touch pwned).wav", "`touch pwned2`.wav", "-rf", "*", "über Snäre.wav",
                     " leading", "trailing ", "semi;colon", "amp&ersand", "quo\"te", "back\\slash", ".hidden", "a|b", "#hash", "~tilde"]
        for (index, name) in names.enumerated() {
            try Data(count: index + 1).write(to: URL(fileURLWithPath: work + "/" + name))
        }
        try FileManager.default.createDirectory(atPath: work + "/Sub Folder", withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: work + "/link", withDestinationPath: "/etc")

        var strategies: [(Bool, Bool)] = [(fs.deviceInfo.hasStat, fs.deviceInfo.hasFindPlus)]
        if fs.deviceInfo.hasStat { strategies += [(true, false), (false, false)] }
        for (hasStat, hasFindPlus) in strategies {
            fs.overrideCapabilities(hasStat: hasStat, hasFindPlus: hasFindPlus)
            let entries = try fs.list(work)
            let label = "stat=\(hasStat) plus=\(hasFindPlus)"
            XCTAssertEqual(Set(entries.map(\.name)), Set(names + ["Sub Folder", "link"]), label)
            for (index, name) in names.enumerated() {
                let entry = entries.first { $0.name == name }
                XCTAssertEqual(entry?.kind, .file, "\(label) \(name)")
                XCTAssertEqual(entry?.size, Int64(index + 1), "\(label) \(name)")
                XCTAssertEqual(entry?.path, work + "/" + name)
                if hasStat { XCTAssertNotNil(entry?.modified, label) }
            }
            XCTAssertEqual(entries.first { $0.name == "Sub Folder" }?.kind, .directory, label)
            XCTAssertEqual(entries.first { $0.name == "link" }?.kind, .link, label)
        }
        XCTAssertFalse(exists(work + "/pwned"))
        XCTAssertFalse(exists(work + "/pwned2"))
        XCTAssertFalse(exists("/root/pwned"))
        XCTAssertFalse(exists("/root/pwned2"))
    }

    func testLargeFolderAndEmptyFolder() throws {
        XCTAssertEqual(try fs.list(work), [])
        for index in 0..<1500 {
            FileManager.default.createFile(atPath: work + "/sample \(index).wav", contents: nil)
        }
        XCTAssertEqual(try fs.list(work).count, 1500)
    }

    func testMissingFolder() throws {
        assertFileError(.folderMissing) { _ = try fs.list(work + "/nope") }
    }

    // MARK: Changing

    func testCreateRenameDelete() throws {
        let folder = work + "/Kit's \"Best\" $HOME"
        try fs.makeDirectory(folder)
        XCTAssertTrue(exists(folder))
        assertFileError(.alreadyExists) { try fs.makeDirectory(folder) }
        try fs.makeDirectory(folder, existingIsFine: true)
        assertFileError(.folderMissing) { try fs.makeDirectory(work + "/a/b/c") }

        try Data("x".utf8).write(to: URL(fileURLWithPath: folder + "/one.wav"))
        try fs.move(folder + "/one.wav", to: folder + "/two.wav")
        XCTAssertFalse(exists(folder + "/one.wav"))
        XCTAssertTrue(exists(folder + "/two.wav"))

        try Data("y".utf8).write(to: URL(fileURLWithPath: folder + "/three.wav"))
        assertFileError(.alreadyExists) { try fs.move(folder + "/three.wav", to: folder + "/two.wav") }
        XCTAssertEqual(try String(contentsOfFile: folder + "/two.wav", encoding: .utf8), "x", "nothing was overwritten")
        assertFileError(.notFound) { try fs.move(folder + "/ghost.wav", to: folder + "/four.wav") }

        let renamed = work + "/Renamed"
        try fs.move(folder, to: renamed)
        XCTAssertTrue(exists(renamed + "/two.wav"))
        XCTAssertThrowsError(try fs.move(renamed, to: renamed + "/inside"))

        try fs.delete(renamed)
        XCTAssertFalse(exists(renamed))
        assertFileError(.notFound) { try fs.delete(renamed) }
        assertFileError(.invalidName) { try fs.makeDirectory(work + "/bad\nname") }
        assertFileError(.invalidName) { try fs.delete(work + "/../" + RemotePath.lastComponent(of: work)) }
    }

    // MARK: Copying

    func testCopyingWithoutStat() throws {
        // A device with no `stat` command: sizes are checked by counting bytes instead.
        fs.overrideCapabilities(hasStat: false, hasFindPlus: false)
        let payload = randomData(300_000)
        let source = try localFile("nostat.bin", payload)
        try fs.upload(localFile: source, to: work + "/nostat.wav", replaceExisting: false)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: work + "/nostat.wav")), payload)
        XCTAssertEqual(try fs.list(work).map(\.size), [300_000])
        let back = scratch.appendingPathComponent("nostat-back.bin")
        try fs.download(remoteFile: work + "/nostat.wav", to: back)
        XCTAssertEqual(try Data(contentsOf: back), payload)
    }

    func testUploadAndDownloadRoundTrip() throws {
        let payload = randomData(3_000_000)
        let source = try localFile("source.bin", payload)
        let remote = work + "/Über Kick's \"final\" $1.wav"

        let seen = Counter()
        try fs.upload(localFile: source, to: remote, replaceExisting: false) { seen.record($0) }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: remote)), payload)
        XCTAssertEqual(seen.last, Int64(payload.count))

        assertFileError(.alreadyExists) { try fs.upload(localFile: source, to: remote, replaceExisting: false) }

        let replacement = try localFile("replacement.bin", Data("new".utf8))
        try fs.upload(localFile: replacement, to: remote, replaceExisting: true)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: remote)), Data("new".utf8))

        let empty = try localFile("empty.bin", Data())
        try fs.upload(localFile: empty, to: work + "/empty.wav", replaceExisting: false)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: work + "/empty.wav")), Data())

        try fs.upload(localFile: source, to: work + "/big.bin", replaceExisting: false)
        let back = scratch.appendingPathComponent("back.bin")
        let downloaded = Counter()
        try fs.download(remoteFile: work + "/big.bin", to: back) { downloaded.record($0) }
        XCTAssertEqual(try Data(contentsOf: back), payload)
        XCTAssertEqual(downloaded.last, Int64(payload.count))

        let emptyBack = scratch.appendingPathComponent("empty-back.bin")
        try fs.download(remoteFile: work + "/empty.wav", to: emptyBack)
        XCTAssertEqual(try Data(contentsOf: emptyBack), Data())

        assertFileError(.notFound) { try fs.download(remoteFile: work + "/ghost.wav", to: scratch.appendingPathComponent("ghost")) }
        XCTAssertFalse(exists(scratch.appendingPathComponent("ghost").path))
        assertFileError(.unsupportedItem) { try fs.upload(localFile: source, to: work, replaceExisting: true) }

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: work).filter { $0.contains("mpcl") }
        XCTAssertEqual(leftovers, [], "no temporary files stay on the MPC")
        let localLeftovers = try FileManager.default.contentsOfDirectory(atPath: scratch.path).filter { $0.contains("mpcl-part") }
        XCTAssertEqual(localLeftovers, [], "no temporary files stay on the Mac")
    }

    func testUploadIntoAFolderThatIsAFile() throws {
        let source = try localFile("s.bin", Data("abc".utf8))
        try fs.makeDirectory(work + "/Folder")
        assertFileError(.unsupportedItem) { try fs.upload(localFile: source, to: work + "/Folder", replaceExisting: true) }
        XCTAssertTrue(exists(work + "/Folder"))
        assertFileError(.localFile) {
            try fs.upload(localFile: scratch.appendingPathComponent("missing"), to: work + "/x", replaceExisting: true)
        }
    }

    func testCancelledUploadLeavesNothingBehind() throws {
        let big = scratch.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: 400_000_000)
        try handle.close()

        let control = CommandControl()
        let remote = work + "/big.wav"
        XCTAssertThrowsError(try fs.upload(localFile: big, to: remote, replaceExisting: false, control: control) { bytes in
            if bytes > 1_000_000 { control.cancel() }
        }) { error in
            XCTAssertEqual((error as? SSHError)?.kind, .cancelled, "\(error)")
        }
        // The MPC notices the stream stopped short and removes its temporary copy.
        let deadline = Date().addingTimeInterval(20)
        var names: [String] = ["?"]
        while Date() < deadline {
            names = (try? FileManager.default.contentsOfDirectory(atPath: work)) ?? []
            if names.isEmpty { break }
            usleep(200_000)
        }
        XCTAssertEqual(names, [], "a cancelled upload leaves neither the file nor a partial copy")
        XCTAssertEqual(try session.run("echo ok").text, "ok\n", "the connection is still usable")
    }

    func testCancelledDownloadLeavesNothingBehind() throws {
        try shell("truncate -s 400000000 '\(work!)/big.wav'")
        let control = CommandControl()
        let local = scratch.appendingPathComponent("big.wav")
        XCTAssertThrowsError(try fs.download(remoteFile: work + "/big.wav", to: local, control: control) { bytes in
            if bytes > 1_000_000 { control.cancel() }
        }) { error in
            XCTAssertEqual((error as? SSHError)?.kind, .cancelled, "\(error)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path).filter { $0.contains("big") }, [])
    }

    func testDownloadPlanWalksFolders() throws {
        try shell("mkdir -p '\(work!)/Kit/Sub' && printf abc > '\(work!)/Kit/a.wav' && printf defgh > '\(work!)/Kit/Sub/b.wav' && ln -s /etc '\(work!)/Kit/link' && printf z > '\(work!)/loose.wav'")
        try Data().write(to: scratch.appendingPathComponent("loose.wav"))
        let entries = try fs.list(work).sorted { $0.name < $1.name }
        let plan = try TransferPlan.download(entries: entries, into: scratch, fileSystem: fs)
        XCTAssertEqual(plan.directories.map(\.lastPathComponent), ["Kit", "Sub"])
        XCTAssertEqual(plan.files.map(\.local.lastPathComponent), ["a.wav", "b.wav", "loose 2.wav"],
                       "an existing file on the Mac is never replaced")
        XCTAssertEqual(plan.totalBytes, 9)
        XCTAssertEqual(plan.skipped.count, 1)

        for directory in plan.directories { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        for file in plan.files { try fs.download(remoteFile: file.remote, to: file.local) }
        XCTAssertEqual(try String(contentsOf: scratch.appendingPathComponent("Kit/Sub/b.wav"), encoding: .utf8), "defgh")
    }

    func testUploadPlanEndToEnd() throws {
        let kit = scratch.appendingPathComponent("My Kit")
        try FileManager.default.createDirectory(at: kit.appendingPathComponent("Loops"), withIntermediateDirectories: true)
        try Data("kick".utf8).write(to: kit.appendingPathComponent("kick.wav"))
        try Data("loop".utf8).write(to: kit.appendingPathComponent("Loops/loop.wav"))
        try Data("junk".utf8).write(to: kit.appendingPathComponent(".DS_Store"))

        let plan = TransferPlan.upload(items: [kit], into: work)
        for directory in plan.directories { try fs.makeDirectory(directory, existingIsFine: true) }
        for file in plan.files { try fs.upload(localFile: file.local, to: file.remote, replaceExisting: false) }
        XCTAssertEqual(try String(contentsOfFile: work + "/My Kit/Loops/loop.wav", encoding: .utf8), "loop")
        XCTAssertEqual(try String(contentsOfFile: work + "/My Kit/kick.wav", encoding: .utf8), "kick")
        XCTAssertFalse(exists(work + "/My Kit/.DS_Store"))
    }

    // MARK: Safety

    func testSystemAreasAreRefused() throws {
        let canary = "/media/az01-internal/system/etc/overlay/passwd"
        XCTAssertTrue(exists(canary))
        let source = try localFile("s.bin", Data("abc".utf8))

        for path in ["/", "/etc", "/media", "/media/az01-internal", "/media/az01-internal/system", "/media/ramdisk",
                     "/root", "/media/az01-internal-sdx/../az01-internal"] {
            do {
                _ = try fs.list(path)
                XCTFail("listing \(path) should be refused")
            } catch let error as RemoteFileError {
                XCTAssertTrue([.notAllowed, .invalidName].contains(error.kind), "\(path): \(error)")
            }
        }
        assertFileError(.notAllowed) { try fs.delete(canary) }
        assertFileError(.notAllowed) { try fs.delete("/media/az01-internal/system") }
        assertFileError(.notAllowed) { try fs.delete("/media/az01-internal") }
        assertFileError(.notAllowed) { try fs.delete("/etc/az01-release") }
        assertFileError(.notAllowed) { try fs.delete(usb) }
        assertFileError(.notAllowed) { try fs.delete("/nvme") }
        assertFileError(.notAllowed) { try fs.makeDirectory("/media/new-drive") }
        assertFileError(.notAllowed) { try fs.makeDirectory("/media/ramdisk/x") }
        assertFileError(.notAllowed) { try fs.upload(localFile: source, to: "/etc/mpcl-upload", replaceExisting: true) }
        assertFileError(.notAllowed) { try fs.upload(localFile: source, to: canary, replaceExisting: true) }
        assertFileError(.notAllowed) { try fs.move(work, to: "/etc/moved") }
        assertFileError(.notAllowed) { try fs.move(canary, to: work + "/passwd") }
        assertFileError(.notAllowed) { try fs.download(remoteFile: canary, to: scratch.appendingPathComponent("passwd")) }
        assertFileError(.invalidName) { try fs.delete(usb + "/../az01-internal/system") }

        XCTAssertTrue(exists(canary))
        XCTAssertTrue(exists("/etc/az01-release"))
        XCTAssertFalse(exists("/etc/mpcl-upload"))
        XCTAssertFalse(exists("/etc/moved"))
        XCTAssertTrue(exists(work))
    }

    func testReadOnlyDrivesCanBeReadButNotChanged() throws {
        let factory = "/media/acvs-content/Expansions/Factory Kit"
        let source = try localFile("s.bin", Data("abc".utf8))
        XCTAssertEqual(try fs.list(factory).map(\.name), ["kick.wav"])
        let copy = scratch.appendingPathComponent("kick.wav")
        try fs.download(remoteFile: factory + "/kick.wav", to: copy)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "RIFFfactory")

        assertFileError(.readOnly) { try fs.delete(factory + "/kick.wav") }
        assertFileError(.readOnly) { try fs.delete(factory) }
        assertFileError(.readOnly) { try fs.makeDirectory(factory + "/New") }
        assertFileError(.readOnly) { try fs.upload(localFile: source, to: factory + "/new.wav", replaceExisting: true) }
        assertFileError(.readOnly) { try fs.move(factory + "/kick.wav", to: factory + "/k.wav") }
        assertFileError(.readOnly) { try fs.delete("/media/LOCKED/readme.txt") }
        XCTAssertTrue(exists(factory + "/kick.wav"))
        XCTAssertTrue(exists("/media/LOCKED/readme.txt"))
        XCTAssertEqual(try fs.list("/media/LOCKED").map(\.name), ["readme.txt"])
    }

    func testLinksCannotBeUsedToEscapeADrive() throws {
        let canary = "/etc/mpcl-canary"
        try Data("canary".utf8).write(to: URL(fileURLWithPath: canary))
        defer { try? FileManager.default.removeItem(atPath: canary) }
        try FileManager.default.createSymbolicLink(atPath: work + "/escape", withDestinationPath: "/etc")
        try FileManager.default.createSymbolicLink(atPath: work + "/system", withDestinationPath: "/media/az01-internal")
        try FileManager.default.createSymbolicLink(atPath: work + "/filelink", withDestinationPath: canary)
        try Data("mine".utf8).write(to: URL(fileURLWithPath: work + "/mine.wav"))
        let source = try localFile("s.bin", Data("abc".utf8))

        assertFileError(.notAllowed) { _ = try fs.list(work + "/escape") }
        assertFileError(.notAllowed) { _ = try fs.list(work + "/system") }
        assertFileError(.notAllowed) { try fs.makeDirectory(work + "/escape/mpcl-dir") }
        assertFileError(.notAllowed) { try fs.upload(localFile: source, to: work + "/escape/mpcl-upload", replaceExisting: true) }
        assertFileError(.notAllowed) { try fs.upload(localFile: source, to: work + "/escape/mpcl-canary", replaceExisting: true) }
        assertFileError(.notAllowed) { try fs.delete(work + "/escape/mpcl-canary") }
        assertFileError(.notAllowed) { try fs.delete(work + "/system/system") }
        assertFileError(.notAllowed) { try fs.move(work + "/mine.wav", to: work + "/escape/mine.wav") }
        assertFileError(.notAllowed) { try fs.move(work + "/escape/mpcl-canary", to: work + "/stolen") }
        assertFileError(.notAllowed) { try fs.download(remoteFile: work + "/escape/mpcl-canary", to: scratch.appendingPathComponent("c1")) }
        assertFileError(.unsupportedItem) { try fs.download(remoteFile: work + "/filelink", to: scratch.appendingPathComponent("c2")) }

        XCTAssertEqual(try String(contentsOfFile: canary, encoding: .utf8), "canary")
        XCTAssertFalse(exists("/etc/mpcl-dir"))
        XCTAssertFalse(exists("/etc/mpcl-upload"))
        XCTAssertFalse(exists("/etc/mine.wav"))
        XCTAssertTrue(exists("/media/az01-internal/system"))

        // Uploading over a link replaces the link itself, never the file it points to.
        try fs.upload(localFile: source, to: work + "/filelink", replaceExisting: true)
        XCTAssertEqual(try String(contentsOfFile: canary, encoding: .utf8), "canary")
        XCTAssertEqual(try String(contentsOfFile: work + "/filelink", encoding: .utf8), "abc")

        // Deleting a link removes the link, never what it points to.
        try fs.delete(work + "/escape")
        try fs.delete(work + "/system")
        XCTAssertFalse(exists(work + "/escape"))
        XCTAssertTrue(exists(canary))
        XCTAssertTrue(exists("/etc/az01-release"))
        XCTAssertTrue(exists("/media/az01-internal/system/etc/overlay/passwd"))
    }

    func testDriveRemovedMidSessionIsNotWrittenTo() throws {
        let mount = "/media/TEMPSTICK-" + String(UUID().uuidString.prefix(6))
        let backing = "/srv/fake-mpc/temp-" + String(UUID().uuidString.prefix(6))
        try shell("mkdir -p '\(backing)' '\(mount)' && mount --bind '\(backing)' '\(mount)'")
        var mounted = true
        defer {
            if mounted { try? shell("umount '\(mount)'") }
            try? shell("rm -rf '\(mount)' '\(backing)'")
        }
        try fs.refreshDrives()
        XCTAssertTrue(fs.drives.contains { $0.mountPoint == mount })
        let source = try localFile("s.bin", Data("abc".utf8))
        try fs.upload(localFile: source, to: mount + "/before.wav", replaceExisting: false)
        XCTAssertTrue(exists(backing + "/before.wav"))

        // The drive is pulled out. The folder is still there, but it is no longer the drive.
        try shell("umount '\(mount)'")
        mounted = false
        assertFileError(.driveGone) { try fs.upload(localFile: source, to: mount + "/after.wav", replaceExisting: false) }
        assertFileError(.driveGone) { try fs.makeDirectory(mount + "/Folder") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mount), [], "nothing was written to the MPC's own disk")

        try fs.refreshDrives()
        XCTAssertFalse(fs.drives.contains { $0.mountPoint == mount })
        assertFileError(.notAllowed) { _ = try fs.list(mount) }
    }

    // MARK: FAT drives (most SD cards and USB sticks)

    func testFATDrive() throws {
        guard !target.fatDrives.isEmpty else { throw XCTSkip("no exFAT or FAT drive in this environment") }
        for fat in target.fatDrives { try checkWindowsStyleDrive(fat) }
    }

    private func checkWindowsStyleDrive(_ fat: String) throws {
        let drive = try XCTUnwrap(fs.drives.first { $0.mountPoint == fat })
        XCTAssertTrue(drive.usesWindowsNaming, "\(drive.fileSystem)")
        XCTAssertTrue(drive.isWritable)
        let folder = fat + "/t-" + String(UUID().uuidString.prefix(6))
        try fs.makeDirectory(folder)
        defer { try? fs.delete(folder) }
        let payload = randomData(200_000)
        let source = try localFile("fat.bin", payload)

        // The plan leaves out names this format refuses, so they never reach the drive.
        let odd = scratch.appendingPathComponent("odd?name.wav")
        try payload.write(to: odd)
        let plan = TransferPlan.upload(items: [odd], into: folder, drive: drive)
        XCTAssertEqual(plan.files, [])
        XCTAssertEqual(plan.skipped, [SkippedItem(name: "odd?name.wav", reason: .nameNotAllowed)])
        assertFileError(.alreadyExists) { try fs.makeDirectory(folder) }

        try fs.upload(localFile: source, to: folder + "/kick.wav", replaceExisting: false)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: folder + "/kick.wav")), payload)

        // Changing only the capitals works even though FAT treats both names as the same file.
        try fs.move(folder + "/kick.wav", to: folder + "/KICK.wav")
        XCTAssertEqual(try fs.list(folder).map(\.name), ["KICK.wav"])

        // FAT does not allow some characters. The upload is refused cleanly, with nothing left behind.
        assertFileError(.writeFailed) { try fs.upload(localFile: source, to: folder + "/what?.wav", replaceExisting: false) }
        XCTAssertEqual(try fs.list(folder).map(\.name), ["KICK.wav"])

        let back = scratch.appendingPathComponent("fat-back.bin")
        try fs.download(remoteFile: folder + "/KICK.wav", to: back)
        XCTAssertEqual(try Data(contentsOf: back), payload)
    }

    func testFullDriveIsReported() throws {
        guard let small = target.smallDrive else { throw XCTSkip("no small drive in this environment") }
        let folder = small + "/t-" + String(UUID().uuidString.prefix(6))
        try fs.makeDirectory(folder)
        defer { try? fs.delete(folder) }
        let big = scratch.appendingPathComponent("toobig.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: 80_000_000)
        try handle.close()
        assertFileError(.noSpace) { try fs.upload(localFile: big, to: folder + "/toobig.wav", replaceExisting: false) }
        XCTAssertEqual(try fs.list(folder), [], "the partial copy was removed")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var latest: Int64 = -1

    func increment() { lock.lock(); count += 1; lock.unlock() }
    func record(_ value: Int64) { lock.lock(); latest = value; count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    var last: Int64 { lock.lock(); defer { lock.unlock() }; return latest }
}
