import Foundation

/// How far a copy of many files has got.
public struct BatchProgress: Equatable, Sendable {
    public var finishedFiles = 0
    public var totalFiles = 0
    public var copiedBytes: Int64 = 0
    public var totalBytes: Int64 = 0
    /// The file most recently started.
    public var currentName = ""
}

public struct BatchFailure: Equatable, Sendable {
    public let name: String
    public let message: String
}

/// How a copy of many files ended.
public struct BatchOutcome: Sendable {
    public var copied = 0
    public var failures: [BatchFailure] = []
    public var cancelled = false
    /// Set when the copy gave up early: the drive went away or filled up, or the connection dropped.
    public var stoppedBecause: String?
    /// The connection error that ended the copy, if that is what happened.
    public var connectionError: SSHError?
}

/// Copies many files, several at a time.
///
/// A folder of samples is mostly small files, and for those the fixed cost of starting each
/// copy outweighs the time spent sending data. Running a few side by side over the one
/// connection removes most of that wait. Large files gain nothing from company, and writing
/// them one at a time keeps each in one piece on the drive, so they go singly.
enum BatchRunner {
    struct Job {
        let name: String
        let size: Int64
        /// Copies the file, reporting bytes copied so far as it goes.
        let perform: (@escaping (Int64) -> Void) throws -> Void
    }

    /// Files this size and over are copied one at a time.
    static let largeFileSize: Int64 = 8 * 1024 * 1024

    static func run(_ jobs: [Job], parallel: Int, largeFileSize: Int64 = BatchRunner.largeFileSize,
                    control: CommandControl?, progress: ((BatchProgress) -> Void)?,
                    stopsEverything: @escaping (RemoteFileError) -> Bool = { _ in false }) -> BatchOutcome {
        let state = State(totalFiles: jobs.count, totalBytes: jobs.reduce(0) { $0 + $1.size }, progress: progress)
        let small = jobs.filter { $0.size < largeFileSize }
        let large = jobs.filter { $0.size >= largeFileSize }
        pass(small, workers: max(1, parallel), state: state, control: control, stopsEverything: stopsEverything)
        pass(large, workers: 1, state: state, control: control, stopsEverything: stopsEverything)
        return state.outcome
    }

    private static func pass(_ jobs: [Job], workers: Int, state: State, control: CommandControl?,
                             stopsEverything: @escaping (RemoteFileError) -> Bool) {
        guard !jobs.isEmpty else { return }
        let queue = JobQueue(jobs)
        let group = DispatchGroup()
        for _ in 0..<min(workers, jobs.count) {
            group.enter()
            let thread = Thread {
                defer { group.leave() }
                while !state.shouldStop, control?.isCancelled != true, let job = queue.next() {
                    let slot = state.begin(job)
                    do {
                        try job.perform { bytes in state.advance(slot, to: bytes) }
                        state.finish(slot, job: job, copied: true)
                    } catch let error as SSHError {
                        state.finish(slot, job: job, copied: false)
                        if error.kind == .cancelled {
                            state.markCancelled()
                        } else {
                            state.connectionLost(error)
                        }
                    } catch let error as RemoteFileError {
                        state.finish(slot, job: job, copied: false)
                        state.fail(job, message: error.localizedDescription, stopBecause: stopsEverything(error) ? error.localizedDescription : nil)
                    } catch {
                        state.finish(slot, job: job, copied: false)
                        state.fail(job, message: error.localizedDescription, stopBecause: nil)
                    }
                }
                if control?.isCancelled == true { state.markCancelled() }
            }
            thread.stackSize = 1 << 20
            thread.start()
        }
        group.wait()
    }

    private final class JobQueue: @unchecked Sendable {
        private let lock = NSLock()
        private let jobs: [Job]
        private var index = 0

        init(_ jobs: [Job]) { self.jobs = jobs }

        func next() -> Job? {
            lock.lock(); defer { lock.unlock() }
            guard index < jobs.count else { return nil }
            index += 1
            return jobs[index - 1]
        }
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private let progress: ((BatchProgress) -> Void)?
        private var snapshot = BatchProgress()
        private var settledBytes: Int64 = 0
        private var underway: [Int: Int64] = [:]
        private var nextSlot = 0
        private var stop = false
        private var result = BatchOutcome()

        init(totalFiles: Int, totalBytes: Int64, progress: ((BatchProgress) -> Void)?) {
            self.progress = progress
            snapshot.totalFiles = totalFiles
            snapshot.totalBytes = totalBytes
        }

