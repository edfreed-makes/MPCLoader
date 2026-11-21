import XCTest
@testable import MPCKit

final class RemotePathTests: XCTestCase {
    func testQuoteKeepsEverythingLiteral() {
        XCTAssertEqual(Shell.quote("plain"), "'plain'")
        XCTAssertEqual(Shell.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(Shell.quote("$(rm -rf /) `x` \"y\""), "'$(rm -rf /) `x` \"y\"'")
    }

    func testNormaliseAcceptsCleanPaths() {
        XCTAssertEqual(RemotePath.normalise("/media/USB"), "/media/USB")
        XCTAssertEqual(RemotePath.normalise("/media//USB/"), "/media/USB")
        XCTAssertEqual(RemotePath.normalise("/media/MY USB/Kits & Loops"), "/media/MY USB/Kits & Loops")
        XCTAssertEqual(RemotePath.normalise("/"), "/")
    }

    func testNormaliseRejectsTraversalAndOddities() {
        XCTAssertNil(RemotePath.normalise("media/USB"))
        XCTAssertNil(RemotePath.normalise(""))
        XCTAssertNil(RemotePath.normalise("/media/USB/../../etc"))
        XCTAssertNil(RemotePath.normalise("/media/USB/./x"))
        XCTAssertNil(RemotePath.normalise("/media/USB/a\nb"))
        XCTAssertNil(RemotePath.normalise("/media/USB/a\u{0}b"))
    }

    func testValidNames() {
        XCTAssertTrue(RemotePath.isValidName("Kick 01.wav"))
        XCTAssertTrue(RemotePath.isValidName("-rf"))
        XCTAssertTrue(RemotePath.isValidName("..hidden"))
        XCTAssertFalse(RemotePath.isValidName(""))
        XCTAssertFalse(RemotePath.isValidName("."))
        XCTAssertFalse(RemotePath.isValidName(".."))
        XCTAssertFalse(RemotePath.isValidName("a/b"))
        XCTAssertFalse(RemotePath.isValidName("a\tb"))
        XCTAssertFalse(RemotePath.isValidName(String(repeating: "x", count: 256)))
    }

    func testInsideIsNotFooledByLookalikeNames() {
        XCTAssertTrue(RemotePath.isInside("/media/USB", root: "/media/USB"))
        XCTAssertTrue(RemotePath.isInside("/media/USB/a", root: "/media/USB"))
        XCTAssertFalse(RemotePath.isInside("/media/USB2", root: "/media/USB"))
        XCTAssertFalse(RemotePath.isInside("/media", root: "/media/USB"))
    }

    func testPathPieces() {
        XCTAssertEqual(RemotePath.parent(of: "/media/USB/a.wav"), "/media/USB")
        XCTAssertEqual(RemotePath.parent(of: "/nvme"), "/")
        XCTAssertEqual(RemotePath.lastComponent(of: "/media/USB/a.wav"), "a.wav")
        XCTAssertEqual(RemotePath.join("/media/USB", "a.wav"), "/media/USB/a.wav")
        XCTAssertEqual(RemotePath.components(of: "/media/MY USB/Kits/808", below: "/media/MY USB"), ["Kits", "808"])
        XCTAssertEqual(RemotePath.components(of: "/media/MY USB", below: "/media/MY USB"), [])
    }
}

final class StorageRulesTests: XCTestCase {
    /// Modelled on a real MPC: system data on az01-internal, user storage on az01-internal-sd,
    /// factory content on the acvs partitions, plus a USB stick and an SD card.
    static let mounts = """
    /dev/root / ext4 ro,relatime 0 0
    devtmpfs /dev devtmpfs rw,relatime,size=952056k 0 0
    proc /proc proc rw,relatime 0 0
    sysfs /sys sysfs rw,relatime 0 0
    tmpfs /tmp tmpfs rw,relatime 0 0
    tmpfs /media tmpfs rw,relatime 0 0
    /dev/mmcblk2p7 /media/az01-internal ext4 rw,relatime 0 0
    overlay /etc overlay rw,relatime,lowerdir=/etc,upperdir=/media/az01-internal/system/etc/overlay,workdir=/media/az01-internal/system/etc/.work 0 0
    overlay /var overlay rw,relatime,lowerdir=/var,upperdir=/media/az01-internal/system/var/overlay,workdir=/media/az01-internal/system/var/.work 0 0
    /dev/mmcblk0p1 /media/az01-internal-sd ext4 rw,relatime 0 0
    /dev/mmcblk2p5 /media/acvs-synths ext4 ro,relatime 0 0
    /dev/mmcblk2p6 /media/acvs-content ext4 rw,relatime 0 0
    /dev/sda1 /media/MY\\040USB vfat rw,relatime,utf8 0 0
    /dev/sdb1 /media/LOCKED exfat ro,relatime 0 0
    tmpfs /media/ramdisk tmpfs rw 0 0
    """

