import Foundation
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import MPCKit

/// The working folder on this Mac for previews and for items dragged out of the window.
///
/// Everything temporary lives here, in the Mac's own temporary area. Nothing temporary is ever
/// written to the MPC for a preview or a drag. The folder is removed when the app quits, and
/// anything a crashed session left behind is cleared the next time the app starts.
enum Scratch {
    private static let base = FileManager.default.temporaryDirectory.appendingPathComponent("MPCLoader", isDirectory: true)
    static let session = base.appendingPathComponent(UUID().uuidString, isDirectory: true)

    static func newFolder(_ purpose: String) throws -> URL {
        let folder = session.appendingPathComponent(purpose, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func remove(_ purpose: String) {
        try? FileManager.default.removeItem(at: session.appendingPathComponent(purpose, isDirectory: true))
    }

    static func removeSession() {
        try? FileManager.default.removeItem(at: session)
    }

    /// Clears working folders left by earlier runs that did not quit cleanly.
    static func removeStale() {
        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(-86_400)
        let folders = (try? fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders where folder != session {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (modified ?? .distantPast) < cutoff { try? fileManager.removeItem(at: folder) }
        }
    }
}

/// Somewhere files can be fetched from: the connected MPC, or made-up content in a demo.
protocol FileSource: AnyObject {
    /// Copies a file, or a folder and its contents, into a folder on this Mac and returns where it landed.
    func fetch(_ entry: RemoteEntry, into directory: URL, control: CommandControl?,
               progress: ((_ done: Int64, _ total: Int64) -> Void)?) throws -> URL
}

extension RemoteFileSystem: FileSource {
    func fetch(_ entry: RemoteEntry, into directory: URL, control: CommandControl?,
               progress: ((Int64, Int64) -> Void)?) throws -> URL {
        try export(entry, into: directory, control: control, progress: progress).url
    }
}

/// Stands in for an MPC in the demo scenes: every "file" is a short generated tone.
final class DemoSource: FileSource {
    func fetch(_ entry: RemoteEntry, into directory: URL, control: CommandControl?,
               progress: ((Int64, Int64) -> Void)?) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(entry.name)
        if entry.isDirectory {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            try DemoSource.tone(seconds: 1, frequency: 220).write(to: target.appendingPathComponent("Kick.wav"))
            try DemoSource.tone(seconds: 1, frequency: 330).write(to: target.appendingPathComponent("Snare.wav"))
        } else {
            let data = DemoSource.tone(seconds: 12, frequency: 262)
            progress?(Int64(data.count), Int64(data.count))
            try data.write(to: target)
        }
        return target
    }

    /// A plain 16-bit mono WAV file holding a fading sine tone.
    static func tone(seconds: Double, frequency: Double) -> Data {
        let rate = 22_050
        let count = Int(seconds * Double(rate))
        var samples = Data(capacity: count * 2)
        for index in 0..<count {
            let time = Double(index) / Double(rate)
            let fade = max(0, 1 - time / seconds)
            let value = Int16(sin(2 * .pi * frequency * time) * 12_000 * fade)
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }
        func le32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
        func le16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
        var file = Data()
        file.append(Data("RIFF".utf8)); file.append(le32(36 + samples.count)); file.append(Data("WAVE".utf8))
        file.append(Data("fmt ".utf8)); file.append(le32(16)); file.append(le16(1)); file.append(le16(1))
        file.append(le32(rate)); file.append(le32(rate * 2)); file.append(le16(2)); file.append(le16(16))
        file.append(Data("data".utf8)); file.append(le32(samples.count)); file.append(samples)
        return file
    }
}

/// Plays an audio file from the MPC through this Mac's speakers.
///
/// The file is copied to the Mac's temporary area first and played from there. Recently played
/// files are kept for the session so replaying one is instant.
@MainActor
final class PreviewPlayer: ObservableObject {
    enum Phase: Equatable {
        case closed
        case loading(Double)
        case playing
        case stopped
        case failed(String)
    }

    @Published private(set) var phase: Phase = .closed {
        didSet {
            // Demo scenes say what the player is doing, so an automated check can follow along.
            if AppModel.demoScene != nil, PreviewPlayer.label(phase) != PreviewPlayer.label(oldValue) {
                print("preview: \(PreviewPlayer.label(phase)) \(name)")
                fflush(stdout)
            }
        }
    }
    @Published private(set) var name = ""
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    private(set) var currentPath: String?

    private var player: AVAudioPlayer?
    private var currentURL: URL?
    private var timer: Timer?
    private var control: CommandControl?
    private var token = 0
    private var cache: [(key: String, url: URL)] = []
    private let worker = Worker("mpcloader.preview")
    private static let cacheLimit = 24

    /// Kinds of audio worth trying. macOS decides whether it can actually play each one.
    private static let extraExtensions: Set<String> = ["wave", "aifc", "m4a", "aac", "caf", "snd"]

    static func canTry(_ entry: RemoteEntry) -> Bool {
        guard entry.kind == .file else { return false }
        let ext = entry.fileExtension
        return MPCFileTypes.audio[ext] != nil || extraExtensions.contains(ext)
    }

    private static func label(_ phase: Phase) -> String {
        switch phase {
        case .closed: return "closed"
        case .loading: return "loading"
        case .playing: return "playing"
        case .stopped: return "stopped"
        case .failed(let message): return "failed (\(message))"
        }
    }

    var isOpen: Bool { phase != .closed }
    var isPlaying: Bool { phase == .playing }
    var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    /// Starts playing `entry`, fetching it first if it has not been played this session.
    func play(_ entry: RemoteEntry, from source: FileSource) {
        haltAudio()
        control?.cancel()
        control = nil
        token += 1
        let current = token
        name = entry.name
        currentPath = entry.path
        position = 0
        duration = 0

        let key = "\(entry.path)|\(entry.size)|\(entry.modified?.timeIntervalSince1970 ?? 0)"
        if let cached = cache.first(where: { $0.key == key }), FileManager.default.fileExists(atPath: cached.url.path) {
            start(cached.url)
            return
        }

        phase = .loading(0)
        let stopper = CommandControl()
        control = stopper
        Task {
            do {
                let url = try await worker.run { () -> URL in
                    let folder = try Scratch.newFolder("Previews")
                    return try source.fetch(entry, into: folder, control: stopper) { done, total in
                        let fraction = total > 0 ? min(1, Double(done) / Double(total)) : 0
                        Task { @MainActor in
                            if self.token == current, self.isLoading { self.phase = .loading(fraction) }
                        }
                    }
                }
                guard token == current else { return }
                remember(key: key, url: url)
                start(url)
            } catch {
                guard token == current else { return }
                if (error as? SSHError)?.kind == .cancelled {
                    phase = .closed
                } else {
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func remember(key: String, url: URL) {
        cache.append((key, url))
        while cache.count > PreviewPlayer.cacheLimit {
            let oldest = cache.removeFirst()
            try? FileManager.default.removeItem(at: oldest.url.deletingLastPathComponent())
        }
    }

    private func start(_ url: URL) {
        currentURL = url
        do {
            let fresh = try AVAudioPlayer(contentsOf: url)
            fresh.prepareToPlay()
            duration = fresh.duration
            guard fresh.play() else {
                phase = .failed("This Mac couldn't start playing the file. Check its sound output.")
                return
            }
            player = fresh
            phase = .playing
            let ticker = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(ticker, forMode: .common)
            timer = ticker
        } catch {
            let ext = MPCFileTypes.fileExtension(of: url.lastPathComponent)
            phase = .failed(ext == "ogg"
                ? "macOS has no built-in support for Ogg audio, so this file can't be previewed."
                : "macOS can't play this file, so it can't be previewed.")
        }
    }

    private func tick() {
        guard let player, phase == .playing else { return }
        if player.isPlaying {
            position = player.currentTime
        } else {
            position = duration
            haltAudio()
            phase = .stopped
        }
    }

    private func haltAudio() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
    }

    /// The play / stop button in the preview strip.
    func togglePlayback() {
        switch phase {
        case .playing:
            haltAudio()
            position = 0
            phase = .stopped
        case .stopped:
            if let currentURL, FileManager.default.fileExists(atPath: currentURL.path) {
                position = 0
                start(currentURL)
            }
        case .loading, .failed:
            close()
        case .closed:
            break
        }
    }

    func close() {
        token += 1
        control?.cancel()
        control = nil
        haltAudio()
        phase = .closed
        currentPath = nil
        currentURL = nil
        name = ""
    }

    /// Stops and forgets everything fetched so far. Called on disconnecting.
    func reset() {
        close()
        cache = []
        Scratch.remove("Previews")
    }

    var timeText: String {
        func clock(_ seconds: TimeInterval) -> String {
            let whole = Int(seconds.rounded(.down))
            return String(format: "%d:%02d", whole / 60, whole % 60)
        }
        return "\(clock(position)) / \(clock(duration))"
    }
}

/// Hands items dragged out of the window to Finder, or to any app that accepts files.
///
/// macOS asks for each item only when it is dropped. The item is then copied from the MPC into
/// the Mac's temporary area and macOS moves it to where it was dropped.
final class DragExporter: @unchecked Sendable {
    /// One at a time, so a large drag does not open dozens of connections to the MPC at once.
    private let queue = DispatchQueue(label: "mpcloader.drag-out", qos: .userInitiated)

    func provider(for entry: RemoteEntry, source: FileSource, started: @escaping @Sendable () -> Void,
                  finished: @escaping @Sendable (Error?) -> Void) -> NSItemProvider {
        let provider = NSItemProvider()
        // The full name, extension included: macOS keeps it as it is. Without the extension it
        // would add its own preferred one, turning "Hat.aif" into "Hat.aiff".
        provider.suggestedName = entry.name
        let ext = MPCFileTypes.fileExtension(of: entry.name)
        let type: UTType = entry.isDirectory ? .folder : (ext.isEmpty ? .data : (UTType(filenameExtension: ext) ?? .data))

        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { [queue] completion in
            let progress = Progress(totalUnitCount: 1000)
            let control = CommandControl()
            progress.cancellationHandler = { control.cancel() }
            started()
            queue.async {
                do {
                    let folder = try Scratch.newFolder("Dragged")
                    let url = try source.fetch(entry, into: folder, control: control) { done, total in
                        progress.completedUnitCount = total > 0 ? Int64(Double(done) / Double(total) * 1000) : 0
                    }
                    progress.completedUnitCount = 1000
                    completion(url, false, nil)
                    finished(nil)
                    // macOS has taken its own copy by the time the hand-over returns. Clear ours a little later.
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 600) {
                        try? FileManager.default.removeItem(at: folder)
                    }
                } catch {
                    completion(nil, false, error)
                    finished(error)
                }
            }
            return progress
        }
        return provider
    }
}