        var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return stop }
        var outcome: BatchOutcome { lock.lock(); defer { lock.unlock() }; return result }

        private func publish() {
            // Called with the lock held. The callback runs outside it.
            snapshot.copiedBytes = settledBytes + underway.values.reduce(0, +)
            let copy = snapshot
            lock.unlock()
            progress?(copy)
            lock.lock()
        }

        func begin(_ job: Job) -> Int {
            lock.lock(); defer { lock.unlock() }
            let slot = nextSlot
            nextSlot += 1
            underway[slot] = 0
            snapshot.currentName = job.name
            publish()
            return slot
        }

        func advance(_ slot: Int, to bytes: Int64) {
            lock.lock(); defer { lock.unlock() }
            guard underway[slot] != nil else { return }
            underway[slot] = bytes
            publish()
        }

        func finish(_ slot: Int, job: Job, copied: Bool) {
            lock.lock(); defer { lock.unlock() }
            underway[slot] = nil
            settledBytes += job.size
            snapshot.finishedFiles += 1
            if copied { result.copied += 1 }
            publish()
        }

        func fail(_ job: Job, message: String, stopBecause: String?) {
            lock.lock(); defer { lock.unlock() }
            result.failures.append(BatchFailure(name: job.name, message: message))
            if let stopBecause {
                stop = true
                if result.stoppedBecause == nil { result.stoppedBecause = stopBecause }
            }
        }

        func markCancelled() {
            lock.lock(); defer { lock.unlock() }
            result.cancelled = true
            stop = true
        }

        func connectionLost(_ error: SSHError) {
            lock.lock(); defer { lock.unlock() }
            stop = true
            if result.connectionError == nil {
                result.connectionError = error
                result.stoppedBecause = "The connection to the MPC was lost. " + (error.errorDescription ?? "")
            }
        }
    }
}

public extension RemoteFileSystem {
    /// Copies everything in an upload plan to the MPC: folders first, then the files, several at a time.
    func uploadBatch(_ plan: TransferPlan.Upload, replaceExisting: Bool, control: CommandControl? = nil,
                     progress: ((BatchProgress) -> Void)? = nil) -> BatchOutcome {
        var early = BatchOutcome()
        var failedFolders: [String] = []
        for folder in plan.directories {
            if control?.isCancelled == true { early.cancelled = true; return early }
            do {
                try makeDirectory(folder, existingIsFine: true)
            } catch let error as SSHError {
                if error.kind == .cancelled { early.cancelled = true; return early }
                early.connectionError = error
                early.stoppedBecause = "The connection to the MPC was lost. " + (error.errorDescription ?? "")
                return early
            } catch {
                failedFolders.append(folder)
                early.failures.append(BatchFailure(name: RemotePath.lastComponent(of: folder), message: error.localizedDescription))
            }
        }
        // Files inside a folder that could not be made have nowhere to go. The folder is already reported.
        let files = plan.files.filter { file in !failedFolders.contains { RemotePath.isInside(file.remote, root: $0) } }
        let jobs = files.map { file in
            BatchRunner.Job(name: RemotePath.lastComponent(of: file.remote), size: file.size) { report in
                try self.upload(localFile: file.local, to: file.remote, replaceExisting: replaceExisting,
                                control: control, progress: report)
            }
        }
        var outcome = BatchRunner.run(jobs, parallel: parallelCopies, control: control, progress: progress) { error in
            error.kind == .driveGone || error.kind == .noSpace
        }
        outcome.failures = early.failures + outcome.failures
        flush()
        return outcome
    }

    /// Copies everything in a download plan to this Mac: folders first, then the files, several at a time.
    func downloadBatch(_ plan: TransferPlan.Download, control: CommandControl? = nil,
                       progress: ((BatchProgress) -> Void)? = nil) -> BatchOutcome {
        var early = BatchOutcome()
        for folder in plan.directories {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                early.stoppedBecause = "The folder “\(folder.lastPathComponent)” couldn't be created on this Mac. \(error.localizedDescription)"
                return early
            }
        }
        let jobs = plan.files.map { file in
            BatchRunner.Job(name: file.local.lastPathComponent, size: file.size) { report in
                try self.download(remoteFile: file.remote, to: file.local, control: control, progress: report)
            }
        }
        return BatchRunner.run(jobs, parallel: parallelCopies, control: control, progress: progress) { error in
            error.kind == .driveGone
        }
    }
}