    static let df = """
    Filesystem     1024-blocks    Used Available Capacity Mounted on
    /dev/root           999320  812344    118164      88% /
    /dev/mmcblk0p1    15023000 5000000  10023000      34% /media/az01-internal-sd
    /dev/sda1         30000000 1000000  29000000       4% /media/MY USB
    """

    func testClassification() {
        XCTAssertEqual(StorageRules.classify(mountPoint: "/nvme"), .allowed(.internalStorage))
        XCTAssertEqual(StorageRules.classify(mountPoint: "/media/az01-internal-sd"), .allowed(.internalStorage))
        XCTAssertEqual(StorageRules.classify(mountPoint: "/media/az01-internal"), .system)
        XCTAssertEqual(StorageRules.classify(mountPoint: "/media/az01-internal-other"), .system)
        XCTAssertEqual(StorageRules.classify(mountPoint: "/media/acvs-synths"), .allowed(.factoryContent))
        XCTAssertEqual(StorageRules.classify(mountPoint: "/media/acvs-content"), .allowed(.factoryContent))
        XCTAssertEqual(StorageRules.classify(mountPoint: "/media/SANDISK"), .allowed(.removable))
        XCTAssertEqual(StorageRules.classify(mountPoint: "/"), .notStorage)
        XCTAssertEqual(StorageRules.classify(mountPoint: "/etc"), .notStorage)
        XCTAssertEqual(StorageRules.classify(mountPoint: "/media"), .notStorage)
        XCTAssertEqual(StorageRules.classify(mountPoint: "/mediafake/x"), .notStorage)
    }

    func testParseShowsOnlyUserStorage() {
        let snapshot = StorageRules.parse(mounts: Self.mounts, df: Self.df)
        XCTAssertEqual(snapshot.drives.map(\.mountPoint),
                       ["/media/az01-internal-sd", "/media/LOCKED", "/media/MY USB", "/media/acvs-content", "/media/acvs-synths"])
        XCTAssertEqual(snapshot.blockedMountPoints, ["/media/az01-internal", "/media/ramdisk"])
    }

    func testAccessLevels() {
        let drives = StorageRules.parse(mounts: Self.mounts, df: Self.df).drives
        func drive(_ mount: String) -> Drive { drives.first { $0.mountPoint == mount }! }
        XCTAssertTrue(drive("/media/az01-internal-sd").isWritable)
        XCTAssertTrue(drive("/media/MY USB").isWritable)
        XCTAssertFalse(drive("/media/LOCKED").isWritable, "a drive mounted read-only stays read-only")
        XCTAssertFalse(drive("/media/acvs-content").isWritable, "factory content is read-only even when mounted writable")
        XCTAssertFalse(drive("/media/acvs-synths").isWritable)
    }

    func testSpacesAndSizes() {
        let drives = StorageRules.parse(mounts: Self.mounts, df: Self.df).drives
        let usb = drives.first { $0.mountPoint == "/media/MY USB" }!
        XCTAssertEqual(usb.rawMountField, "/media/MY\\040USB")
        XCTAssertEqual(usb.name, "MY USB")
        XCTAssertEqual(usb.displayName, "MY USB")
        XCTAssertEqual(usb.totalBytes, 30_000_000 * 1024)
        XCTAssertEqual(usb.freeBytes, 29_000_000 * 1024)
        XCTAssertEqual(drives.first?.displayName, "Internal Storage")
    }

