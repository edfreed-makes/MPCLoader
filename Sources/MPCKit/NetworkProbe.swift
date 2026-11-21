import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Low-level network checks: "is something listening on this port?" and "which addresses are on my network?".
public enum NetworkProbe {
    public enum PortState: String, Sendable {
        /// Something accepted the connection.
        case open
        /// A device is there but nothing is listening on that port.
        case refused
        /// Nothing answered in time.
        case unreachable
        /// The name does not resolve.
        case unresolved
    }

    #if canImport(Glibc)
    private static let streamType = Int32(SOCK_STREAM.rawValue)
    #else
    private static let streamType = SOCK_STREAM
    #endif

    private struct Pending {
        let fd: Int32
        let index: Int
    }

    private static func startConnect(family: Int32, address: UnsafePointer<sockaddr>, length: socklen_t)
        -> (fd: Int32, state: PortState?) {
        let fd = socket(family, streamType, 0)
        if fd < 0 { return (-1, .unreachable) }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        #if canImport(Darwin)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        #endif
        let result = connect(fd, address, length)
        if result == 0 { close(fd); return (-1, .open) }
        if errno == EINPROGRESS { return (fd, nil) }
        let state: PortState = errno == ECONNREFUSED ? .refused : .unreachable
        close(fd)
        return (-1, state)
    }

    private static func finish(_ fd: Int32) -> PortState {
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        if getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) != 0 { return .unreachable }
        if error == 0 { return .open }
        return error == ECONNREFUSED ? .refused : .unreachable
    }

    /// Waits for a batch of non-blocking connects and records how each one ended.
    private static func wait(_ pending: [Pending], timeout: TimeInterval, into states: inout [PortState]) {
        var remaining = pending
        let deadline = Date().addingTimeInterval(timeout)
        while !remaining.isEmpty {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            var fds = remaining.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
            let ready = poll(&fds, nfds_t(fds.count), Int32(max(1, left * 1000)))
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { break }
            var still: [Pending] = []
            for (offset, item) in remaining.enumerated() {
                if fds[offset].revents != 0 {
                    states[item.index] = finish(item.fd)
                    close(item.fd)
                } else {
                    still.append(item)
                }
            }
            remaining = still
        }
        for item in remaining {
            states[item.index] = .unreachable
            close(item.fd)
        }
    }

    /// Checks one host and port. `host` may be an IP address or a name.
    public static func check(host: String, port: Int, timeout: TimeInterval = 5) -> PortState {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = streamType
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else { return .unresolved }
        defer { freeaddrinfo(list) }

        var sawRefused = false
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            defer { cursor = info.pointee.ai_next }
            guard let address = info.pointee.ai_addr else { continue }
            let started = startConnect(family: info.pointee.ai_family, address: address, length: info.pointee.ai_addrlen)
            var state: PortState
            if let immediate = started.state {
                state = immediate
            } else {
                var states: [PortState] = [.unreachable]
                wait([Pending(fd: started.fd, index: 0)], timeout: timeout, into: &states)
                state = states[0]
            }
            if state == .open { return .open }
            if state == .refused { sawRefused = true }
        }
        return sawRefused ? .refused : .unreachable
    }

    /// Checks many IPv4 addresses for an open port, a batch at a time.
    /// Returns the addresses that accepted the connection.
    public static func scan(addresses: [String], port: Int, timeout: TimeInterval = 0.7, batchSize: Int = 48,
                            isCancelled: () -> Bool = { false }) -> [String] {
        var open: [String] = []
        var start = 0
        while start < addresses.count, !isCancelled() {
            let batch = Array(addresses[start..<min(start + batchSize, addresses.count)])
            start += batch.count
            var states = [PortState](repeating: .unreachable, count: batch.count)
            var pending: [Pending] = []
            for (index, text) in batch.enumerated() {
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = UInt16(port).bigEndian
                guard inet_pton(AF_INET, text, &address.sin_addr) == 1 else { continue }
                #if canImport(Darwin)
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                #endif
                let started = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        startConnect(family: AF_INET, address: $0, length: socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if let immediate = started.state {
                    states[index] = immediate
                } else {
                    pending.append(Pending(fd: started.fd, index: index))
                }
            }
            wait(pending, timeout: timeout, into: &states)
            for (index, state) in states.enumerated() where state == .open {
                open.append(batch[index])
            }
        }
        return open
    }

    // MARK: Local network

    public struct Interface: Equatable, Sendable {
        public let name: String
        public let address: UInt32
        public let netmask: UInt32

        public init(name: String, address: UInt32, netmask: UInt32) {
            self.name = name
            self.address = address
            self.netmask = netmask
        }
    }

    public static func dotted(_ value: UInt32) -> String {
        "\(value >> 24 & 0xFF).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }

    /// Home and office networks only: 10.x, 172.16-31.x, 192.168.x and link-local 169.254.x.
    public static func isPrivate(_ address: UInt32) -> Bool {
        let a = address >> 24 & 0xFF
        let b = address >> 16 & 0xFF
        return a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254)
    }

    /// This computer's IPv4 addresses on private networks, wired and wireless.
    public static func localInterfaces() -> [Interface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        var found: [Interface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int(entry.pointee.ifa_flags)
            guard flags & Int(IFF_UP) != 0, flags & Int(IFF_LOOPBACK) == 0,
                  let address = entry.pointee.ifa_addr, Int32(address.pointee.sa_family) == AF_INET,
                  let mask = entry.pointee.ifa_netmask else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            guard isPrivate(ip) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            // Skip virtual machine and VPN style interfaces: an MPC will not be behind them.
            if name.hasPrefix("utun") || name.hasPrefix("bridge") || name.hasPrefix("docker")
                || name.hasPrefix("veth") || name.hasPrefix("vmnet") || name.hasPrefix("awdl") || name.hasPrefix("llw") {
                continue
            }
            found.append(Interface(name: name, address: ip, netmask: netmask))
        }
        return found
    }

    /// The other addresses on an interface's network, nearest first.
    /// Large networks are trimmed to the 254 addresses around this computer so a scan stays quick.
    public static func neighbours(of interface: Interface) -> [String] {
        var mask = interface.netmask
        if mask == 0 || mask < 0xFFFF_FF00 { mask = 0xFFFF_FF00 }
        if mask == 0xFFFF_FFFF { return [] }
        let network = interface.address & mask
        let broadcast = network | ~mask
        guard broadcast > network + 1 else { return [] }
        var hosts: [UInt32] = []
        var host = network + 1
        while host < broadcast {
            if host != interface.address { hosts.append(host) }
            host += 1
        }
        hosts.sort { lhs, rhs in
            let l = lhs > interface.address ? lhs - interface.address : interface.address - lhs
            let r = rhs > interface.address ? rhs - interface.address : interface.address - rhs
            return l < r
        }
        return hosts.map(dotted)
    }
}
