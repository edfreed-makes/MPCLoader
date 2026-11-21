// Temporary experiment: how does macOS name a file dragged out of an app as an NSItemProvider?
import AppKit
import UniformTypeIdentifiers

setbuf(stdout, nil)
let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
try! fm.createDirectory(at: work, withIntermediateDirectories: true)

func source(_ name: String, folder: Bool = false) -> URL {
    let dir = work.appendingPathComponent(UUID().uuidString)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    if folder {
        try! fm.createDirectory(at: url.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try! Data("a".utf8).write(to: url.appendingPathComponent("kick.wav"))
        try! Data("b".utf8).write(to: url.appendingPathComponent("Sub/snare.wav"))
    } else {
        try! Data("hello".utf8).write(to: url)
    }
    return url
}

func provider(suggested: String?, type: UTType, source: URL) -> NSItemProvider {
    let p = NSItemProvider()
    if let suggested { p.suggestedName = suggested }
    p.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
        completion(source, false, nil)
        return nil
    }
    return p
}

struct Case { let label: String; let suggested: String?; let type: UTType; let file: String; let folder: Bool }
func ext(_ e: String) -> UTType { UTType(filenameExtension: e) ?? .data }
let cases: [Case] = [
    Case(label: "wav, suggested with ext", suggested: "Kick Deep 01.wav", type: ext("wav"), file: "Kick Deep 01.wav", folder: false),
    Case(label: "wav, suggested without ext", suggested: "Kick Deep 01", type: ext("wav"), file: "Kick Deep 01.wav", folder: false),
    Case(label: "wav, no suggestion", suggested: nil, type: ext("wav"), file: "Kick Deep 01.wav", folder: false),
    Case(label: "aif, suggested with ext", suggested: "Hat.aif", type: ext("aif"), file: "Hat.aif", folder: false),
    Case(label: "aif, suggested without ext", suggested: "Hat", type: ext("aif"), file: "Hat.aif", folder: false),
    Case(label: "xpm, suggested with ext", suggested: "Kit.xpm", type: ext("xpm"), file: "Kit.xpm", folder: false),
    Case(label: "xpj, suggested with ext", suggested: "Beat.xpj", type: ext("xpj"), file: "Beat.xpj", folder: false),
    Case(label: "xpj as public.data, suggested with ext", suggested: "Beat.xpj", type: .data, file: "Beat.xpj", folder: false),
    Case(label: "mid, suggested with ext", suggested: "Fill.mid", type: ext("mid"), file: "Fill.mid", folder: false),
    Case(label: "no extension, public.data", suggested: "README", type: .data, file: "README", folder: false),
    Case(label: "folder, public.folder", suggested: "My Kit", type: .folder, file: "My Kit", folder: true),
    Case(label: "folder, public.directory", suggested: "My Kit", type: .directory, file: "My Kit", folder: true),
]

print("NSItemProvider is NSPasteboardWriting:", (NSItemProvider() as AnyObject) is NSPasteboardWriting)

for c in cases {
    print("\n== \(c.label) | type=\(c.type.identifier) preferredExt=\(c.type.preferredFilenameExtension ?? "nil")")
    let src = source(c.file, folder: c.folder)

    // 1. What a receiver gets from the item provider directly.
    let p1 = provider(suggested: c.suggested, type: c.type, source: src)
    let done = DispatchSemaphore(value: 0)
    _ = p1.loadFileRepresentation(forTypeIdentifier: c.type.identifier) { url, error in
        if let url {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            print("  loadFileRepresentation ->", url.lastPathComponent, "| dir:", isDir.boolValue,
                  "| contents:", (try? fm.subpathsOfDirectory(atPath: url.path)) ?? [])
        } else {
            print("  loadFileRepresentation error:", error?.localizedDescription ?? "nil")
        }
        done.signal()
    }
    _ = done.wait(timeout: .now() + 10)

    // 2. What a drop target such as Finder sees, if the provider can go on a pasteboard.
    let p2 = provider(suggested: c.suggested, type: c.type, source: src)
    guard let writer = (p2 as AnyObject) as? NSPasteboardWriting else {
        print("  (not a pasteboard writer)")
        continue
    }
    let pb = NSPasteboard(name: NSPasteboard.Name("probe-\(UUID().uuidString)"))
    pb.clearContents()
    print("  wrote to pasteboard:", pb.writeObjects([writer]))
    print("  pasteboard types:", pb.types?.map(\.rawValue) ?? [])
    for item in pb.pasteboardItems ?? [] {
        for type in item.types where type.rawValue.lowercased().contains("promise") || type.rawValue.lowercased().contains("name") {
            print("   ", type.rawValue, "=", item.string(forType: type) ?? "(binary)")
        }
    }
    let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
    print("  promise receivers:", receivers.count)
    for receiver in receivers {
        print("    fileTypes:", receiver.fileTypes, "fileNames:", receiver.fileNames)
        let destination = work.appendingPathComponent("dest-\(UUID().uuidString)")
        try! fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let got = DispatchSemaphore(value: 0)
        let queue = OperationQueue()
        receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue) { url, error in
            print("    received:", url.lastPathComponent, "error:", error?.localizedDescription ?? "none",
                  "| contents:", (try? fm.subpathsOfDirectory(atPath: url.path)) ?? [])
            got.signal()
        }
        if got.wait(timeout: .now() + 10) == .timedOut { print("    (timed out waiting for the promised file)") }
        print("    destination now holds:", (try? fm.subpathsOfDirectory(atPath: destination.path)) ?? [])
    }
    pb.releaseGlobally()
}
try? fm.removeItem(at: work)
print("\nprobe done")