    func testUnescape() {
        XCTAssertEqual(StorageRules.unescapeMountField("/media/MY\\040USB"), "/media/MY USB")
        XCTAssertEqual(StorageRules.unescapeMountField("/media/a\\134b"), "/media/a\\b")
        XCTAssertEqual(StorageRules.unescapeMountField("/media/plain"), "/media/plain")
        XCTAssertEqual(StorageRules.unescapeMountField("/media/end\\04"), "/media/end\\04")
    }

    func testNvmeModel() {
        let mounts = """
        /dev/nvme0n1p3 /nvme ext4 rw,relatime 0 0
        /dev/nvme0n1p2 /media/acvs-content ext4 rw,relatime 0 0
        /dev/sda1 /media/T7 exfat rw,relatime 0 0
        """
        let snapshot = StorageRules.parse(mounts: mounts, df: "")
        XCTAssertEqual(snapshot.drives.map(\.mountPoint), ["/nvme", "/media/T7", "/media/acvs-content"])
        XCTAssertEqual(snapshot.drives.map(\.kind), [.internalStorage, .removable, .factoryContent])
    }

    func testWindowsNamingRules() {
        let drives = StorageRules.parse(mounts: Self.mounts, df: Self.df).drives
        let fat = drives.first { $0.mountPoint == "/media/MY USB" }!
        let ext = drives.first { $0.mountPoint == "/media/az01-internal-sd" }!
        XCTAssertTrue(fat.usesWindowsNaming)
        XCTAssertFalse(ext.usesWindowsNaming)
        for bad in ["a\"b", "a*b", "a:b", "a<b", "a>b", "a?b", "a\\b", "a|b", "ends ", "ends."] {
            XCTAssertNotNil(fat.problem(withName: bad), bad)
        }
        XCTAssertNotNil(fat.problem(withName: "a:b"))
        XCTAssertNotNil(fat.problem(withName: "ends."))
        XCTAssertNotNil(fat.problem(withName: ""))
        XCTAssertNotNil(ext.problem(withName: "a/b"))
        XCTAssertNil(fat.problem(withName: "Fine Name.wav"))
        XCTAssertNil(ext.problem(withName: "a:b?"))
        XCTAssertEqual(fat.maximumFileSize, 4_294_967_295)
        XCTAssertNil(ext.maximumFileSize)
        XCTAssertEqual(fat.formatDescription, "FAT32")
    }

    func testOddMountLinesAreIgnored() {
        let mounts = """
        garbage
        /dev/sda1 /media/../etc vfat rw 0 0
        /dev/sda2 /media/ok vfat rw 0 0
        """
        XCTAssertEqual(StorageRules.parse(mounts: mounts, df: "").drives.map(\.mountPoint), ["/media/ok"])
    }
}

final class ListingParserTests: XCTestCase {
    func testStatLines() {
        let output = """
        41ed|4096|1700000000|./Kits
        81a4|123456|1700000100|./Kick 01.wav
        81a4|0|1700000200|./odd|name.wav
        a1ff|9|1700000300|./link
        1180|0|1700000400|./pipe
        81a4|10|1700000500|./.hidden
        not a line
        81a4|x|1700000500|./bad-size
        """
        let entries = ListingParser.parseStat(output, directory: "/media/USB")
        XCTAssertEqual(entries.map(\.name), ["Kits", "Kick 01.wav", "odd|name.wav", "link", "pipe", ".hidden"])
        XCTAssertEqual(entries.map(\.kind), [.directory, .file, .file, .link, .other, .file])
        XCTAssertEqual(entries[1].size, 123456)
        XCTAssertEqual(entries[0].size, 0, "folders have no size")
        XCTAssertEqual(entries[1].path, "/media/USB/Kick 01.wav")
        XCTAssertEqual(entries[1].modified, Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertTrue(entries[5].isHidden)
    }

    func testFallbackListingHasNoDates() {
        let entries = ListingParser.parseStat("81a4|12|0|./a.wav\n41ed|0|0|./Kits\n", directory: "/media/USB")
        XCTAssertEqual(entries.map(\.name), ["a.wav", "Kits"])
        XCTAssertEqual(entries.map(\.size), [12, 0])
        XCTAssertNil(entries[0].modified)
    }

    func testKindDescriptions() {
        func kind(_ name: String) -> String {
            RemoteEntry(path: "/x/" + name, name: name, kind: .file, size: 1, modified: nil).kindDescription
        }
        XCTAssertEqual(kind("a.WAV"), "WAV audio")
        XCTAssertEqual(kind("a.xpm"), "MPC program")
        XCTAssertEqual(kind("a.xyz"), "XYZ file")
        XCTAssertEqual(kind("Beat.xpj"), "MPC project")
        XCTAssertEqual(kind("loop.FLAC"), "FLAC audio")
        XCTAssertEqual(kind("README"), "Document")
        XCTAssertEqual(RemoteEntry(path: "/x/d", name: "d", kind: .directory, size: 0, modified: nil).kindDescription, "Folder")
    }
}

final class SSHErrorTests: XCTestCase {
    func testClassify() {
        XCTAssertEqual(SSHError.classify(stderr: "root@192.168.1.5: Permission denied (publickey,password)."), .auth)
        XCTAssertEqual(SSHError.classify(stderr: "ssh: connect to host 192.168.1.5 port 22: Connection refused"), .refused)
        XCTAssertEqual(SSHError.classify(stderr: "ssh: Could not resolve hostname nope: nodename nor servname provided"), .dns)
        XCTAssertEqual(SSHError.classify(stderr: "ssh: connect to host 10.0.0.9 port 22: Operation timed out"), .unreachable)
        XCTAssertEqual(SSHError.classify(stderr: "ssh: connect to host 10.0.0.9 port 22: No route to host"), .unreachable)
        XCTAssertEqual(SSHError.classify(stderr: "kex_exchange_identification: Connection closed by remote host"), .closed)
        XCTAssertEqual(SSHError.classify(stderr: "mux_client_request_session: read from master failed: Broken pipe"), .closed)
        XCTAssertEqual(SSHError.classify(stderr: "something else"), .other)
    }

