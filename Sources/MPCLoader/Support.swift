import Foundation
import Security
import MPCKit

/// Runs blocking work one job at a time, off the main thread.
final class Worker: @unchecked Sendable {
    private let queue: DispatchQueue

    init(_ label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Keeps the SSH password in the macOS Keychain, never in a settings file.
enum Keychain {
    private static let service = "io.github.edfreed-makes.mpcloader"

    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func password(account: String) -> String? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(password: String, account: String) {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(account: account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account: account)
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func remove(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    static func count(_ number: Int, _ singular: String, _ plural: String) -> String {
        "\(number) \(number == 1 ? singular : plural)"
    }
}

extension RemoteEntry {
    /// Dates and sizes for sorting columns: unknown dates sort first.
    var sortDate: Date { modified ?? .distantPast }
}

extension Drive {
    var symbolName: String {
        switch kind {
        case .internalStorage: return "internaldrive"
        case .removable: return "externaldrive"
        case .factoryContent: return "lock.square.stack"
        }
    }

    var spaceDescription: String? {
        guard let freeBytes, let totalBytes, totalBytes > 0 else { return nil }
        return "\(Format.bytes(freeBytes)) free of \(Format.bytes(totalBytes))"
    }
}

/// The steps for switching on developer mode, as given by Akai's SDK tool for MPC OS 3.10.1.
enum DeveloperModeHelp {
    static let steps: [String] = [
        "Update the MPC to MPC OS 3.10.1 or later. Preferences → Info shows the version.",
        "On the MPC, open Preferences → Info.",
        "Tap the version value 3 times, then the serial number value 2 times, then the firmware version once.",
        "Developer mode is now on, which starts the MPC's SSH server. Connect again.",
    ]
    static let footnote = "Menu names can differ between MPC OS versions. Akai's guide is in the MPC Plugin SDK (github.com/inmusic-software/mpc-plugin-builder-sdk). Developer mode lets any device on your network log in to the MPC, so switch it off again on networks you don't control."
    static let findAddress = "To find the MPC's address: Preferences → Wi-Fi (hold Shift to reach the tab) or Preferences → Ethernet."
}
