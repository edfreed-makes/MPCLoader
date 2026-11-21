import Foundation

/// Why the SSH connection itself failed (as opposed to a command on the MPC failing).
public struct SSHError: Error, Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// No `ssh` program on this Mac.
        case noClient
        /// Wrong user name or password.
        case auth
        /// Something answered at that address but turned the connection down.
        /// On an MPC this almost always means developer mode is off.
        case refused
        /// The name does not resolve to an address.
        case dns
        /// Nothing answered at that address.
        case unreachable
        /// The connection dropped.
        case closed
        case timeout
        case cancelled
        case other
    }

    public let kind: Kind
    public let detail: String

    public init(_ kind: Kind, _ detail: String = "") {
        self.kind = kind
        self.detail = detail
    }

    /// Sorts ssh's own error text into a kind. Mirrors `classify_ssh_error` in Akai's SDK tool.
    public static func classify(stderr: String) -> Kind {
        let text = stderr.lowercased()
        if text.contains("permission denied") || text.contains("authentication failed")
            || text.contains("too many authentication") {
            return .auth
        }
        if text.contains("refused") { return .refused }
        if text.contains("could not resolve") || text.contains("name or service not known")
            || text.contains("nodename nor servname") {
            return .dns
        }
        if text.contains("timed out") || text.contains("no route") || text.contains("unreachable")
            || text.contains("host is down") {
            return .unreachable
        }
        if text.contains("closed by remote") || text.contains("connection reset") || text.contains("kex_exchange")
            || text.contains("banner") || text.contains("broken pipe") || text.contains("mux_client")
            || text.contains("connection closed") {
            return .closed
        }
        return .other
    }
}

extension SSHError: LocalizedError {
    public var errorDescription: String? {
        switch kind {
        case .noClient: return "This Mac has no ssh command."
        case .auth: return "The MPC refused the user name or password."
        case .refused: return "The MPC's SSH server is off. Developer mode is probably not switched on."
        case .dns: return "That name does not lead to a device. Use the MPC's IP address instead."
        case .unreachable: return "Nothing answered at that address."
        case .closed: return "The connection to the MPC dropped."
        case .timeout: return "The MPC stopped responding."
        case .cancelled: return "Cancelled."
        case .other: return detail.isEmpty ? "The SSH connection failed." : detail
        }
    }
}