    func testHostAndUserValidation() {
        XCTAssertTrue(SSHSession.isValidHost("192.168.1.40"))
        XCTAssertTrue(SSHSession.isValidHost("mpc-live.local"))
        XCTAssertTrue(SSHSession.isValidHost("fe80::1%en0"))
        XCTAssertFalse(SSHSession.isValidHost("-oProxyCommand=evil"))
        XCTAssertFalse(SSHSession.isValidHost("host name"))
        XCTAssertFalse(SSHSession.isValidHost(""))
        XCTAssertTrue(SSHSession.isValidUser("root"))
        XCTAssertFalse(SSHSession.isValidUser("-l"))
        XCTAssertFalse(SSHSession.isValidUser("a b"))
    }

    func testArgumentsFollowTheSDKDefaults() {
        let plain = SSHSession(settings: .init(host: "192.168.1.40"))
        let args = plain.arguments(remoteCommand: "true", controlPath: "/tmp/x/cm")
        XCTAssertTrue(args.contains("BatchMode=yes"), "no password means no password prompt")
        XCTAssertTrue(args.contains("ControlPath=/tmp/x/cm"))
        XCTAssertEqual(Array(args.suffix(5)), ["-l", "root", "--", "192.168.1.40", "true"])
        XCTAssertEqual(args[args.firstIndex(of: "-p")! + 1], "22")

        let withPassword = SSHSession(settings: .init(host: "h", port: 2222, user: "me", password: "secret"))
        let passwordArgs = withPassword.arguments(remoteCommand: "true", controlPath: nil)
        XCTAssertFalse(passwordArgs.contains("BatchMode=yes"))
        XCTAssertFalse(passwordArgs.joined(separator: " ").contains("secret"), "the password must never be on the command line")
        XCTAssertFalse(passwordArgs.contains { $0.hasPrefix("ControlPath") })

        let emptyPassword = SSHSession(settings: .init(host: "h", password: ""))
        XCTAssertTrue(emptyPassword.arguments(remoteCommand: "true", controlPath: nil).contains("BatchMode=yes"))
    }
}

final class DeviceInfoTests: XCTestCase {
    func testParse() {
        let output = """
        dt.model=Akai MPC Live II,
        dt.inmusic,product-code=ACVB,
        dt.compatible=inmusic,acvb,rockchip,rk3288,
        app=3.10.1.12
        hostname=mpc-live-ii
        release.file=yes
        firmware="3.10.1.12"
        devmode.file=yes
        cap.stat=yes
        cap.findplus=yes
        mpcl.ok=yes
        """
        let info = DeviceInfo.parse(output)
        XCTAssertEqual(info.model, "Akai MPC Live II")
        XCTAssertEqual(info.productCode, "ACVB")
        XCTAssertEqual(info.firmware, "3.10.1.12")
        XCTAssertEqual(info.displayName, "Akai MPC Live II")
        XCTAssertTrue(info.looksLikeMPC)
        XCTAssertTrue(info.hasStat && info.hasFindPlus && info.complete && info.developerModeMarker)
    }

