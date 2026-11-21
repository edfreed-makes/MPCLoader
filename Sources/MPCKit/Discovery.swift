import Foundation

/// A device on the local network that answers on the SSH port.
public struct DiscoveredDevice: Identifiable, Equatable, Sendable {
    public let address: String
    /// The device identified itself as Akai / inMusic hardware.
    public let isMPC: Bool
    /// The model name, when the device gave one.
    public let model: String

    public var id: String { address }

    public init(address: String, isMPC: Bool, model: String) {
        self.address = address
        self.isMPC = isMPC
        self.model = model
    }

    public var label: String {
        if isMPC { return model.isEmpty ? "MPC at \(address)" : "\(model) at \(address)" }
        return "Unknown device at \(address)"
    }
}

/// Finds MPCs on the local network.
///
/// An MPC in developer mode listens on the SSH port and lets `root` in without a password.
/// So the search checks which nearby addresses have that port open, then asks each one what
/// it is, using a login with no password. No password you have typed is ever sent to a
/// device the app has not already been told is your MPC.
public enum Discovery {
    /// The most devices the search will try to log in to.
    static let maximumProbes = 12

    public static func candidateAddresses() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for interface in NetworkProbe.localInterfaces() {
            for address in NetworkProbe.neighbours(of: interface) where !seen.contains(address) {
                seen.insert(address)
                result.append(address)
            }
        }
        return result
    }

    /// Asks one device what it is. Returns nil when it will not let `user` in without a password.
    public static func identify(address: String, port: Int, user: String, sshPath: String = SSHSession.defaultSSHPath)
        -> DeviceInfo? {
        let session = SSHSession(settings: .init(host: address, port: port, user: user, password: nil),
                                 sshPath: sshPath, multiplex: false, connectTimeout: 4)
        defer { session.close() }
        guard let result = try? session.run(DeviceInfo.script, timeout: 10) else { return nil }
        let info = DeviceInfo.parse(result.text)
        return info.complete ? info : nil
    }

    /// Searches the local network. MPCs come first in the result.
    public static func search(port: Int = SSHSession.Settings.defaultPort, user: String = SSHSession.Settings.defaultUser,
                              sshPath: String = SSHSession.defaultSSHPath,
                              isCancelled: @escaping @Sendable () -> Bool = { false }) -> [DiscoveredDevice] {
        let open = NetworkProbe.scan(addresses: candidateAddresses(), port: port, isCancelled: isCancelled)
        if open.isEmpty || isCancelled() { return [] }

        let targets = Array(open.prefix(maximumProbes))
        let results = ResultBox(count: targets.count)
        DispatchQueue.concurrentPerform(iterations: targets.count) { index in
            if isCancelled() { return }
            let info = identify(address: targets[index], port: port, user: user, sshPath: sshPath)
            results.set(index, info)
        }
        var devices: [DiscoveredDevice] = []
        for (index, address) in targets.enumerated() {
            let info = results.get(index)
            devices.append(DiscoveredDevice(address: address, isMPC: info?.looksLikeMPC ?? false,
                                            model: info?.model ?? ""))
        }
        for address in open.dropFirst(maximumProbes) {
            devices.append(DiscoveredDevice(address: address, isMPC: false, model: ""))
        }
        return devices.sorted { lhs, rhs in
            if lhs.isMPC != rhs.isMPC { return lhs.isMPC }
            return lhs.address.compare(rhs.address, options: .numeric) == .orderedAscending
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DeviceInfo?]

    init(count: Int) { values = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ value: DeviceInfo?) {
        lock.lock(); values[index] = value; lock.unlock()
    }

    func get(_ index: Int) -> DeviceInfo? {
        lock.lock(); defer { lock.unlock() }
        return values[index]
    }
}
