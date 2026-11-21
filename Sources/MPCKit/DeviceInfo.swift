import Foundation

/// What the MPC says about itself, and which commands it has.
public struct DeviceInfo: Equatable, Sendable {
    public var model: String
    public var productCode: String
    public var compatible: String
    public var firmware: String
    public var appVersion: String
    public var hostname: String
    public var hasReleaseFile: Bool
    public var developerModeMarker: Bool
    /// `stat -c` works on this device.
    public var hasStat: Bool
    /// `find ... -exec ... {} +` works on this device.
    public var hasFindPlus: Bool
    /// `md5sum` works on this device, so files can be compared without copying them.
    public var hasMD5: Bool
    /// The script ran to the end.
    public var complete: Bool

    public init() {
        model = ""; productCode = ""; compatible = ""; firmware = ""; appVersion = ""; hostname = ""
        hasReleaseFile = false; developerModeMarker = false; hasStat = false; hasFindPlus = false; hasMD5 = false; complete = false
    }

    /// True when the device identifies itself as inMusic / Akai hardware.
    public var looksLikeMPC: Bool {
        if hasReleaseFile || !productCode.isEmpty || !appVersion.isEmpty { return true }
        let text = (model + " " + compatible).lowercased()
        return text.contains("akai") || text.contains("inmusic") || text.contains("mpc")
    }

    /// A name for the title bar, for example "Akai MPC Live II".
    public var displayName: String {
        if !model.isEmpty { return model }
        if !hostname.isEmpty { return hostname }
        return "MPC"
    }

    /// The questions the app asks the device on connecting.
    /// The device-tree and release-file lookups follow `INFO_SCRIPT` in Akai's SDK tool (MIT licence).
    static let script = """
    B=/sys/firmware/devicetree/base
    for f in model inmusic,product-code compatible; do
      printf 'dt.%s=' "$f"
      if [ -r "$B/$f" ]; then tr '\\000' ',' < "$B/$f"; fi
      echo
    done
    printf 'app=%s\\n' "$(head -n 1 /tmp/com.akaipro.mpc.version 2>/dev/null)"
    printf 'hostname=%s\\n' "$(hostname 2>/dev/null)"
    for f in /etc/az0x-release /etc/az01-release; do
      if [ -r "$f" ]; then echo release.file=yes; sed -n 's/^\\(AZ0[X1]_VERSION\\)=/firmware=/p' "$f" | head -n 1; fi
    done
    if [ -e /data/dev-mode ]; then echo devmode.file=yes; fi
    if stat -c '%f|%s|%Y|%n' -- / >/dev/null 2>&1; then echo cap.stat=yes; fi
    if find / -maxdepth 0 -exec true {} + >/dev/null 2>&1; then echo cap.findplus=yes; fi
    if [ "$(printf abc | md5sum 2>/dev/null | cut -c1-32)" = 900150983cd24fb0d6963f7d28e17f72 ]; then echo cap.md5=yes; fi
    echo mpcl.ok=yes
    """

    public static func parse(_ output: String) -> DeviceInfo {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,\"'\t"))
            if values[key] == nil { values[key] = value }
        }
        var info = DeviceInfo()
        info.model = values["dt.model"] ?? ""
        info.productCode = values["dt.inmusic,product-code"] ?? ""
        info.compatible = values["dt.compatible"] ?? ""
        info.firmware = values["firmware"] ?? ""
        info.appVersion = values["app"] ?? ""
        info.hostname = values["hostname"] ?? ""
        info.hasReleaseFile = values["release.file"] == "yes"
        info.developerModeMarker = values["devmode.file"] == "yes"
        info.hasStat = values["cap.stat"] == "yes"
        info.hasFindPlus = values["cap.findplus"] == "yes"
        info.hasMD5 = values["cap.md5"] == "yes"
        info.complete = values["mpcl.ok"] == "yes"
        return info
    }
}