    func testOrdinaryComputerIsNotAnMPC() {
        let info = DeviceInfo.parse("dt.model=\ndt.inmusic,product-code=\ndt.compatible=\napp=\nhostname=nas\nmpcl.ok=yes\n")
        XCTAssertFalse(info.looksLikeMPC)
        XCTAssertTrue(info.complete)
        XCTAssertFalse(info.hasStat)
        XCTAssertEqual(info.displayName, "nas")
    }

    func testCutShortReplyIsIncomplete() {
        XCTAssertFalse(DeviceInfo.parse("dt.model=Akai MPC One\n").complete)
    }
}

final class NetworkProbeTests: XCTestCase {
    func testPrivateRanges() {
        func ip(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 { a << 24 | b << 16 | c << 8 | d }
        XCTAssertTrue(NetworkProbe.isPrivate(ip(192, 168, 1, 10)))
        XCTAssertTrue(NetworkProbe.isPrivate(ip(10, 0, 0, 1)))
        XCTAssertTrue(NetworkProbe.isPrivate(ip(172, 20, 0, 1)))
        XCTAssertFalse(NetworkProbe.isPrivate(ip(172, 32, 0, 1)))
        XCTAssertFalse(NetworkProbe.isPrivate(ip(8, 8, 8, 8)))
    }

    func testNeighboursOfAHomeNetwork() {
        let me: UInt32 = 192 << 24 | 168 << 16 | 1 << 8 | 20
        let list = NetworkProbe.neighbours(of: .init(name: "en0", address: me, netmask: 0xFFFF_FF00))
        XCTAssertEqual(list.count, 253)
        XCTAssertFalse(list.contains("192.168.1.20"))
        XCTAssertFalse(list.contains("192.168.1.0"))
        XCTAssertFalse(list.contains("192.168.1.255"))
        XCTAssertEqual(Set(list.prefix(2)), ["192.168.1.19", "192.168.1.21"], "nearest addresses are tried first")
    }

    func testBigNetworksAreTrimmed() {
        let me: UInt32 = 10 << 24 | 5 << 8 | 7
        let list = NetworkProbe.neighbours(of: .init(name: "en0", address: me, netmask: 0xFF00_0000))
        XCTAssertEqual(list.count, 253)
        XCTAssertTrue(list.allSatisfy { $0.hasPrefix("10.0.5.") })
    }

    func testPointToPointHasNoNeighbours() {
        XCTAssertEqual(NetworkProbe.neighbours(of: .init(name: "x", address: 1, netmask: 0xFFFF_FFFF)), [])
    }

    func testUnresolvableName() {
        XCTAssertEqual(NetworkProbe.check(host: "no-such-device.invalid", port: 22, timeout: 2), .unresolved)
    }
}

final class TransferPlanTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mpcl-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, bytes: Int) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    func testUploadPlanWalksFoldersAndSkipsJunk() throws {
        try write("Kit/kick.wav", bytes: 10)
        try write("Kit/Sub/snare.wav", bytes: 20)
        try write("Kit/.DS_Store", bytes: 5)
        try write("Kit/._kick.wav", bytes: 5)
        try write("loose.wav", bytes: 7)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Kit/loop"),
                                                   withDestinationURL: root.appendingPathComponent("Kit"))

