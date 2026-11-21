// Saves the icon macOS shows for an app, as Finder and the Dock would draw it.
//
//   swiftc scripts/render-icon.swift -o /tmp/render-icon && /tmp/render-icon "dist/MPC Loader.app" out.png
//
// Exits with an error when macOS falls back to its generic app icon, which means the app's own
// icon was not found.
import AppKit
import CoreServices

setbuf(stdout, nil)
let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: render-icon <app> <output.png>")
    exit(2)
}
let appURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
let app = appURL.path
let output = URL(fileURLWithPath: arguments[2])
let side = 512

func pixels(_ image: NSImage) -> Data? {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

// What the bundle says about its icon, for the build log.
let info = Bundle(path: app)?.infoDictionary ?? [:]
print("render-icon: \(app)")
print("render-icon: CFBundleIconFile=\(info["CFBundleIconFile"] ?? "none") CFBundleIconName=\(info["CFBundleIconName"] ?? "none")")
let resources = appURL.appendingPathComponent("Contents/Resources")
print("render-icon: Resources holds \((try? FileManager.default.contentsOfDirectory(atPath: resources.path).sorted()) ?? [])")
if let icns = NSImage(contentsOf: resources.appendingPathComponent("AppIcon.icns")) {
    print("render-icon: AppIcon.icns loads, with \(icns.representations.count) sizes")
}

// Tell Launch Services about the app, as Finder does when an app is copied in.
let registered = LSRegisterURL(appURL as CFURL, true)
print("render-icon: registered with Launch Services, status \(registered)")

let generic = NSWorkspace.shared.icon(for: .application)
guard let fallback = pixels(generic) else {
    print("render-icon: could not draw the generic icon")
    exit(1)
}
// Icons can arrive a moment after they are first asked for, so keep asking for a few seconds.
var drawn = Data()
for attempt in 0..<20 {
    guard let image = pixels(NSWorkspace.shared.icon(forFile: app)) else { break }
    drawn = image
    if drawn != fallback {
        print("render-icon: macOS shows the app's own icon (attempt \(attempt + 1))")
        break
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
}
try drawn.write(to: output)
if drawn == fallback {
    print("render-icon: macOS shows the generic app icon, so the app's own icon was not found")
    exit(1)
}
print("render-icon: saved \(output.path)")
