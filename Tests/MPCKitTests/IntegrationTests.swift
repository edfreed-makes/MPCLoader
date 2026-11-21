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
    /// The test's own folder on the stand-in MPC. Empty until setUp has made it.
    var work = ""
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
        if !work.isEmpty { try? fs?.delete(work) }
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
        XCTAssertTrue(info.hasMD5)
        // A server that allows few sessions per connection gets its copies one at a time.
        XCTAssertEqual(fs.parallelCopies, target.mode == "few-sessions" ? 1 : RemoteFileSystem.preferredParallelCopies)

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
        try shell("truncate -s 400000000 '\(work)/big.wav'")
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
        try shell("mkdir -p '\(work)/Kit/Sub' && printf abc > '\(work)/Kit/a.wav' && printf defgh > '\(work)/Kit/Sub/b.wav' && ln -s /etc '\(work)/Kit/link' && printf z > '\(work)/loose.wav'")
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

    func testExportReadsWithoutTouchingTheMPC() throws {
        try shell("mkdir -p '\(work)/Kit/Sub' && printf abc > '\(work)/Kit/a.wav' && printf defgh > '\(work)/Kit/Sub/b.wav' && ln -s /etc '\(work)/Kit/link' && printf 0123456789 > '\(work)/Kick 01.wav'")
        func snapshot() throws -> [String] { try FileManager.default.subpathsOfDirectory(atPath: work).sorted() }
        let before = try snapshot()
        let entries = try fs.list(work)

        // A single file, as used for a preview.
        let kick = try XCTUnwrap(entries.first { $0.name == "Kick 01.wav" })
        let seen = Counter()
        let single = try fs.export(kick, into: scratch.appendingPathComponent("preview")) { done, _ in seen.record(done) }
        XCTAssertEqual(single.url.lastPathComponent, "Kick 01.wav")
        XCTAssertEqual(try String(contentsOf: single.url, encoding: .utf8), "0123456789")
        XCTAssertEqual(single.files, 1)
        XCTAssertEqual(seen.last, 10)

        // A whole folder, as used when one is dragged out to Finder.
        let kit = try XCTUnwrap(entries.first { $0.name == "Kit" })
        let folder = try fs.export(kit, into: scratch.appendingPathComponent("dragged"))
        XCTAssertEqual(folder.url.lastPathComponent, "Kit")
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: folder.url.path).sorted(), ["Sub", "Sub/b.wav", "a.wav"])
        XCTAssertEqual(folder.bytes, 8)
        XCTAssertEqual(folder.skipped, [SkippedItem(name: "Kit/link", reason: .link)])

        // A link is refused rather than followed.
        let link = RemoteEntry(path: work + "/Kit/link", name: "link", kind: .link, size: 0, modified: nil)
        assertFileError(.unsupportedItem) { _ = try fs.export(link, into: scratch.appendingPathComponent("x")) }

        // The same name twice on the Mac gets a number, never a replacement.
        let again = try fs.export(kick, into: scratch.appendingPathComponent("preview"))
        XCTAssertEqual(again.url.lastPathComponent, "Kick 01 2.wav")

        XCTAssertEqual(try snapshot(), before, "previews and drags leave nothing behind on the MPC")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: usb).filter { $0.contains("mpcl") }, [])
    }

    func testConflictsAreCountedAndKeepBothLeavesEverythingInPlace() throws {
        // On the MPC already: a kit with two samples and a nested one, plus a loose sample.
        try shell("mkdir -p '\(work)/Kit/Sub' && printf old > '\(work)/Kit/kick.wav' && printf old > '\(work)/Kit/only-on-mpc.wav' && printf old > '\(work)/Kit/Sub/snare.wav' && printf old > '\(work)/loose.wav'")
        // On the Mac: the same kit with changes, the loose sample, and something new.
        let kit = scratch.appendingPathComponent("Kit")
        try FileManager.default.createDirectory(at: kit.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: kit.appendingPathComponent("Brand New"), withIntermediateDirectories: true)
        for (path, text) in [("kick.wav", "new"), ("extra.wav", "new"), ("Sub/snare.wav", "new"), ("Sub/hat.wav", "new"),
                             ("Brand New/tom.wav", "new")] {
            try Data(text.utf8).write(to: kit.appendingPathComponent(path))
        }
        let loose = try localFile("loose.wav", Data("new".utf8))
        let fresh = try localFile("fresh.wav", Data("new".utf8))
        let drive = try XCTUnwrap(fs.drives.first { $0.mountPoint == usb })

        let plan = TransferPlan.upload(items: [kit, loose, fresh], into: work, drive: drive)
        let found = try TransferPlan.conflicts(for: plan, in: work, drive: drive, fileSystem: fs)
        XCTAssertEqual(found.names, ["Kit", "loose.wav"])
        XCTAssertEqual(Set(found.filesToReplace), [work + "/Kit/kick.wav", work + "/Kit/Sub/snare.wav", work + "/loose.wav"],
                       "only files that are really there are counted, however deep")
        XCTAssertTrue(found.mergesFolders)
        XCTAssertEqual(Set(found.existingNames), ["Kit", "loose.wav"])

        // Nothing clashes when the destination is empty.
        try fs.makeDirectory(work + "/Empty")
        let clear = try TransferPlan.conflicts(for: TransferPlan.upload(items: [kit], into: work + "/Empty", drive: drive),
                                               in: work + "/Empty", drive: drive, fileSystem: fs)
        XCTAssertTrue(clear.isEmpty)
        XCTAssertEqual(clear.filesToReplace, [])

        // Capitals: the drive decides whether "LOOSE.WAV" is the same file as "loose.wav".
        let shouty = try localFile("LOOSE.WAV", Data("new".utf8))
        let capitals = try TransferPlan.conflicts(for: TransferPlan.upload(items: [shouty], into: work, drive: drive),
                                                  in: work, drive: drive, fileSystem: fs)
        XCTAssertEqual(capitals.names.isEmpty, !drive.usesWindowsNaming)

        // Keep Both: everything lands under new names and the originals are exactly as they were.
        let kept = plan.keepingBoth(found.names, existingNames: found.existingNames + ["Empty"], in: work)
        for folder in kept.directories { try fs.makeDirectory(folder, existingIsFine: true) }
        for file in kept.files { try fs.upload(localFile: file.local, to: file.remote, replaceExisting: false) }
        for untouched in ["Kit/kick.wav", "Kit/only-on-mpc.wav", "Kit/Sub/snare.wav", "loose.wav"] {
            XCTAssertEqual(try String(contentsOfFile: work + "/" + untouched, encoding: .utf8), "old", untouched)
        }
        for copied in ["Kit 2/kick.wav", "Kit 2/extra.wav", "Kit 2/Sub/snare.wav", "Kit 2/Sub/hat.wav", "Kit 2/Brand New/tom.wav",
                       "loose 2.wav", "fresh.wav"] {
            XCTAssertEqual(try String(contentsOfFile: work + "/" + copied, encoding: .utf8), "new", copied)
        }
        XCTAssertFalse(exists(work + "/Kit/extra.wav"), "nothing was added to the folder that was already there")
    }

    func testManyFilesCopySideBySide() throws {
        // A kit of small samples plus two "large" files, sent up and brought back.
        let kit = scratch.appendingPathComponent("Big Kit")
        try FileManager.default.createDirectory(at: kit.appendingPathComponent("Loops"), withIntermediateDirectories: true)
        var expected: [String: Data] = [:]
        for index in 0..<60 {
            let name = index % 5 == 0 ? "Loops/loop \(index).wav" : "hit \(index).wav"
            let data = randomData(2_000 + index * 37)
            try data.write(to: kit.appendingPathComponent(name))
            expected[name] = data
        }
        for name in ["long take 1.wav", "long take 2.wav"] {
            let data = randomData(9_000_000)
            try data.write(to: kit.appendingPathComponent(name))
            expected[name] = data
        }
        let drive = try XCTUnwrap(fs.drives.first { $0.mountPoint == usb })
        let plan = TransferPlan.upload(items: [kit], into: work, drive: drive)
        XCTAssertEqual(plan.files.count, 62)

        let last = LastProgress()
        let up = fs.uploadBatch(plan, replaceExisting: false) { last.set($0) }
        XCTAssertEqual(up.copied, 62)
        XCTAssertEqual(up.failures, [])
        XCTAssertNil(up.stoppedBecause)
        XCTAssertEqual(last.value.finishedFiles, 62)
        XCTAssertEqual(last.value.copiedBytes, plan.totalBytes)
        for (name, data) in expected {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: work + "/Big Kit/" + name)), data, name)
        }
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: work).filter { $0.contains("mpcl") }, [])

        // Sending it again without permission to replace fails file by file and changes nothing.
        let again = fs.uploadBatch(plan, replaceExisting: false)
        XCTAssertEqual(again.copied, 0)
        XCTAssertEqual(again.failures.count, 62)

        // And back to the Mac.
        let entries = try fs.list(work).filter { $0.name == "Big Kit" }
        let back = scratch.appendingPathComponent("back")
        try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
        let down = fs.downloadBatch(try TransferPlan.download(entries: entries, into: back, fileSystem: fs))
        XCTAssertEqual(down.copied, 62)
        XCTAssertEqual(down.failures, [])
        for (name, data) in expected {
            XCTAssertEqual(try Data(contentsOf: back.appendingPathComponent("Big Kit/" + name)), data, name)
        }
    }

    func testCancellingASideBySideCopyLeavesNoPartFiles() throws {
        let folder = scratch.appendingPathComponent("Cancel Me")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<40 {
            FileManager.default.createFile(atPath: folder.appendingPathComponent("f\(index).wav").path, contents: nil)
            let handle = try FileHandle(forWritingTo: folder.appendingPathComponent("f\(index).wav"))
            try handle.truncate(atOffset: 4_000_000)
            try handle.close()
        }
        let plan = TransferPlan.upload(items: [folder], into: work)
        let control = CommandControl()
        let outcome = fs.uploadBatch(plan, replaceExisting: false, control: control) { state in
            if state.finishedFiles >= 3 { control.cancel() }
        }
        XCTAssertTrue(outcome.cancelled)
        XCTAssertLessThan(outcome.copied, 40)
        // Whatever arrived is whole, and nothing half-written is left under a temporary name.
        let deadline = Date().addingTimeInterval(20)
        var names: [String] = []
        repeat {
            names = (try? FileManager.default.contentsOfDirectory(atPath: work + "/Cancel Me")) ?? []
            if !names.contains(where: { $0.contains("mpcl") }) { break }
            usleep(200_000)
        } while Date() < deadline
        XCTAssertEqual(names.filter { $0.contains("mpcl") }, [])
        for name in names {
            let size = try FileManager.default.attributesOfItem(atPath: work + "/Cancel Me/" + name)[.size] as? Int
            XCTAssertEqual(size, 4_000_000, name)
        }
        XCTAssertEqual(try session.run("echo ok").text, "ok\n")
    }

    func testFilesAlreadyOnTheMPCAreRecognised() throws {
        // On the MPC: a kit holding one file we also have, one we have changed, and one of a different length.
        let same = randomData(50_000)
        let kit = scratch.appendingPathComponent("Kit")
        try FileManager.default.createDirectory(at: kit.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: work + "/Kit/Sub", withIntermediateDirectories: true)
        try same.write(to: URL(fileURLWithPath: work + "/Kit/it's the same $1.wav"))
        try same.write(to: kit.appendingPathComponent("it's the same $1.wav"))
        try randomData(50_000).write(to: URL(fileURLWithPath: work + "/Kit/changed.wav"))
        try randomData(50_000).write(to: kit.appendingPathComponent("changed.wav"))
        try randomData(10).write(to: URL(fileURLWithPath: work + "/Kit/shorter.wav"))
        try randomData(20).write(to: kit.appendingPathComponent("shorter.wav"))
        try same.write(to: URL(fileURLWithPath: work + "/Kit/Sub/deep.wav"))
        try same.write(to: kit.appendingPathComponent("Sub/deep.wav"))
        try same.write(to: kit.appendingPathComponent("brand new.wav"))
        // And a whole item that is already across, plus an empty file.
        try same.write(to: URL(fileURLWithPath: work + "/done.wav"))
        let done = try localFile("done.wav", same)
        try Data().write(to: URL(fileURLWithPath: work + "/empty.wav"))
        let empty = try localFile("empty.wav", Data())
        let drive = try XCTUnwrap(fs.drives.first { $0.mountPoint == usb })

        // Full paths in the test folder. Built one at a time: a long list of joined
        // strings in one expression is more than current compilers will type-check quickly.
        let base: String = work
        func inWork(_ names: String...) -> Set<String> { Set(names.map { base + "/" + $0 }) }

        let plan = TransferPlan.upload(items: [kit, done, empty], into: work, drive: drive)
        let found = try TransferPlan.conflicts(for: plan, in: work, drive: drive, fileSystem: fs)
        XCTAssertEqual(Set(found.identical), inWork("Kit/it's the same $1.wav", "Kit/Sub/deep.wav", "done.wav", "empty.wav"))
        XCTAssertEqual(Set(found.filesToReplace), inWork("Kit/changed.wav", "Kit/shorter.wav"))
        XCTAssertEqual(found.names, ["Kit", "done.wav", "empty.wav"])
        XCTAssertEqual(found.settledNames(in: plan, directory: work), ["done.wav", "empty.wav"])
        XCTAssertEqual(Set(found.existingFolders), inWork("Kit", "Kit/Sub"))

        // Replace: only what differs or is new travels.
        let needed = plan.removing(found.settledNames(in: plan, directory: work), in: work)
            .leavingOut(identical: found.identical, existingFolders: found.existingFolders)
        XCTAssertEqual(Set(needed.files.map(\.remote)), inWork("Kit/changed.wav", "Kit/shorter.wav", "Kit/brand new.wav"))
        let outcome = fs.uploadBatch(needed, replaceExisting: true)
        XCTAssertEqual(outcome.copied, 3)
        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: work + "/Kit/changed.wav")),
                       try Data(contentsOf: kit.appendingPathComponent("changed.wav")))

        // Now everything is across: a second look finds nothing left to do.
        let after = try TransferPlan.conflicts(for: plan, in: work, drive: drive, fileSystem: fs)
        XCTAssertEqual(after.filesToReplace, [])
        XCTAssertEqual(after.identical.count, plan.files.count)
        XCTAssertEqual(after.settledNames(in: plan, directory: work), ["Kit", "done.wav", "empty.wav"])

        // A link is never followed to make the comparison, and a device with no checksum command compares nothing.
        try FileManager.default.removeItem(atPath: work + "/done.wav")
        try FileManager.default.createSymbolicLink(atPath: work + "/done.wav", withDestinationPath: work + "/Kit/Sub/deep.wav")
        XCTAssertEqual(try fs.checksums(inFolder: work, names: ["done.wav", "empty.wav", "missing.wav"]),
                       ["empty.wav": "d41d8cd98f00b204e9800998ecf8427e"])
        fs.overrideChecksums(available: false)
        let blind = try TransferPlan.conflicts(for: plan, in: work, drive: drive, fileSystem: fs)
        XCTAssertEqual(blind.identical, [], "without checksums nothing is assumed to be identical")
        XCTAssertTrue(blind.filesToReplace.contains(work + "/Kit/it's the same $1.wav"))
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