        let plan = TransferPlan.upload(items: [root.appendingPathComponent("Kit"), root.appendingPathComponent("loose.wav")],
                                       into: "/media/USB/Samples")
        XCTAssertEqual(plan.directories, ["/media/USB/Samples/Kit", "/media/USB/Samples/Kit/Sub"])
        XCTAssertEqual(plan.files.map(\.remote), ["/media/USB/Samples/Kit/kick.wav", "/media/USB/Samples/Kit/Sub/snare.wav",
                                                  "/media/USB/Samples/loose.wav"])
        XCTAssertEqual(plan.totalBytes, 37)
        XCTAssertEqual(plan.skipped, [SkippedItem(name: "Kit/loop", reason: .link)],
                       "the link inside the folder is reported, junk is silently dropped")
        XCTAssertEqual(plan.topLevelNames, ["Kit", "loose.wav"])
    }

    private var fatDrive: Drive {
        StorageRules.parse(mounts: StorageRulesTests.mounts, df: "").drives.first { $0.mountPoint == "/media/MY USB" }!
    }

    func testOnlyFilesTheMPCCanUseAreCopied() throws {
        try write("Pack/kick.wav", bytes: 3)
        try write("Pack/Loop.AIFF", bytes: 3)
        try write("Pack/beat.xpj", bytes: 3)
        try write("Pack/readme.pdf", bytes: 9)
        try write("Pack/kick.asd", bytes: 9)
        try write("Pack/cover.jpg", bytes: 9)
        try write("Pack/noextension", bytes: 9)
        try write("Pack/Docs/licence.txt", bytes: 9)
        try write("notes.txt", bytes: 9)

        let plan = TransferPlan.upload(items: [root.appendingPathComponent("Pack"), root.appendingPathComponent("notes.txt")],
                                       into: "/media/USB")
        XCTAssertEqual(plan.files.map(\.remote), ["/media/USB/Pack/beat.xpj", "/media/USB/Pack/kick.wav", "/media/USB/Pack/Loop.AIFF"])
        XCTAssertEqual(plan.directories, ["/media/USB/Pack"], "a folder with nothing usable in it is not created")
        XCTAssertEqual(Set(plan.skipped), Set([
            SkippedItem(name: "Pack/readme.pdf", reason: .unsupportedType),
            SkippedItem(name: "Pack/kick.asd", reason: .unsupportedType),
            SkippedItem(name: "Pack/cover.jpg", reason: .unsupportedType),
            SkippedItem(name: "Pack/noextension", reason: .unsupportedType),
            SkippedItem(name: "Pack/Docs/licence.txt", reason: .unsupportedType),
            SkippedItem(name: "notes.txt", reason: .unsupportedType),
        ]))
        XCTAssertEqual(plan.topLevelNames, ["Pack"])
    }

    func testNamesTheDriveRefusesAreSkippedNotRenamed() throws {
        try write("What?/inside.wav", bytes: 3)
        try write("Kit/a:b.wav", bytes: 3)
        try write("Kit/fine.wav", bytes: 1)
        let items = [root.appendingPathComponent("What?"), root.appendingPathComponent("Kit")]

        let onFAT = TransferPlan.upload(items: items, into: "/media/MY USB", drive: fatDrive)
        XCTAssertEqual(onFAT.directories, ["/media/MY USB/Kit"])
        XCTAssertEqual(onFAT.files.map(\.remote), ["/media/MY USB/Kit/fine.wav"])
        XCTAssertEqual(Set(onFAT.skipped), Set([
            SkippedItem(name: "What?", isFolder: true, reason: .nameNotAllowed),
            SkippedItem(name: "Kit/a:b.wav", reason: .nameNotAllowed),
        ]))

        // A drive with no such rule (ext4) takes the same names as they are.
        let ext = StorageRules.parse(mounts: StorageRulesTests.mounts, df: "").drives.first { $0.mountPoint == "/media/az01-internal-sd" }!
        let onExt = TransferPlan.upload(items: items, into: "/media/az01-internal-sd", drive: ext)
        XCTAssertEqual(onExt.files.count, 3)
        XCTAssertEqual(onExt.skipped, [])
    }

