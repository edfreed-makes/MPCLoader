import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// MD5 checksums, used only to tell whether a file on the Mac and a file on the MPC hold the
/// same bytes. Nothing here is used for security.
public enum FileDigest {
    /// The MD5 of a file as 32 lower-case hex characters, read a megabyte at a time.
    public static func md5(of url: URL, isCancelled: () -> Bool = { false }) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = MD5Hasher()
        while true {
            if isCancelled() { throw SSHError(.cancelled) }
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(chunk)
        }
        return hasher.finish()
    }

    public static func md5(of data: Data) -> String {
        var hasher = MD5Hasher()
        hasher.update(data)
        return hasher.finish()
    }
}

/// Uses the system's implementation on a Mac and a plain Swift one elsewhere, so the same code
/// can be tested on Linux.
struct MD5Hasher {
    #if canImport(CryptoKit)
    private var system = Insecure.MD5()

    mutating func update(_ data: Data) { system.update(data: data) }

    mutating func finish() -> String {
        system.finalize().map { String(format: "%02x", $0) }.joined()
    }
    #else
    private var portable = PortableMD5()

    mutating func update(_ data: Data) { portable.update(data) }

    mutating func finish() -> String { portable.finish() }
    #endif
}

/// MD5 as described in RFC 1321.
struct PortableMD5 {
    private var state: (UInt32, UInt32, UInt32, UInt32) = (0x6745_2301, 0xefcd_ab89, 0x98ba_dcfe, 0x1032_5476)
    private var pending: [UInt8] = []
    private var length: UInt64 = 0

    private static let shifts: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                                           5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                                           4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                                           6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
    private static let table: [UInt32] = (0..<64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4_294_967_296.0)) }

    mutating func update(_ data: Data) {
        length &+= UInt64(data.count)
        pending.append(contentsOf: data)
        var offset = 0
        while pending.count - offset >= 64 {
            process(pending, at: offset)
            offset += 64
        }
        if offset > 0 { pending.removeFirst(offset) }
    }

    mutating func finish() -> String {
        var tail = pending
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        let bits = length &* 8
        for shift in stride(from: 0, to: 64, by: 8) { tail.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        var offset = 0
        while offset < tail.count {
            process(tail, at: offset)
            offset += 64
        }
        var bytes: [UInt8] = []
        for word in [state.0, state.1, state.2, state.3] {
            for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: word >> UInt32(shift))) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private mutating func process(_ bytes: [UInt8], at start: Int) {
        var words = [UInt32](repeating: 0, count: 16)
        for index in 0..<16 {
            let base = start + index * 4
            words[index] = UInt32(bytes[base]) | UInt32(bytes[base + 1]) << 8 | UInt32(bytes[base + 2]) << 16 | UInt32(bytes[base + 3]) << 24
        }
        var a = state.0, b = state.1, c = state.2, d = state.3
        for round in 0..<64 {
            var mix: UInt32
            var pick: Int
            switch round / 16 {
            case 0: mix = (b & c) | (~b & d); pick = round
            case 1: mix = (d & b) | (~d & c); pick = (5 * round + 1) % 16
            case 2: mix = b ^ c ^ d; pick = (3 * round + 5) % 16
            default: mix = c ^ (b | ~d); pick = (7 * round) % 16
            }
            mix = mix &+ a &+ PortableMD5.table[round] &+ words[pick]
            a = d
            d = c
            c = b
            let shift = PortableMD5.shifts[round]
            b = b &+ ((mix << shift) | (mix >> (32 - shift)))
        }
        state = (state.0 &+ a, state.1 &+ b, state.2 &+ c, state.3 &+ d)
    }
}