    func testEmptyAndUselessFolders() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        try write("Useless/a.pdf", bytes: 1)
        try write("Useless/Deeper/b.txt", bytes: 1)
        let plan = TransferPlan.upload(items: [root.appendingPathComponent("Empty"), root.appendingPathComponent("Useless")],
                                       into: "/media/USB")
        XCTAssertEqual(plan.directories, ["/media/USB/Empty"], "an empty folder is copied, a folder of unusable files is not")
        XCTAssertEqual(plan.files, [])
        XCTAssertEqual(plan.skipped.count, 2)
    }

    func testExpansionsAndPluginsKeepTheirSupportFiles() throws {
        try write("My Expansion/Expansion.xml", bytes: 5)
        try write("My Expansion/cover.jpg", bytes: 5)
        try write("My Expansion/kick.wav", bytes: 5)
        try write("My Expansion/readme.pdf", bytes: 5)
        try write("My Expansion/Kits/art.png", bytes: 5)
        try write("Acme - VST - Synth/plugin.json", bytes: 5)
        try write("Acme - VST - Synth/arm32/Synth.so", bytes: 5)
        try write("Acme - VST - Synth/ui/knob.png", bytes: 5)

        let plan = TransferPlan.upload(items: [root.appendingPathComponent("My Expansion"),
                                               root.appendingPathComponent("Acme - VST - Synth")], into: "/media/USB")
        let copied = Set(plan.files.map(\.remote))
        XCTAssertTrue(copied.contains("/media/USB/My Expansion/Expansion.xml"))
        XCTAssertTrue(copied.contains("/media/USB/My Expansion/cover.jpg"))
        XCTAssertTrue(copied.contains("/media/USB/Acme - VST - Synth/arm32/Synth.so"))
        XCTAssertTrue(copied.contains("/media/USB/Acme - VST - Synth/ui/knob.png"))
        XCTAssertEqual(Set(plan.skipped), Set([
            SkippedItem(name: "My Expansion/readme.pdf", reason: .unsupportedType),
            SkippedItem(name: "My Expansion/Kits/art.png", reason: .unsupportedType),
        ]), "artwork only counts in the folder that holds the expansion's description")
    }

    func testFilesTooBigForFAT32AreSkipped() throws {
        let big = root.appendingPathComponent("huge.wav")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: 4_294_967_296)
        try handle.close()
        let plan = TransferPlan.upload(items: [big], into: "/media/MY USB", drive: fatDrive)
        XCTAssertEqual(plan.files, [])
        XCTAssertEqual(plan.skipped, [SkippedItem(name: "huge.wav", reason: .tooLarge)])
        XCTAssertEqual(TransferPlan.upload(items: [big], into: "/media/x").files.count, 1)
    }

    func testCompatibleTypes() {
        for name in ["a.wav", "a.WAV", "a.aif", "a.aiff", "a.mp3", "a.flac", "a.ogg", "a.xpj", "a.xpm", "a.sxq", "a.mid",
                     "a.xpn", "a.snd", "a.pgm", "a.50s", "my.kit.wav"] {
            XCTAssertTrue(MPCFileTypes.isCompatible(fileName: name), name)
        }
        for name in ["a.pdf", "a.txt", "a.asd", "a.m4a", "a.jpg", "a.zip", "a.exe", "wav", ".wav", "a.wav.bak", "a."] {
            XCTAssertFalse(MPCFileTypes.isCompatible(fileName: name), name)
        }
    }

    func testAvailableNamesNeverReplaceAnything() throws {
        try write("Kick.wav", bytes: 1)
        try write("Kick 2.wav", bytes: 1)
        var taken = Set<String>()
        XCTAssertEqual(TransferPlan.availableURL(for: "Kick.wav", in: root, taken: &taken).lastPathComponent, "Kick 3.wav")
        XCTAssertEqual(TransferPlan.availableURL(for: "Kick.wav", in: root, taken: &taken).lastPathComponent, "Kick 4.wav")
        XCTAssertEqual(TransferPlan.availableURL(for: "New.wav", in: root, taken: &taken).lastPathComponent, "New.wav")
        XCTAssertEqual(TransferPlan.availableURL(for: "new.wav", in: root, taken: &taken).lastPathComponent, "new 2.wav")
        XCTAssertEqual(TransferPlan.availableURL(for: "Folder", in: root, taken: &taken).lastPathComponent, "Folder")
    }

    func testJunk() {
        XCTAssertTrue(TransferPlan.isJunk(".DS_Store"))
        XCTAssertTrue(TransferPlan.isJunk("._anything"))
        XCTAssertFalse(TransferPlan.isJunk("kick.wav"))
        XCTAssertFalse(TransferPlan.isJunk(".hidden-but-real"))
    }
}
